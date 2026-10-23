#!/usr/bin/env bash
# x5h-ota hook test: runs the POSIX sh hook (dash on the host) against fake
# podman, systemctl, journalctl and blockdev in a temporary directory.
set -u
name=test-x5h-ota
here=$(cd "$(dirname "$0")" && pwd); hook="$here/../scripts/x5h-ota.sh"
fail() { echo "TEST_FAIL $name reason=$1"; exit 1; }
[ -f "$hook" ] || fail hook_missing
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
D64=$(printf 'a%.0s' $(seq 64))
VP=ghcr.io/youtalk/x5h-visionpilot
CR=ghcr.io/youtalk/x5h-cr52-si
mangle() { printf '%s' "$1" | tr '/:' '__'; }

# ---- fakes, written once and copied into each case ----
mkdir -p "$tmp/fakes"
cat > "$tmp/fakes/podman" <<'EOF2'
#!/bin/sh
P=$T/podman
echo "$*" >> "$T/podman.log"
mangle() { printf '%s' "$1" | tr '/:' '__'; }
resolve() {
    m=$(mangle "$1")
    if [ -f "$P/tags/$m" ]; then cat "$P/tags/$m"
    elif [ -d "$P/images/$1" ]; then printf '%s\n' "$1"
    else return 1; fi
}
ntags() {
    n=0
    for f in "$P"/tags/*; do
        [ -f "$f" ] && [ "$(cat "$f")" = "$1" ] && n=$((n + 1))
    done
    echo "$n"
}
case "$1" in
pull)
    r="$P/refs/$(mangle "$3")"
    [ -f "$r" ] || exit 125
    id=$(cat "$r")
    [ ! -f "$r.name" ] || printf '%s\n' "$id" > "$P/tags/$(mangle "$(cat "$r.name")")"
    echo "$id" ;;
tag)
    id=$(resolve "$2") || exit 125
    printf '%s\n' "$id" > "$P/tags/$(mangle "$3")" ;;
rmi)
    [ -z "${RMI_FAIL:-}" ] || exit 1
    m=$(mangle "$2")
    if [ -f "$P/tags/$m" ]; then
        id=$(cat "$P/tags/$m"); rm -f "$P/tags/$m"
        [ "$(ntags "$id")" = 0 ] && rm -rf "$P/images/$id"
        exit 0
    fi
    [ -d "$P/images/$2" ] || exit 1
    [ "$(ntags "$2")" -le 1 ] || exit 1
    for f in "$P"/tags/*; do [ -f "$f" ] && [ "$(cat "$f")" = "$2" ] && rm -f "$f"; done
    rm -rf "$P/images/$2" ;;
image)
    case "$2" in
    inspect)
        id=$(resolve "$5") || exit 125
        case "$4" in
        '{{.Id}}') echo "$id" ;;
        '{{.Architecture}}') cat "$P/images/$id/arch"; echo ;;
        '{{len .RepoTags}}') ntags "$id" ;;
        '{{index .Labels "'*'"}}')
            k=${4#'{{index .Labels "'}; k=${k%'"}}'}
            cat "$P/images/$id/label.$k" 2>/dev/null; echo ;;
        *) exit 1 ;;
        esac ;;
    mount)
        id=$(resolve "$3") || exit 125
        [ -d "$P/images/$id/root" ] || exit 125
        echo "$P/images/$id/root" ;;
    unmount) : ;;
    *) exit 1 ;;
    esac ;;
*) exit 1 ;;
esac
EOF2
cat > "$tmp/fakes/systemctl" <<'EOF2'
#!/bin/sh
echo "$*" >> "$T/systemctl.log"
case "$*" in
"is-active score-lm.service")
    echo "${LM_STATE:-inactive}"; [ "${LM_STATE:-inactive}" = active ] ;;
"start score-lm.service")
    n=$(cat "$T/starts" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$T/starts"
    cp "$T/journal.after.$n" "$T/journal.since" 2>/dev/null || : > "$T/journal.since" ;;
esac
exit 0
EOF2
cat > "$tmp/fakes/journalctl" <<'EOF2'
#!/bin/sh
case "$*" in
*x5h-si-link*) cat "$T/journal.si" 2>/dev/null ;;
*--since*) cat "$T/journal.since" 2>/dev/null ;;
*) cat "$T/journal.boot" 2>/dev/null ;;
esac
exit 0
EOF2
cat > "$tmp/fakes/blockdev" <<'EOF2'
#!/bin/sh
if [ -f "$T/flip" ]; then
    off=$(cat "$T/flip"); rm -f "$T/flip"
    for a; do d=$a; done
    printf '\001' | dd of="$d" bs=1 seek="$off" conv=notrunc 2>/dev/null
fi
exit 0
EOF2
chmod +x "$tmp/fakes/"*

# ---- fixtures ----
mkdir -p "$tmp/fix"
vec() { for _ in 1 2 3 4 5 6 7 8; do printf '\030\360\237\345'; done; }
{ vec; head -c 9968 /dev/zero; } > "$tmp/fix/good.bin"
{ vec; head -c 39968 /dev/zero; } > "$tmp/fix/big.bin"
head -c 10000 /dev/zero > "$tmp/fix/zero.bin"
{ printf '\177ELF'; head -c 100 /dev/zero; } > "$tmp/fix/good.elf"
{ printf 'MZ\220\000'; head -c 100 /dev/zero; } > "$tmp/fix/mz.elf"

reset_case() {
    T="$tmp/case"; export T
    rm -rf "$T"; mkdir -p "$T/podman/images" "$T/podman/tags" "$T/podman/refs" "$T/fw"
    cp -r "$tmp/fakes" "$T/bin"; cp -r "$tmp/fix" "$T/fix"
    printf 'SLOT_SKIP=4\nSLOT_SECTORS=8\n' > "$T/slot.conf"
    head -c 49152 /dev/zero > "$T/dev0"; head -c 49152 /dev/zero > "$T/dev1"
}
run() {
    out=$(PATH="$T/bin:$PATH" T="$T" X5H_OTA_STATE="$T/state" X5H_OTA_CONF="$T/slot.conf" \
        X5H_OTA_DEVICES="$T/dev0 $T/dev1" X5H_OTA_FIRMWARE="$T/fw/actuation_x5h.elf" \
        X5H_OTA_LOCK="$T/lock" X5H_OTA_TIMEOUT="${TIMEOUT:-0}" X5H_OTA_DIRECT= \
        sh "$hook" "$@" 2>&1); rc=$?
}
has() { printf '%s\n' "$out" | grep -qxF -- "$1" || fail "$2 out=$out"; }
hasnt() { ! printf '%s\n' "$out" | grep -qxF -- "$1" || fail "$2 out=$out"; }
bad() { has "X5H_OTA_FAIL $1 reason=$2" "$3"; [ "$rc" = 1 ] || fail "$3 rc=$rc"; }
logged() { grep -qxF -- "$1" "$T/podman.log" || fail "$2 log=$(cat "$T/podman.log")"; }

# mkimg <id> <arch> <key=value>...: a label may hold any bytes, one file each.
mkimg() {
    id=$1; arch=$2; shift 2
    mkdir -p "$T/podman/images/$id"; printf '%s' "$arch" > "$T/podman/images/$id/arch"
    for kv; do printf '%s' "${kv#*=}" > "$T/podman/images/$id/label.${kv%%=*}"; done
}
ref() { printf '%s\n' "$2" > "$T/podman/refs/$(mangle "$1")"; }
sum() { sha256sum "$1" | { read -r h _; echo "$h"; }; }
# mkcr52 <id> <payload> <elf> <version>; H1 and H2 override the hash labels.
mkcr52() {
    mkimg "$1" arm64 x5h.ota.component=cr52 "org.opencontainers.image.version=$4" \
        "x5h.ota.sha256=${H1:-$(sum "$2")}" "x5h.ota.elf_sha256=${H2:-$(sum "$3")}"
    mkdir -p "$T/podman/images/$1/root/cr52"
    cp "$2" "$T/podman/images/$1/root/cr52/slot.bin"
    cp "$3" "$T/podman/images/$1/root/cr52/actuation_x5h.elf"
}
vpimg() { mkimg A arm64 x5h.ota.component=visionpilot "org.opencontainers.image.version=${1-v1}"; }
VD="$VP@sha256:$D64"; CD="$CR@sha256:$D64"
ST() { echo "$T/state/$1"; }

# ---- vp_digest, status_staged ----
reset_case; vpimg; ref "$VD" A
run install visionpilot "$VD"
has 'X5H_OTA_PASS install' vp_digest
[ "$rc" = 0 ] || fail vp_digest_rc
[ "$(cat "$T/podman/tags/localhost_x5h-visionpilot_staged")" = A ] || fail vp_tag
grep -qx 'version=v1' "$(ST visionpilot/staged.env)" || fail vp_env_version
grep -qx 'image=A' "$(ST visionpilot/staged.env)" || fail vp_env_image
run status
has 'X5H_OTA_STATUS component=cr52 version=none state=ok' status_cr52
has 'X5H_OTA_STATUS component=visionpilot version=none state=staged' status_staged

# ---- rollback_staged ----
run rollback
has 'X5H_OTA_PASS rollback' rollback_staged
hasnt X5H_OTA_REBOOT_REQUIRED rollback_reboot
[ ! -e "$T/podman/tags/localhost_x5h-visionpilot_staged" ] || fail rollback_tag
[ ! -e "$(ST visionpilot/staged.env)" ] || fail rollback_env

# ---- rollback_none ----
reset_case
run rollback
bad rollback nothing_to_roll_back rollback_none

# ---- source checks ----
reset_case; vpimg; ref "$VP:v1" A
run install visionpilot "$VP:v1"; bad install bad_source tag_ref
reset_case; vpimg; ref "$CD" A
run install visionpilot "$CD"; bad install bad_source wrong_repo
run install visionpilot "$VP@sha256:abc"; bad install bad_source short_digest
run install visionpilot "$VP@sha256:${D64%a}G"; bad install bad_source nonhex_digest

reset_case; vpimg; : > "$T/a.tar"; ref "oci-archive:$T/a.tar" A
run install visionpilot "$T/a.tar"
has 'X5H_OTA_PASS install' archive_ok
logged "pull -q oci-archive:$T/a.tar" archive_pull
: > "$T/a:b.tar"; mkdir "$T/d"
run install visionpilot a.tar; bad install bad_source archive_relative
run install visionpilot "$T/a:b.tar"; bad install bad_source archive_colon
run install visionpilot "$T/d"; bad install bad_source archive_dir

reset_case
run install visionpilot "$VD"
bad install pull_failed pull_fail
[ ! -e "$T/podman/tags/localhost_x5h-visionpilot_staged" ] || fail pull_fail_tag
[ ! -e "$(ST visionpilot/staged.env)" ] || fail pull_fail_env

# ---- archive named like a hook tag (R16) ----
reset_case; vpimg; mkimg B arm64 x5h.ota.component=visionpilot org.opencontainers.image.version=v0
echo B > "$T/podman/tags/localhost_x5h-visionpilot_latest"
: > "$T/a.tar"; ref "oci-archive:$T/a.tar" A; echo localhost/x5h-visionpilot:latest > "$T/podman/refs/$(mangle "oci-archive:$T/a.tar").name"
run install visionpilot "$T/a.tar"; bad install bad_source archive_named_latest
[ "$(cat "$T/podman/tags/localhost_x5h-visionpilot_latest")" = B ] || fail archive_latest_moved
[ ! -e "$(ST visionpilot/staged.env)" ] || fail archive_named_env
echo localhost/x5h-visionpilot:previous > "$T/podman/refs/$(mangle "oci-archive:$T/a.tar").name"
vpimg
run install visionpilot "$T/a.tar"; bad install bad_source archive_named_absent
[ ! -e "$T/podman/tags/localhost_x5h-visionpilot_previous" ] || fail archive_previous_left
[ ! -e "$T/podman/images/A" ] || fail archive_image_left

# ---- label checks ----
reset_case; mkimg A arm64 x5h.ota.component=cr52 org.opencontainers.image.version=v1; ref "$VD" A
run install visionpilot "$VD"; bad install bad_label bad_label
reset_case; mkimg A amd64 x5h.ota.component=visionpilot org.opencontainers.image.version=v1; ref "$VD" A
run install visionpilot "$VD"; bad install bad_arch bad_arch_vp
reset_case; mkimg C amd64 x5h.ota.component=cr52 org.opencontainers.image.version=v1; ref "$CD" C
run install cr52 "$CD"; bad install bad_arch bad_arch_cr52
for v in 'v1;reboot' 'v1
state=ok' ''; do
    reset_case; vpimg "$v"; ref "$VD" A
    run install visionpilot "$VD"; bad install bad_version "bad_version[$v]"
    ! grep -rq 'reboot\|state=ok' "$T/state" 2>/dev/null || fail version_leaked
done

# ---- cr52 ----
reset_case; mkcr52 C "$T/fix/good.bin" "$T/fix/good.elf" v1; ref "$CD" C
run install cr52 "$CD"
has 'X5H_OTA_PASS install' cr52_ok
cmp -s "$T/fix/good.bin" "$(ST cr52/staged.bin)" || fail cr52_bin
cmp -s "$T/fix/good.elf" "$(ST cr52/staged.elf)" || fail cr52_elf
logged 'image unmount C' cr52_unmount; logged 'rmi C' cr52_rmi
for k in version=v1 "sha256=$(sum "$T/fix/good.bin")" "elf_sha256=$(sum "$T/fix/good.elf")" bytes=10000; do
    grep -qx "$k" "$(ST cr52/staged.env)" || fail "cr52_env $k"
done
run status
has 'X5H_OTA_STATUS component=cr52 version=none state=staged' cr52_status

cr52bad() { # <case> <reason> <bin> <elf>
    reset_case; mkcr52 C "$T/fix/$3" "$T/fix/$4" v1; ref "$CD" C
    run install cr52 "$CD"; bad install "$2" "$1"
    [ ! -e "$(ST cr52/staged.bin)" ] && [ ! -e "$(ST cr52/staged.env)" ] || fail "$1_staged"
    logged 'image unmount C' "$1_unmount"; logged 'rmi C' "$1_rmi"
}
H1=0000 cr52bad hash_payload bad_hash good.bin good.elf
H2=0000 cr52bad hash_elf bad_hash good.bin good.elf
cr52bad too_large too_large big.bin good.elf
cr52bad no_vector no_vector_table zero.bin good.elf
cr52bad no_elf no_elf_magic good.bin mz.elf

reset_case; mkcr52 C "$T/fix/good.bin" "$T/fix/good.elf" v1; ref "$CD" C
rm "$T/podman/images/C/root/cr52/slot.bin"; ln -s "$T/fix/good.bin" "$T/podman/images/C/root/cr52/slot.bin"
run install cr52 "$CD"; bad install bad_hash cr52_symlink
[ ! -e "$(ST cr52/staged.env)" ] || fail symlink_staged
reset_case; mkcr52 C "$T/fix/good.bin" "$T/fix/good.elf" v1; ref "$CD" C
mkdir "$T/outside"; cp "$T/fix/good.bin" "$T/outside/slot.bin"; cp "$T/fix/good.elf" "$T/outside/actuation_x5h.elf"
rm -rf "$T/podman/images/C/root/cr52"; ln -s "$T/outside" "$T/podman/images/C/root/cr52"
run install cr52 "$CD"; bad install bad_hash cr52_dir_symlink

# A cr52 pull that already holds a name keeps its image and name (R17).
reset_case; mkimg C arm64 x5h.ota.component=visionpilot org.opencontainers.image.version=v1; ref "$CD" C
echo localhost/other:x > "$T/podman/refs/$(mangle "$CD").name"
run install cr52 "$CD"; bad install bad_label cr52_named
[ -d "$T/podman/images/C" ] && [ -f "$T/podman/tags/localhost_other_x" ] || fail cr52_named_lost

reset_case; rm "$T/slot.conf"; mkcr52 C "$T/fix/good.bin" "$T/fix/good.elf" v1; ref "$CD" C
run install cr52 "$CD"; bad install no_conf cr52_noconf
printf 'SLOT_SKIP=4x\nSLOT_SECTORS=8\n' > "$T/slot.conf"
run install cr52 "$CD"; bad install no_conf conf_not_digits

# ---- state_write: a read-only state directory stops a normal user (uid != 0) ----
if [ "$(id -u)" != 0 ]; then
    reset_case; vpimg; ref "$VD" A; mkdir -p "$T/state/visionpilot"; chmod a-w "$T/state/visionpilot"
    run install visionpilot "$VD"; bad install state_write state_write_vp
    hasnt 'X5H_OTA_PASS install' state_write_vp_pass
    chmod u+w "$T/state/visionpilot"
    reset_case; mkcr52 C "$T/fix/good.bin" "$T/fix/good.elf" v1; ref "$CD" C
    mkdir -p "$T/state/cr52"; chmod a-w "$T/state/cr52"
    run install cr52 "$CD"; bad install state_write state_write_cr52
    hasnt 'X5H_OTA_PASS install' state_write_cr52_pass
    chmod u+w "$T/state/cr52"
fi

# ---- pending ----
reset_case; vpimg; ref "$VD" A; mkdir -p "$T/state"; echo 'visionpilot update' > "$T/state/pending"
run install visionpilot "$VD"; bad install verify_pending pending_install
run rollback; bad rollback verify_pending pending_rollback
run status
has 'X5H_OTA_STATUS component=visionpilot version=none state=verifying' pending_status
echo 'visionpilot rollback' > "$T/state/pending"
run status
has 'X5H_OTA_STATUS component=visionpilot version=none state=rolling_back' pending_status_rb

# ---- usage ----
reset_case
run; bad usage usage usage_none
run bogus; bad usage usage usage_bogus
run install camera "$VD"; bad install bad_component bad_component
run install visionpilot; bad install usage usage_argc

echo "TEST_PASS $name"
