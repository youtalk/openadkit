#!/bin/sh
# x5h-ota: OTA hook for the X5H board. An update agent calls it to stage,
# apply and judge two components: the VisionPilot image and the CR52 slot.
#   x5h-ota init <payload-file>
#   x5h-ota install <visionpilot|cr52> <source>
#   x5h-ota activate | status | rollback
# (verify is added by a later change.)
# State and conf files are read with sed, never sourced: a version string
# comes from an artifact.
set -u

S=${X5H_OTA_STATE:-/var/lib/x5h-ota}
CONF=${X5H_OTA_CONF:-/etc/x5h-ota/cr52-slot.conf}
FW=${X5H_OTA_FIRMWARE:-/lib/firmware/actuation_x5h.elf}
LOCK=${X5H_OTA_LOCK:-/run/x5h-ota.lock}
DIRECT=${X5H_OTA_DIRECT-iflag=direct}
VPIMG=localhost/x5h-visionpilot
VPREPO=ghcr.io/youtalk/x5h-visionpilot
CRREPO=ghcr.io/youtalk/x5h-cr52-si

die() { printf 'X5H_OTA_FAIL %s reason=%s\n' "$1" "$2"; exit 1; }

env_get() { sed -n "/^$2=/{s///p;q;}" "$1" 2>/dev/null; }

# env_put <file> <key=value>...: replace the whole file through a temp file.
env_put() {
    f=$1; shift
    mkdir -p "$(dirname "$f")" && printf '%s\n' "$@" > "$f.tmp" && mv "$f.tmp" "$f"
}

