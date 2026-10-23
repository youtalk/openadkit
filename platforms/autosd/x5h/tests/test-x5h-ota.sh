#!/usr/bin/env bash
# x5h-ota hook test: runs the POSIX sh hook against fake podman, systemctl,
# journalctl, blockdev and cp in a temporary directory.
set -u
name=test-x5h-ota
here=$(cd "$(dirname "$0")" && pwd); hook="$here/../scripts/x5h-ota.sh"
fail() { echo "TEST_FAIL $name reason=$1 sh=${OTA_SH:-}"; exit 1; }
[ -f "$hook" ] || fail hook_missing
# The board runs the hook with bash as /bin/sh, a Debian host with dash. Run
# every case once per shell, and print one TEST_PASS for both.
if [ -z "${OTA_SH:-}" ]; then
    for s in dash 'bash --posix'; do
        command -v "${s%% *}" > /dev/null || fail "no_${s%% *}"
        OTA_SH=$s bash "$0" || exit 1
    done
    echo "TEST_PASS $name"; exit 0
fi
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
# systemctl: is-active prints $T/lm.state, or $LM_STATE. The nth start copies
# journal.after.<n> to journal.since and lm.after.<n> to lm.state, logs its
# time to start.at, then sleeps $START_SLEEP.
cat > "$tmp/fakes/systemctl" <<'EOF2'
#!/bin/sh
echo "$*" >> "$T/systemctl.log"
case "$*" in
"is-active score-lm.service")
    s=$(cat "$T/lm.state" 2>/dev/null || echo "${LM_STATE:-inactive}")
    echo "$s"; [ "$s" = active ] ;;
"start score-lm.service")
    n=$(cat "$T/starts" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$T/starts"
    cp "$T/journal.after.$n" "$T/journal.since" 2>/dev/null || : > "$T/journal.since"
    [ ! -f "$T/lm.after.$n" ] || cp "$T/lm.after.$n" "$T/lm.state"
    date +%s >> "$T/start.at"; sleep "${START_SLEEP:-0}" ;;
esac
exit 0
EOF2
# journalctl: logs its arguments. A --since call prints journal.since, or
# journal.late from the call number in $T/late on.
cat > "$tmp/fakes/journalctl" <<'EOF2'
#!/bin/sh
echo "$*" >> "$T/journalctl.log"
case "$*" in
*x5h-si-link*) cat "$T/journal.si" 2>/dev/null ;;
*--since*)
    n=$(($(cat "$T/since.calls" 2>/dev/null || echo 0) + 1)); echo "$n" > "$T/since.calls"
    if [ -f "$T/late" ] && [ "$n" -ge "$(cat "$T/late")" ]; then cat "$T/journal.late"
    else cat "$T/journal.since" 2>/dev/null; fi ;;
*) cat "$T/journal.boot" 2>/dev/null ;;
esac
exit 0
EOF2
# blockdev: $T/flip changes one byte once. $T/powercut kills the hook (the
# parent) right after the slot dd, first changing the byte at its offset if any.
cat > "$tmp/fakes/blockdev" <<'EOF2'
#!/bin/sh
for a; do d=$a; done
if [ -f "$T/flip" ]; then
    off=$(cat "$T/flip"); rm -f "$T/flip"
    printf '\001' | dd of="$d" bs=1 seek="$off" conv=notrunc 2>/dev/null
fi
if [ -f "$T/powercut" ]; then
    off=$(cat "$T/powercut"); rm -f "$T/powercut"
    [ -z "$off" ] || printf '\001' | dd of="$d" bs=1 seek="$off" conv=notrunc 2>/dev/null
    kill -9 "$PPID"
fi
exit 0
EOF2
# cp: with $T/cpfail present, a copy onto the firmware writes 10 bytes and fails,
# once, or as many times as the number in the file.
cat > "$tmp/fakes/cp" <<'EOF2'
#!/bin/sh
for a; do d=$a; done
if [ -f "$T/cpfail" ] && [ "$d" = "$X5H_OTA_FIRMWARE" ]; then
    n=$(cat "$T/cpfail"); n=${n:-1}
    if [ "$n" -gt 1 ]; then echo $((n - 1)) > "$T/cpfail"; else rm -f "$T/cpfail"; fi
    head -c 10 "$1" > "$d"; exit 1
