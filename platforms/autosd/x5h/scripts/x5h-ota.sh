#!/bin/sh
# x5h-ota: OTA hook for the X5H board. An update agent calls it to stage,
# apply and judge two components: the VisionPilot image and the CR52 slot.
#   x5h-ota install <visionpilot|cr52> <source>
#   x5h-ota status | rollback
# (init, activate and verify are added by later changes.)
# State and conf files are read with sed, never sourced: a version string
# comes from an artifact.
set -u

S=${X5H_OTA_STATE:-/var/lib/x5h-ota}
CONF=${X5H_OTA_CONF:-/etc/x5h-ota/cr52-slot.conf}
FW=${X5H_OTA_FIRMWARE:-/lib/firmware/actuation_x5h.elf}
LOCK=${X5H_OTA_LOCK:-/run/x5h-ota.lock}
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
        moved=1
        if [ -n "${t#*:}" ]; then podman tag "${t#*:}" "$VPIMG:${t%%:*}"
        else podman rmi "$VPIMG:${t%%:*}" > /dev/null 2>&1; fi
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
# restore is added with `activate`.
cmd_rollback() {
    n=0
    for c in cr52 visionpilot; do discard_staged "$c" && n=1; done
    [ "$n" = 1 ] || die rollback nothing_to_roll_back
    echo 'X5H_OTA_PASS rollback'
}

# slot_check: slot=match|mismatch for an installed cr52.
# ponytail: stub until `slot_find` exists; no installed.env exists before then.
slot_check() { echo mismatch; }

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
status | rollback) [ $# -eq 1 ] || die "$cmd" usage ;;
*) die usage usage ;;
esac
if [ "$cmd" = install ]; then
    case $2 in visionpilot | cr52) ;; *) die install bad_component ;; esac
fi
{ exec 9> "$LOCK" && flock -w 600 9; } || die "$cmd" lock
if [ "$cmd" != status ] && [ -e "$S/pending" ]; then die "$cmd" verify_pending; fi
case $cmd in
install) cmd_install "$2" "$3" ;;
rollback) cmd_rollback ;;
status) cmd_status ;;
esac