valid_version() {
    case $1 in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
    [ ${#1} -le 64 ]
}

tagid() { podman image inspect -f '{{.Id}}' "$1" 2>/dev/null; }

# retag <tag> <id>: point $VPIMG:<tag> at <id>, or remove the tag for an empty
# id. Returns 0 only if the tag then holds <id>.
retag() {
    if [ -n "$2" ]; then podman tag "$2" "$VPIMG:$1"; else podman rmi "$VPIMG:$1"; fi > /dev/null 2>&1
    [ "$(tagid "$VPIMG:$1")" = "$2" ]
}

# drop_image <id>: remove an image that holds no name. Never fails.
drop_image() {
    if [ "$(podman image inspect -f '{{len .RepoTags}}' "$1" 2>/dev/null)" = 0 ]; then
        podman rmi "$1" > /dev/null 2>&1
    fi
    return 0
}

# fetch <component> <source>: print the full image ID.
# Returns 2 for bad_source and 3 for pull_failed.
fetch() {
    case $2 in
    /*)
        case $2 in *:*) return 2 ;; esac
        [ -f "$2" ] || return 2
        ref=oci-archive:$2 ;;
    *)
        if [ "$1" = visionpilot ]; then repo=$VPREPO; else repo=$CRREPO; fi
        case $2 in "$repo"@sha256:*) h=${2#"$repo"@sha256:} ;; *) return 2 ;; esac
        [ ${#h} -eq 64 ] || return 2
        case $h in *[!0-9a-f]*) return 2 ;; esac
        ref=$2 ;;
    esac
    # A pulled archive applies the name stored in it. Put the hook's tags back
    # if the pull moved any of them (podman 4.x moves :latest).
    o1=$(tagid "$VPIMG:latest"); o2=$(tagid "$VPIMG:previous"); o3=$(tagid "$VPIMG:staged")
    id=$(podman pull -q "$ref" 2>/dev/null) || return 3
    id=$(podman image inspect -f '{{.Id}}' "$id" 2>/dev/null) || return 3
    moved=0
    for t in latest:"$o1" previous:"$o2" staged:"$o3"; do
        [ "$(tagid "$VPIMG:${t%%:*}")" = "${t#*:}" ] && continue
        moved=1; retag "${t%%:*}" "${t#*:}"
    done
    if [ $moved = 1 ]; then drop_image "$id"; return 2; fi
    printf '%s\n' "$id"
}

# conf_load: set SLOT_SKIP and SLOT_SECTORS, or return 1.
conf_load() {
    SLOT_SKIP=$(env_get "$CONF" SLOT_SKIP); SLOT_SECTORS=$(env_get "$CONF" SLOT_SECTORS)
    for v in "$SLOT_SKIP" "$SLOT_SECTORS"; do
        case $v in '' | *[!0-9]*) return 1 ;; esac
    done
}

label() { podman image inspect -f "{{index .Labels \"$2\"}}" "$1" 2>/dev/null; }
sum() { sha256sum "$1" | { read -r h _; echo "$h"; }; }

# stage <component> <image id>: check the image and write the staged state.
# On failure it sets $reason and returns 1.
stage() {
    ver=$(label "$2" org.opencontainers.image.version)
    [ "$(label "$2" x5h.ota.component)" = "$1" ] || { reason=bad_label; return 1; }
    valid_version "$ver" || { reason=bad_version; return 1; }
    [ "$(podman image inspect -f '{{.Architecture}}' "$2" 2>/dev/null)" = arm64 ] ||
        { reason=bad_arch; return 1; }
    if [ "$1" = visionpilot ]; then
        podman tag "$2" "$VPIMG:staged" || { reason=pull_failed; return 1; }
        env_put "$S/visionpilot/staged.env" "version=$ver" "image=$2" ||
            { reason=state_write; return 1; }
        return 0
    fi
    w=$S/cr52/work
    mkdir -p "$S/cr52" || { reason=state_write; return 1; }
    mnt=$(podman image mount "$2" 2>/dev/null) || { reason=mount_failed; return 1; }
    # The source is not trusted: no symlinks, and the payload copy has a cap.
    [ -d "$mnt/cr52" ] && [ ! -h "$mnt/cr52" ] || { reason=bad_hash; return 1; }
    for f in slot.bin actuation_x5h.elf; do
        [ -f "$mnt/cr52/$f" ] && [ ! -h "$mnt/cr52/$f" ] || { reason=bad_hash; return 1; }
    done
    max=$((SLOT_SECTORS * 4096))
    head -c $((max + 1)) "$mnt/cr52/slot.bin" > "$w.bin" && cp "$mnt/cr52/actuation_x5h.elf" "$w.elf" ||
        { reason=state_write; return 1; }
    bytes=$(($(wc -c < "$w.bin")))
    [ "$bytes" -le "$max" ] || { reason=too_large; return 1; }
    h1=$(sum "$w.bin"); h2=$(sum "$w.elf")
    [ "$h1" = "$(label "$2" x5h.ota.sha256)" ] && [ "$h2" = "$(label "$2" x5h.ota.elf_sha256)" ] ||
        { reason=bad_hash; return 1; }
    # Eight words, each an "ldr pc, [pc, #imm]" (little-endian e59ff...).
    set -- $(od -v -A n -t x4 -N 32 "$w.bin")
    [ $# -eq 8 ] || { reason=no_vector_table; return 1; }
    for x; do
        case $x in e59ff[0-9a-f][0-9a-f][0-9a-f]) ;; *) reason=no_vector_table; return 1 ;; esac
    done
    [ "$(head -c 4 "$w.elf" | od -A n -t x1 | tr -d ' \n')" = 7f454c46 ] ||
        { reason=no_elf_magic; return 1; }
    mv "$w.bin" "$S/cr52/staged.bin" && mv "$w.elf" "$S/cr52/staged.elf" &&
        env_put "$S/cr52/staged.env" "version=$ver" "sha256=$h1" "elf_sha256=$h2" "bytes=$bytes" ||
        { reason=state_write; return 1; }
}

cmd_install() {
    if [ "$1" = cr52 ] && ! conf_load; then die install no_conf; fi
    id=$(fetch "$1" "$2"); r=$?
    case $r in 0) ;; 2) die install bad_source ;; *) die install pull_failed ;; esac
    stage "$1" "$id"; r=$?
    # Cleanup never fails the command.
    if [ "$1" = cr52 ]; then
        podman image unmount "$id" > /dev/null 2>&1
        rm -f "$S/cr52/work.bin" "$S/cr52/work.elf"
        drop_image "$id"
    elif [ "$r" != 0 ]; then
        drop_image "$id"
    fi
    [ "$r" = 0 ] || die install "$reason"
    echo 'X5H_OTA_PASS install'
}

# discard_staged <component>: drop a staged update that was never applied.
discard_staged() {
    [ -f "$S/$1/staged.env" ] || return 1
    rm -f "$S/$1/staged.env" "$S/$1/staged.bin" "$S/$1/staged.elf"
    [ "$1" != visionpilot ] || podman rmi "$VPIMG:staged" > /dev/null 2>&1
    return 0
}

# ponytail: only staged components roll back here; the activated-version
# restore is a later change.
cmd_rollback() {
    n=0
    for c in cr52 visionpilot; do discard_staged "$c" && n=1; done
    [ "$n" = 1 ] || die rollback nothing_to_roll_back
    echo 'X5H_OTA_PASS rollback'
}

# devices: each whole UFS device once. Two names of one device are one device.
devices() {
    seen=
    for d in ${X5H_OTA_DEVICES:-/dev/disk/by-path/platform-*ufs*}; do
        case ${d##*/} in *-part*) continue ;; esac
        d=$(readlink -f "$d") && [ -e "$d" ] || continue
        case " $seen " in *" $d "*) continue ;; esac
        seen="$seen $d"; printf '%s\n' "$d"
    done
}