fi
exec /bin/cp "$@"
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
{ vec; head -c 11968 /dev/zero | tr '\000' '\125'; } > "$tmp/fix/p1.bin"
{ printf '\177ELF'; head -c 200 /dev/zero | tr '\000' '\001'; } > "$tmp/fix/elf1.elf"

reset_case() {
    T="$tmp/case"; export T
    rm -rf "$T"; mkdir -p "$T/podman/images" "$T/podman/tags" "$T/podman/refs" "$T/fw"
    cp -r "$tmp/fakes" "$T/bin"; cp -r "$tmp/fix" "$T/fix"
    printf 'SLOT_SKIP=4\nSLOT_SECTORS=8\n' > "$T/slot.conf"
    head -c 49152 /dev/zero > "$T/dev0"; head -c 49152 /dev/zero > "$T/dev1"
    echo 1 > "$T/boot_id"
}
# newboot: a reboot, as far as the hook can see (a new boot ID).
newboot() { echo $(($(cat "$T/boot_id") + 1)) > "$T/boot_id"; }
run() {
    out=$(PATH="$T/bin:$PATH" T="$T" X5H_OTA_STATE="$T/state" X5H_OTA_CONF="$T/slot.conf" \
        X5H_OTA_DEVICES="${DEVS:-$T/dev0 $T/dev1}" X5H_OTA_FIRMWARE="$T/fw/actuation_x5h.elf" \
        X5H_OTA_LOCK="$T/lock" X5H_OTA_TIMEOUT="${TIMEOUT:-0}" X5H_OTA_DIRECT= \
        X5H_OTA_BOOT_ID="$T/boot_id" $OTA_SH "$hook" "$@" 2>&1); rc=$?
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
run init; bad init usage init_argc
run activate now; bad activate usage activate_argc

# ---- init ----
# base: P0 at SLOT_SKIP on dev1 (dev0 stays zeros), the baseline ELF as firmware.
base() {
    cp "$T/fix/good.bin" "$T/p0.bin"; cp "$T/fix/good.elf" "$T/fw/actuation_x5h.elf"
    dd if="$T/p0.bin" of="$T/dev1" bs=4096 seek=4 conv=notrunc 2>/dev/null
}
ext() { dd if="$T/$1" bs=4096 skip=4 count=8 2>/dev/null; }
reset_case; base
run init "$T/p0.bin"
has 'X5H_OTA_PASS init' init_ok
for k in version=baseline state=ok "sha256=$(sum "$T/p0.bin")" bytes=10000 "elf_sha256=$(sum "$T/fix/good.elf")"; do
    grep -qx "$k" "$(ST cr52/installed.env)" || fail "init_env $k"
done
run status
has 'X5H_OTA_STATUS component=cr52 version=baseline state=ok slot=match' init_status
cp "$T/fix/elf1.elf" "$T/fw/actuation_x5h.elf"; run status
has 'X5H_OTA_STATUS component=cr52 version=baseline state=ok slot=mismatch' status_fw_mismatch
cp "$T/fix/good.elf" "$T/fw/actuation_x5h.elf"; head -c 49152 /dev/zero > "$T/dev1"; run status
has 'X5H_OTA_STATUS component=cr52 version=baseline state=ok slot=mismatch' status_slot_mismatch

reset_case; base; cp "$T/fix/p1.bin" "$T/p1.bin"
run init "$T/p1.bin"; bad init slot_not_found init_none
reset_case; base; dd if="$T/p0.bin" of="$T/dev0" bs=4096 seek=4 conv=notrunc 2>/dev/null
run init "$T/p0.bin"; bad init slot_ambiguous init_two
reset_case; base; ln -s "$T/dev1" "$T/alias1"
DEVS="$T/dev0 $T/dev1 $T/alias1" run init "$T/p0.bin"; has 'X5H_OTA_PASS init' init_alias
reset_case; base; rm "$T/fw/actuation_x5h.elf"
run init "$T/p0.bin"; bad init no_firmware init_nofw
[ ! -e "$(ST cr52/installed.env)" ] || fail init_nofw_env

# ---- activate ----
reset_case
run activate; bad activate nothing_staged act_none

# cr52up <case>: init with P0, then stage P1 and ELF1 as v1; keep the old extent.
cr52up() {
    base; run init "$T/p0.bin"; has 'X5H_OTA_PASS init' "$1_init"
    mkcr52 K "$T/fix/p1.bin" "$T/fix/elf1.elf" v1; ref "$CD" K
    run install cr52 "$CD"; has 'X5H_OTA_PASS install' "$1_install"
    ext dev1 > "$T/old.ext"
}
# vpup <case>: :latest holds B, :previous holds C with no other tag, then stage A.
vpup() {
    mkimg B arm64 x5h.ota.component=visionpilot org.opencontainers.image.version=v0
    mkimg C arm64 x5h.ota.component=visionpilot org.opencontainers.image.version=old
    echo B > "$T/podman/tags/localhost_x5h-visionpilot_latest"
    echo C > "$T/podman/tags/localhost_x5h-visionpilot_previous"
    vpimg; ref "$VD" A
    run install visionpilot "$VD"; has 'X5H_OTA_PASS install' "$1_install"
}
tagof() { cat "$T/podman/tags/localhost_x5h-visionpilot_$1" 2>/dev/null; }
# undone <case>: the slot, the firmware and pending are as before the activate.
undone() {
    hasnt X5H_OTA_REBOOT_REQUIRED "$1_reboot"
    ext dev1 | cmp -s - "$T/old.ext" || fail "$1_slot"
    cmp -s "$T/fix/good.elf" "$T/fw/actuation_x5h.elf" || fail "$1_fw"
    [ ! -e "$(ST pending)" ] && [ ! -e "$(ST pending.boot)" ] || fail "$1_pending"
    [ ! -e "$(ST last)" ] || fail "$1_last"
    [ -f "$(ST cr52/staged.env)" ] && [ -f "$(ST cr52/staged.bin)" ] || fail "$1_staged"
}

reset_case; cr52up act_cr52
run activate
has X5H_OTA_REBOOT_REQUIRED act_cr52_reboot; has 'X5H_OTA_PASS activate' act_cr52
{ cat "$T/fix/p1.bin"; head -c $((32768 - 12000)) /dev/zero | tr '\000' '\377'; } > "$T/want.ext"
ext dev1 | cmp -s - "$T/want.ext" || fail act_cr52_slot
cmp -s "$T/dev0" <(head -c 49152 /dev/zero) || fail act_cr52_dev0
cmp -s <(head -c 16384 "$T/dev1") <(head -c 16384 /dev/zero) || fail act_cr52_head
cmp -s "$T/fix/elf1.elf" "$T/fw/actuation_x5h.elf" || fail act_cr52_fw
cmp -s "$T/old.ext" "$(ST cr52/previous.bin)" || fail act_cr52_prevbin
cmp -s "$T/fix/good.elf" "$(ST cr52/previous.elf)" || fail act_cr52_prevelf
grep -qx version=baseline "$(ST cr52/previous.env)" || fail act_cr52_prevenv
[ "$(cat "$(ST pending)")" = 'cr52 update' ] || fail act_cr52_pending
[ "$(cat "$(ST last)")" = cr52 ] || fail act_cr52_last
[ ! -e "$(ST cr52/staged.env)" ] && [ ! -e "$(ST cr52/staged.bin)" ] || fail act_cr52_staged
run status
has 'X5H_OTA_STATUS component=cr52 version=v1 state=verifying slot=match' act_cr52_status

reset_case; cr52up act_flip; echo 16384 > "$T/flip"
run activate; bad activate write_mismatch act_flip
[ ! -e "$T/flip" ] || fail act_flip_unused
undone act_flip
run status
has 'X5H_OTA_STATUS component=cr52 version=baseline state=staged slot=match' act_flip_status

reset_case; base; mkcr52 K "$T/fix/p1.bin" "$T/fix/elf1.elf" v1; ref "$CD" K
run install cr52 "$CD"; ext dev1 > "$T/old.ext"
run activate; bad activate slot_not_found act_noinit
undone act_noinit

# The conf shrank after the install: P1 (12000 bytes) no longer fits 2 sectors.
reset_case; cr52up act_big; printf 'SLOT_SKIP=4\nSLOT_SECTORS=2\n' > "$T/slot.conf"
run activate; bad activate too_large act_too_large
undone act_too_large

reset_case; cr52up act_nofw; rm "$T/fw/actuation_x5h.elf"
run activate; bad activate no_firmware act_nofw
ext dev1 | cmp -s - "$T/old.ext" || fail act_nofw_slot
[ ! -e "$(ST pending)" ] || fail act_nofw_pending

reset_case; cr52up act_fw; : > "$T/cpfail"
run activate; bad activate firmware_write act_fw
[ ! -e "$T/cpfail" ] || fail act_fw_unused
undone act_fw

if [ "$(id -u)" != 0 ]; then
    reset_case; cr52up act_sw; chmod a-w "$T/state/cr52"
    run activate; bad activate state_write act_state_write
    chmod u+w "$T/state/cr52"
    undone act_state_write
fi

reset_case; vpup act_vp_reboot
LM_STATE=inactive run activate
has X5H_OTA_REBOOT_REQUIRED act_vp_reboot_marker; has 'X5H_OTA_PASS activate' act_vp_reboot
[ "$(tagof latest)" = A ] && [ "$(tagof previous)" = B ] && [ -z "$(tagof staged)" ] || fail act_vp_tags
logged 'rmi C' act_vp_rmi
[ ! -d "$T/podman/images/C" ] || fail act_vp_c_left
[ "$(cat "$(ST pending)")" = 'visionpilot update' ] || fail act_vp_pending
[ "$(cat "$(ST last)")" = visionpilot ] || fail act_vp_last
grep -qx image=B "$(ST visionpilot/previous.env)" || fail act_vp_prev
for k in version=v1 image=A state=ok; do
    grep -qx "$k" "$(ST visionpilot/installed.env)" || fail "act_vp_env $k"
done
[ ! -e "$(ST visionpilot/staged.env)" ] || fail act_vp_staged

reset_case; vpup act_vp_child
RMI_FAIL=1 run activate
has 'X5H_OTA_PASS activate' act_vp_child
[ -d "$T/podman/images/C" ] || fail act_vp_child_rmi

reset_case; vpup act_both; cr52up act_both; echo 16384 > "$T/flip"
run activate; bad activate write_mismatch act_both_flip
[ "$(tagof latest)" = B ] && [ "$(tagof previous)" = C ] && [ "$(tagof staged)" = A ] || fail act_both_tags
[ -f "$(ST visionpilot/staged.env)" ] || fail act_both_vp_staged
undone act_both

reset_case; mkdir -p "$T/state"; echo 'cr52 update' > "$T/state/pending"
run activate; bad activate verify_pending act_pending
run init "$T/p0.bin"; bad init verify_pending init_pending

# ---- verify, the restart path and rollback ----
# The real line on board 2 has an em dash; the hook matches the prefix only.
RL='[MergedBackend] Ready — 3 inputs, 9 outputs'
# hb <seq>...: x5h-si-link heartbeat lines. fault=1 is normal with no camera.
hb() { for s; do echo "RPMSG_SI_RX hb seq=$s uptime_ms=${s}000 fault=1"; done > "$T/journal.si"; }
# vpj <file> [ready]: VisionPilot journal lines, with or without the ready line.
vpj() { { echo '[MergedBackend] Loading model'; [ "${2:-}" != ready ] || echo "$RL"; } > "$T/$1"; }
sys() { cat "$T/systemctl.log" 2>/dev/null; }
reboots() { sys | grep -cx reboot; }
starts() { sys | grep -cx 'start score-lm.service'; }
LMR=$'stop score-lm.service\nkill -s USR2 x5h-si-link.service\nstart score-lm.service'
nopending() {
    [ ! -e "$(ST pending)" ] || fail "$1_pending $(cat "$(ST pending)")"
    [ ! -e "$(ST pending.boot)" ] || fail "$1_pending_boot"
}

# verify in the boot of the change judges nothing: the old firmware still
# beats and the old ready line is in this boot's journal (R31).
reset_case; cr52up v_same_boot; run activate; has 'X5H_OTA_PASS activate' v_same_boot_act
hb 41 42; ext dev1 > "$T/new.ext"; cp "$(ST pending)" "$T/pending.before"
run verify
[ "$out" = $'X5H_OTA_REBOOT_REQUIRED\nX5H_OTA_FAIL verify reason=reboot_required' ] || fail "v_same_boot out=$out"
[ "$rc" = 1 ] || fail v_same_boot_rc
cmp -s "$(ST pending)" "$T/pending.before" || fail v_same_boot_pending
ext dev1 | cmp -s - "$T/new.ext" || fail v_same_boot_slot
[ "$(reboots)" = 0 ] || fail v_same_boot_reboot
run status; has 'X5H_OTA_STATUS component=cr52 version=v1 state=verifying slot=match' v_same_boot_status

reset_case; cr52up v_cr52; run activate; has 'X5H_OTA_PASS activate' v_cr52_act
hb 41 42; newboot; run verify
has 'X5H_OTA_PASS verify' v_cr52_pass
[ "$rc" = 0 ] || fail v_cr52_pass_rc
nopending v_cr52_pass
[ "$(reboots)" = 0 ] || fail v_cr52_pass_reboot
run status; has 'X5H_OTA_STATUS component=cr52 version=v1 state=ok slot=match' v_cr52_pass_status

# r_cr52: a rollback of an activated cr52 waits for a reboot.
run rollback
has X5H_OTA_REBOOT_REQUIRED r_cr52_reboot; has 'X5H_OTA_PASS rollback' r_cr52
ext dev1 | cmp -s - "$(ST cr52/previous.bin)" || fail r_cr52_slot
cmp -s "$T/fix/good.elf" "$T/fw/actuation_x5h.elf" || fail r_cr52_fw
[ "$(cat "$(ST pending)")" = 'cr52 rollback' ] || fail r_cr52_pending
[ ! -e "$(ST last)" ] || fail r_cr52_last
run status; has 'X5H_OTA_STATUS component=cr52 version=baseline state=rolling_back slot=match' r_cr52_status
# The v1 firmware still beats in this boot, so the rollback is not judged yet (R31).
hb 43 44; run verify
[ "$out" = $'X5H_OTA_REBOOT_REQUIRED\nX5H_OTA_FAIL verify reason=reboot_required' ] || fail "r_cr52_same_boot out=$out"
[ "$(cat "$(ST pending)")" = 'cr52 rollback' ] || fail r_cr52_same_boot_pending

# cr52fail <case>: act_cr52, then a verify with one hb line.
cr52fail() {
    reset_case; cr52up "$1"; run activate; has 'X5H_OTA_PASS activate' "$1_act"
    hb 41; newboot; run verify
}
cr52fail v_cr52_fail
bad verify verify_failed v_cr52_fail
ext dev1 | cmp -s - "$(ST cr52/previous.bin)" || fail v_cr52_fail_slot
cmp -s "$(ST cr52/previous.elf)" "$T/fw/actuation_x5h.elf" || fail v_cr52_fail_fw
[ "$(cat "$(ST pending)")" = 'cr52 rollback' ] || fail v_cr52_fail_pending
[ "$(sys | tail -n 1)" = reboot ] || fail "v_cr52_fail_reboot $(sys)"
[ ! -e "$(ST last)" ] || fail v_cr52_fail_last
run status; has 'X5H_OTA_STATUS component=cr52 version=baseline state=rolling_back slot=match' v_cr52_fail_status
hb 7 8; newboot; run verify
has 'X5H_OTA_PASS verify' v_rb_pass
nopending v_rb_pass
run status; has 'X5H_OTA_STATUS component=cr52 version=baseline state=rolled_back slot=match' v_rb_pass_status

# Each pass condition on its own: a flat seq, and rising seqs with the old ELF.
reset_case; cr52up v_cr52_flat; run activate; hb 42 42; newboot; run verify
bad verify verify_failed v_cr52_flat
reset_case; cr52up v_cr52_fw; run activate; hb 41 42; cp "$T/fix/good.elf" "$T/fw/actuation_x5h.elf"
newboot; run verify; bad verify verify_failed v_cr52_fw

cr52fail v_rb_fail; rm -f "$T/journal.si"; newboot; run verify
bad verify rollback_failed v_rb_fail
nopending v_rb_fail
[ "$(reboots)" = 1 ] || fail "v_rb_fail_reboot $(sys)"
run status; has 'X5H_OTA_STATUS component=cr52 version=baseline state=rollback_failed slot=match' v_rb_fail_status

# cut <case> [offset]: a power cut right after the slot dd of activate (R6),
# then a verify at the next boot with no heartbeat.
cut() {
    reset_case; cr52up "$1"; printf '%s' "${2:-}" > "$T/powercut"
    run activate
    [ ! -e "$T/powercut" ] || fail "$1_unused"
    hasnt 'X5H_OTA_PASS activate' "$1_act"
    ext dev1 > "$T/cut.ext"
    ! cmp -s "$T/cut.ext" "$T/old.ext" || fail "$1_nowrite"
    newboot; run verify
}
cut v_cut_after_write
bad verify verify_failed v_cut_after_write
ext dev1 | cmp -s - "$(ST cr52/previous.bin)" || fail v_cut_after_write_slot
cmp -s "$T/fix/good.elf" "$T/fw/actuation_x5h.elf" || fail v_cut_after_write_fw
[ "$(cat "$(ST pending)")" = 'cr52 rollback' ] || fail v_cut_after_write_pending
[ "$(sys | tail -n 1)" = reboot ] || fail "v_cut_after_write_reboot $(sys)"
run status
has 'X5H_OTA_STATUS component=cr52 version=baseline state=rolling_back slot=match' v_cut_after_write_status

cut v_cut_mid_write 28383
bad verify rollback_failed v_cut_mid_write
ext dev1 | cmp -s - "$T/cut.ext" || fail v_cut_mid_write_slot
[ "$(reboots)" = 0 ] || fail v_cut_mid_write_reboot
nopending v_cut_mid_write
run status
has 'X5H_OTA_STATUS component=cr52 version=baseline state=rollback_failed slot=mismatch' v_cut_mid_write_status

# A cut right after the restore's slot write (R24): the slot holds the
# previous payload, installed.env still names v1, nothing is staged.
reset_case; cr52up v_cut_restore; run activate; has 'X5H_OTA_PASS activate' v_cut_restore_act
hb 41; : > "$T/powercut"; newboot; run verify
[ ! -e "$T/powercut" ] || fail v_cut_restore_unused
hasnt 'X5H_OTA_FAIL verify reason=verify_failed' v_cut_restore_died
ext dev1 | cmp -s - "$(ST cr52/previous.bin)" || fail v_cut_restore_written
[ "$(cat "$(ST pending)")" = 'cr52 update' ] || fail v_cut_restore_pending_update
hb 7 8; newboot; run verify
bad verify verify_failed v_cut_restore
ext dev1 | cmp -s - "$(ST cr52/previous.bin)" || fail v_cut_restore_slot
cmp -s "$T/fix/good.elf" "$T/fw/actuation_x5h.elf" || fail v_cut_restore_fw
[ "$(cat "$(ST pending)")" = 'cr52 rollback' ] || fail v_cut_restore_pending
[ "$(sys | tail -n 1)" = reboot ] || fail "v_cut_restore_reboot $(sys)"
hb 9 10; newboot; run verify
has 'X5H_OTA_PASS verify' v_cut_restore_rb
run status
has 'X5H_OTA_STATUS component=cr52 version=baseline state=rolled_back slot=match' v_cut_restore_status

reset_case; vpup v_vp_pass; LM_STATE=inactive run activate; has X5H_OTA_REBOOT_REQUIRED v_vp_pass_act
vpj journal.boot ready; newboot; run verify
has 'X5H_OTA_PASS verify' v_vp_pass
nopending v_vp_pass
run status; has 'X5H_OTA_STATUS component=visionpilot version=v1 state=ok' v_vp_pass_status

# The ready line is there, but :latest is not the installed image.
reset_case; vpup v_vp_latest; LM_STATE=inactive run activate
vpj journal.boot ready; echo B > "$T/podman/tags/localhost_x5h-visionpilot_latest"
newboot; run verify; bad verify verify_failed v_vp_latest

reset_case; vpup v_vp_restart; LM_STATE=inactive run activate; has X5H_OTA_REBOOT_REQUIRED v_vp_restart_act
vpj journal.boot; vpj journal.after.1 ready; : > "$T/systemctl.log"
newboot; LM_STATE=active run verify
bad verify verify_failed v_vp_restart
[ "$(tagof latest)" = B ] || fail v_vp_restart_latest
[ "$(sys | grep -v '^is-active ')" = "$LMR" ] || fail "v_vp_restart_sys $(sys)"
nopending v_vp_restart
run status; has 'X5H_OTA_STATUS component=visionpilot version=none state=rolled_back' v_vp_restart_status

# restart_act <case> <file>...: stage A over B, mark the listed journal files
# ready, and activate with the launch manager active.
restart_act() {
    reset_case; vpup "$1"; shift
    vpj journal.boot; vpj journal.after.1; vpj journal.after.2
    for f; do vpj "$f" ready; done
    t0=$(date +%s); LM_STATE=active run activate
}
# START_SLEEP=1: a since taken after lm_restart is later than the start.
START_SLEEP=1 restart_act a_restart_pass journal.after.1
has 'X5H_OTA_PASS activate' a_restart_pass; hasnt X5H_OTA_REBOOT_REQUIRED a_restart_pass_reboot
[ "$rc" = 0 ] || fail a_restart_pass_rc
nopending a_restart_pass
[ "$(sys | grep -v '^is-active ')" = "$LMR" ] || fail "a_restart_pass_sys $(sys)"
[ "$(cat "$(ST last)")" = visionpilot ] || fail a_restart_pass_last
since=$(sed -n 's/.*--since @\([^ ]*\) .*/\1/p' "$T/journalctl.log" | head -n 1)
case $since in '' | *[!0-9]*) fail "a_restart_since_nan since=$since" ;; esac
[ "$since" -ge "$t0" ] && [ "$since" -le "$(head -n 1 "$T/start.at")" ] ||
    fail "a_restart_since since=$since t0=$t0 start=$(cat "$T/start.at")"