# slot_find <sha256> <bytes>: print the one device whose first <bytes> at
# SLOT_SKIP have that hash. Returns 2 for none and 3 for more than one.
slot_find() {
    case $2 in '' | *[!0-9]*) return 2 ;; esac
    n=0
    for d in $(devices); do
        got=$(dd if="$d" bs=4096 skip="$SLOT_SKIP" count=$((($2 + 4095) / 4096)) 2>/dev/null |
            head -c "$2" | sha256sum)
        [ "${got%% *}" = "$1" ] || continue
        n=$((n + 1)); found=$d
    done
    [ "$n" -gt 0 ] || return 2
    [ "$n" -eq 1 ] || return 3
    printf '%s\n' "$found"
}

# slot_write <dev> <extent-file>: write, flush, and compare a direct read-back.
# Call it in the main shell, never in $(...) or a pipeline: the power-cut
# test kills the parent of blockdev.
slot_write() {
    dd if="$2" of="$1" bs=4096 seek="$SLOT_SKIP" conv=notrunc,fsync 2>/dev/null &&
        blockdev --flushbufs "$1" &&
        dd if="$1" bs=4096 skip="$SLOT_SKIP" count="$SLOT_SECTORS" $DIRECT 2>/dev/null | cmp -s - "$2"
}

# slot_check: slot=match|mismatch for an installed cr52.
slot_check() {
    e=$S/cr52/installed.env
    if conf_load && [ -f "$FW" ] && [ "$(sum "$FW")" = "$(env_get "$e" elf_sha256)" ] &&
        slot_find "$(env_get "$e" sha256)" "$(env_get "$e" bytes)" > /dev/null; then
        echo match
    else
        echo mismatch
    fi
}

cmd_init() {
    conf_load || die init no_conf
    [ -f "$FW" ] || die init no_firmware
    [ -f "$1" ] && bytes=$(($(wc -c < "$1"))) &&
        [ "$bytes" -gt 0 ] && [ "$bytes" -le $((SLOT_SECTORS * 4096)) ] || die init slot_not_found
    h=$(sum "$1")
    slot_find "$h" "$bytes" > /dev/null; r=$?
    case $r in 0) ;; 3) die init slot_ambiguous ;; *) die init slot_not_found ;; esac
    env_put "$S/cr52/installed.env" version=baseline state=ok "sha256=$h" \
        "elf_sha256=$(sum "$FW")" "bytes=$bytes" || die init state_write
    echo 'X5H_OTA_PASS init'
}

# start_kind <components>: how the update starts, reboot or restart.
# ponytail: always reboot until the restart path exists (a later change).
start_kind() { echo reboot; }

# undo <reason>: put back what activate changed, keep the staged state, fail.
# Called in the main shell, so slot_write keeps its parent.
undo() {
    r=$1
    rm -f "$S/cr52/full.bin" "$S/cr52/installed.env.tmp" "$S/visionpilot/installed.env.tmp" "$S/last.tmp"
    if [ "$wrote" = 1 ]; then slot_write "$dev" "$S/cr52/previous.bin" || r=rollback_failed; fi
    if [ "$fwc" = 1 ]; then
        cmp -s "$S/cr52/previous.elf" "$FW" || cp "$S/cr52/previous.elf" "$FW" || r=rollback_failed
    fi
    if [ "$vpb" = 1 ]; then
        retag latest "$old_latest" || r=rollback_failed
        retag previous "$old_prev" || r=rollback_failed
    fi
    rm -f "$S/pending"; sync
    die activate "$r"
}