# -b: with a clock behind, lines of an earlier boot must not count (R32).
grep -qxF -- "-b --since @$since -t x5h-vp -o cat" "$T/journalctl.log" ||
    fail "a_restart_since_boot $(cat "$T/journalctl.log")"
run status; has 'X5H_OTA_STATUS component=visionpilot version=v1 state=ok' a_restart_pass_status

vpj journal.after.2 ready; LM_STATE=active run rollback
has 'X5H_OTA_PASS rollback' r_after_ok; hasnt X5H_OTA_REBOOT_REQUIRED r_after_ok_reboot
[ "$(tagof latest)" = B ] || fail r_after_ok_latest
[ "$(starts)" = 2 ] || fail "r_after_ok_starts $(sys)"
[ ! -e "$(ST last)" ] || fail r_after_ok_last
nopending r_after_ok
run status; has 'X5H_OTA_STATUS component=visionpilot version=none state=rolled_back' r_after_ok_status
LM_STATE=active run rollback; bad rollback nothing_to_roll_back r_twice
[ "$(tagof latest)" = B ] || fail r_twice_latest
[ "$(starts)" = 2 ] || fail r_twice_starts

# A cancelled v2 stage also forgets the last activate (R26): a retried cancel
# never restores the version before the good, active v1.
restart_act r_cancel journal.after.1; has 'X5H_OTA_PASS activate' r_cancel_act
mkimg D arm64 x5h.ota.component=visionpilot org.opencontainers.image.version=v2
VD2="$VP@sha256:$(printf 'b%.0s' $(seq 64))"; ref "$VD2" D
run install visionpilot "$VD2"; has 'X5H_OTA_PASS install' r_cancel_install
LM_STATE=active run rollback; has 'X5H_OTA_PASS rollback' r_cancel
[ ! -e "$(ST visionpilot/staged.env)" ] && [ -z "$(tagof staged)" ] || fail r_cancel_staged
[ ! -e "$(ST last)" ] || fail r_cancel_last
LM_STATE=active run rollback; bad rollback nothing_to_roll_back r_cancel_twice
[ "$(tagof latest)" = A ] || fail r_cancel_latest
[ "$(starts)" = 1 ] || fail r_cancel_starts

# The judge polls (TIMEOUT=3): the ready line shows only from the 2nd look.
reset_case; vpup a_poll; vpj journal.boot; vpj journal.after.1; vpj journal.late ready; echo 2 > "$T/late"
TIMEOUT=3 LM_STATE=active run activate
has 'X5H_OTA_PASS activate' a_poll
[ "$(cat "$T/since.calls")" = 2 ] || fail "a_poll_calls $(cat "$T/since.calls")"
[ "$(starts)" = 1 ] || fail a_poll_starts

# chrony steps the clock 30 days ahead after the first look (R32): the judge
# counts looks, so the second look still runs and passes.
reset_case; vpup a_clock_step; vpj journal.boot; vpj journal.after.1; vpj journal.late ready; echo 2 > "$T/late"
cat > "$T/bin/date" <<'EOF2'
#!/bin/sh
if [ "$*" = +%s ] && [ -f "$T/since.calls" ]; then echo $(($(/bin/date +%s) + 2592000)); exit 0; fi
exec /bin/date "$@"
EOF2
chmod +x "$T/bin/date"
TIMEOUT=3 LM_STATE=active run activate
has 'X5H_OTA_PASS activate' a_clock_step
[ "$(cat "$T/since.calls")" = 2 ] || fail "a_clock_step_calls $(cat "$T/since.calls")"