# activate: apply every staged component, visionpilot first in each phase.
# A: save the previous version and add the pending line. B: apply. C: record.
# A failure in A, B or the records of C runs undo. pending did not exist before
# (verify_pending), so every pending line is ours.
cmd_activate() {
    list=
    for c in visionpilot cr52; do [ ! -f "$S/$c/staged.env" ] || list="$list $c"; done
    [ -n "$list" ] || die activate nothing_staged
    e=$S/cr52/installed.env
    case $list in *cr52*)
        conf_load || die activate no_conf
        [ -f "$FW" ] || die activate no_firmware
        # Never write past the extent, even if the conf changed after the install.
        [ "$(($(wc -c < "$S/cr52/staged.bin")))" -le $((SLOT_SECTORS * 4096)) ] || die activate too_large
        dev=$(slot_find "$(env_get "$e" sha256)" "$(env_get "$e" bytes)"); r=$?
        case $r in 0) ;; 3) die activate slot_ambiguous ;; *) die activate slot_not_found ;; esac ;;
    esac
    old_latest=$(tagid "$VPIMG:latest"); old_prev=$(tagid "$VPIMG:previous")
    vpb=0 wrote=0 fwc=0
    rm -f "$S/last"
    for c in $list; do
        if [ "$c" = visionpilot ]; then
            v=$(env_get "$S/visionpilot/installed.env" version)
            env_put "$S/visionpilot/previous.env" "version=${v:-none}" state=ok "image=$old_latest"
        else
            p=$S/cr52/previous
            dd if="$dev" of="$p.bin" bs=4096 skip="$SLOT_SKIP" count="$SLOT_SECTORS" $DIRECT 2>/dev/null &&
                [ "$(($(wc -c < "$p.bin")))" -eq $((SLOT_SECTORS * 4096)) ] &&
                cp "$FW" "$p.elf" &&
                env_put "$p.env" "version=$(env_get "$e" version)" state=ok "sha256=$(env_get "$e" sha256)" \
                    "elf_sha256=$(sum "$p.elf")" "bytes=$(env_get "$e" bytes)"
        fi && echo "$c update" >> "$S/pending" || undo state_write
    done
    sync
    for c in $list; do
        if [ "$c" = visionpilot ]; then
            vpb=1
            { [ -z "$old_latest" ] || podman tag "$old_latest" "$VPIMG:previous"; } &&
                podman tag "$(env_get "$S/visionpilot/staged.env" image)" "$VPIMG:latest" || undo state_write
        else
            full=$S/cr52/full.bin
            { dd if=/dev/zero bs=4096 count="$SLOT_SECTORS" 2>/dev/null | tr '\000' '\377' > "$full" &&
                dd if="$S/cr52/staged.bin" of="$full" conv=notrunc 2>/dev/null; } || undo state_write
            wrote=1
            slot_write "$dev" "$full" || undo write_mismatch
            fwc=1
            cp "$S/cr52/staged.elf" "$FW" && sync || undo firmware_write
        fi
    done
    # Write every record first, then move them in: a full disk fails before any move.
    # ponytail: a failed rename after an earlier one leaves that installed.env new.
    for c in $list; do
        { cat "$S/$c/staged.env" && echo state=ok; } > "$S/$c/installed.env.tmp" || undo state_write
    done
    printf '%s\n' $list > "$S/last.tmp" || undo state_write
    for c in $list; do mv "$S/$c/installed.env.tmp" "$S/$c/installed.env" || undo state_write; done
    mv "$S/last.tmp" "$S/last" || undo state_write
    sync
    # Cleanup never fails the command.
    rm -f "$S/cr52/full.bin"
    for c in $list; do discard_staged "$c"; done
    [ "$vpb" = 0 ] || [ -z "$old_prev" ] || drop_image "$old_prev"
    if [ "$(start_kind "$list")" = reboot ]; then echo X5H_OTA_REBOOT_REQUIRED; fi
    echo 'X5H_OTA_PASS activate'
}

cmd_status() {
    for c in cr52 visionpilot; do
        e=$S/$c/installed.env
        v=$(env_get "$e" version); st=$(env_get "$e" state)
        p=$(sed -n "s/^$c //p" "$S/pending" 2>/dev/null | head -n 1)
        case $p in
        rollback) st=rolling_back ;;
        ?*) st=verifying ;;
        *) [ ! -f "$S/$c/staged.env" ] || st=staged ;;
        esac
        extra=
        [ "$c" != cr52 ] || [ ! -f "$e" ] || extra=" slot=$(slot_check)"
        echo "X5H_OTA_STATUS component=$c version=${v:-none} state=${st:-ok}$extra"
    done
}

cmd=${1:-}
case $cmd in
install) [ $# -eq 3 ] || die install usage ;;
init) [ $# -eq 2 ] || die init usage ;;
activate | status | rollback) [ $# -eq 1 ] || die "$cmd" usage ;;
*) die usage usage ;;
esac
if [ "$cmd" = install ]; then
    case $2 in visionpilot | cr52) ;; *) die install bad_component ;; esac
fi
{ exec 9> "$LOCK" && flock -w 600 9; } || die "$cmd" lock
if [ "$cmd" != status ] && [ -e "$S/pending" ]; then die "$cmd" verify_pending; fi
case $cmd in
install) cmd_install "$2" "$3" ;;
init) cmd_init "$2" ;;
activate) cmd_activate ;;
rollback) cmd_rollback ;;
status) cmd_status ;;
esac