# The launch manager is down after the failed check (R25): the rollback waits
# for a reboot that the agent makes.
reset_case; vpup a_lm_down; vpj journal.boot; vpj journal.after.1; echo inactive > "$T/lm.after.1"
LM_STATE=active run activate
[ "$out" = $'X5H_OTA_REBOOT_REQUIRED\nX5H_OTA_FAIL activate reason=verify_failed' ] || fail "a_lm_down out=$out"
[ "$rc" = 1 ] || fail a_lm_down_rc
[ "$(cat "$(ST pending)")" = 'visionpilot rollback' ] || fail a_lm_down_pending
[ "$(starts)" = 1 ] || fail a_lm_down_starts
[ "$(reboots)" = 0 ] || fail a_lm_down_reboot
[ "$(tagof latest)" = B ] || fail a_lm_down_latest
run status; has 'X5H_OTA_STATUS component=visionpilot version=none state=rolling_back' a_lm_down_status

restart_act a_restart_rb journal.after.2
bad activate verify_failed a_restart_rb; hasnt X5H_OTA_REBOOT_REQUIRED a_restart_rb_reboot
[ "$(tagof latest)" = B ] || fail a_restart_rb_latest
[ "$(starts)" = 2 ] || fail a_restart_rb_starts
# TIMEOUT=0: each of the two judgments looks exactly once.
[ "$(cat "$T/since.calls")" = 2 ] || fail "a_restart_rb_looks $(cat "$T/since.calls")"
nopending a_restart_rb
[ ! -e "$(ST last)" ] || fail a_restart_rb_last
run status; has 'X5H_OTA_STATUS component=visionpilot version=none state=rolled_back' a_restart_rb_status

restart_act a_restart_both
bad activate rollback_failed a_restart_both
[ "$(starts)" = 2 ] || fail "a_restart_both_starts $(sys)"
[ "$(reboots)" = 0 ] || fail a_restart_both_reboot
nopending a_restart_both
run status; has 'X5H_OTA_STATUS component=visionpilot version=none state=rollback_failed' a_restart_both_status

# The ready line from before the restart (journal.boot) does not count (R7).
restart_act a_stale_line journal.boot journal.after.2
bad activate verify_failed a_stale_line
[ "$(tagof latest)" = B ] || fail a_stale_line_latest
run status; has 'X5H_OTA_STATUS component=visionpilot version=none state=rolled_back' a_stale_line_status

# ---- both components (R23) ----
both() {
    reset_case; vpup "$1"; cr52up "$1"; run activate
    has X5H_OTA_REBOOT_REQUIRED "$1_reboot"; has 'X5H_OTA_PASS activate' "$1"
}
both act_both
[ "$(cat "$(ST pending)")" = $'visionpilot update\ncr52 update' ] || fail act_both_pending
[ "$(cat "$(ST last)")" = $'visionpilot\ncr52' ] || fail act_both_last
for c in visionpilot cr52; do grep -qx version=v1 "$(ST $c/installed.env)" || fail "act_both_env $c"; done
hb 41 42; vpj journal.boot ready; newboot; run verify
has 'X5H_OTA_PASS verify' v_both_pass
nopending v_both_pass
run status
has 'X5H_OTA_STATUS component=cr52 version=v1 state=ok slot=match' v_both_pass_cr52
has 'X5H_OTA_STATUS component=visionpilot version=v1 state=ok' v_both_pass_vp

both v_both_act; hb 41 42; vpj journal.boot; newboot; run verify
bad verify verify_failed v_both_vp_fail
ext dev1 | cmp -s - "$(ST cr52/previous.bin)" || fail v_both_vp_fail_slot
[ "$(tagof latest)" = B ] || fail v_both_vp_fail_latest
[ "$(cat "$(ST pending)")" = $'visionpilot rollback\ncr52 rollback' ] || fail v_both_vp_fail_pending
[ "$(sys | tail -n 1)" = reboot ] || fail "v_both_vp_fail_reboot $(sys)"

# ---- a failed undo shows in status (R22) ----
reset_case; cr52up act_undo_fail; echo 2 > "$T/cpfail"
run activate; bad activate rollback_failed act_undo_fail
[ ! -e "$T/cpfail" ] || fail act_undo_fail_unused
nopending act_undo_fail
run status
has 'X5H_OTA_STATUS component=cr52 version=baseline state=rollback_failed slot=mismatch' act_undo_fail_status

reset_case
run verify; has 'X5H_OTA_PASS verify' v_nothing
[ "$rc" = 0 ] || fail v_nothing_rc
run verify now; bad verify usage verify_argc
exit 0 # the outer run prints TEST_PASS
