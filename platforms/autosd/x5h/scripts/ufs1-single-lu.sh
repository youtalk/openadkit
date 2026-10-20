#!/usr/bin/env bash
# Move a board's UFS1 from the factory three-LU map to one LU that holds the
# whole device, without re-staging it. Run on the companion, with the board in
# the AutoSD NFS rescue (`run rescue_autosd`), so nothing on UFS1 is mounted.
#
#   ufs1-single-lu.sh <x5h1|x5h2> <backup-dir> backup  [--yes]
#       raw images of the six partitions and of LU 0, hashed on both ends
#   (manual) the operator rewrites the UFS1 Configuration Descriptor and
#       power cycles the board -- see selfboot.md, "Single-LU UFS1"
#   ufs1-single-lu.sh <x5h1|x5h2> <backup-dir> restore [--yes]
#       the same labels, GUIDs and images on the single LU, then grown
#
# Without --yes a subcommand prints its plan and stops. Exactly one marker per
# run: UFS1_FAIL reason=bad_args (exit 2), <PREFIX>_PASS, <PREFIX>_FAIL
# reason=<slug>, or PLAN ONLY.
set -u -o pipefail
here=$(cd "$(dirname "$0")" && pwd)
board=${1:-}; dir=${2:-}; cmd=${3:-}; yes=${4:-}
bad_args() { echo "UFS1_FAIL reason=bad_args"; exit 2; }
case $board in x5h1|x5h2) ;; *) bad_args ;; esac
case $cmd in backup) P=UFS1_BACKUP ;; restore) P=UFS1_RESTORE ;; *) bad_args ;; esac
[ -n "$dir" ] || bad_args
die() { echo "${P}_FAIL reason=$1"; exit 1; }
need_yes() { [ "$yes" = --yes ] || { echo "PLAN ONLY: re-run with --yes to execute the above on $board ($ip)"; exit 0; }; }

ip=$(sed -n 's/^BOARD_IP=//p' "$here/../boards/$board.vars" 2>/dev/null | head -1)
[ -n "$ip" ] || die no_board_ip
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes)
run() { ssh -n "${SSHO[@]}" "root@$ip" "$1"; }

LABELS="x5h-boot x5h-root autosd-store yocto-boot yocto-root npu-work"
LU=/dev/disk/by-path/platform-c0a90000.ufs-scsi-0:0:0

# The board must run from the NFS rescue with no UFS partition mounted: a raw
# image of a mounted filesystem is not consistent, and a write would corrupt it.
rescue_check() {
    local fstype
    fstype=$(run 'findmnt -n -o FSTYPE /') || die board_unreachable
    case $fstype in nfs|nfs4) ;; *) die not_in_rescue ;; esac
    [ -z "$(run "grep '^/dev/sd' /proc/mounts")" ] || die ufs_mounted
}

# "<by-path> <bytes>" for every UFS1 LU, partitions excluded.
lus() {
    run "for p in $LU:*; do case \$p in *-part*) continue ;; esac; echo \"\$p \$(blockdev --getsize64 \$p)\"; done" \
        || die layout_probe_failed
}

backup() {
    ls "$dir"/*.img.zst >/dev/null 2>&1 && die backup_dir_not_empty
    rescue_check
    local l n
    l=$(lus); n=$(printf '%s\n' "$l" | grep -c .)
    [ "$n" -eq 3 ] && printf '%s\n' "$l" | grep -qxF "$LU:0 402653184" || die not_three_lu_layout
    echo "PLAN: e2fsck -n / btrfs check --readonly on: $LABELS"
    echo "PLAN: dd each partition and $LU:0 from $ip, zstd into $dir, sha256 on both ends"
    need_yes

    mkdir -p "$dir" || die mkdir_failed
    run 'lsblk -b -o NAME,SIZE,TYPE,PARTLABEL,PARTUUID,UUID,FSTYPE' > "$dir/lsblk.txt" || die lsblk_failed
    run 'blkid' > "$dir/blkid.txt" || die blkid_failed
    for n in 1 2; do
        run "sgdisk --backup=/tmp/lu$n.gpt $LU:$n >/dev/null && cat /tmp/lu$n.gpt" > "$dir/lu$n.gpt" || die "gpt_backup_lu$n"
    done
    local name dev c h rh sz
    for name in $LABELS; do
        case $name in
            autosd-store) c="btrfs check --readonly /dev/disk/by-partlabel/$name" ;;
            *) c="e2fsck -n /dev/disk/by-partlabel/$name" ;;
        esac
        run "$c" > "$dir/fsck-$name.txt" 2>&1 || die "fsck_$name"
    done
    for name in $LABELS lu0; do
        case $name in lu0) dev=$LU:0 ;; *) dev=/dev/disk/by-partlabel/$name ;; esac
        echo "== $name"
        ssh "${SSHO[@]}" "root@$ip" "dd if=$dev bs=4M iflag=direct status=none" < /dev/null \
            | zstd -T0 -3 -q > "$dir/$name.img.zst" || die "stream_$name"
        h=$(zstd -dc "$dir/$name.img.zst" | sha256sum | cut -c1-64) || die "local_hash_$name"
        rh=$(run "sha256sum $dev" | cut -c1-64) || die "remote_hash_$name"
        [ "$h" = "$rh" ] || die "hash_mismatch_$name"
        sz=$(run "blockdev --getsize64 $dev") || die "size_$name"
        printf '%s  %s\n' "$h" "$name" >> "$dir/SHA256SUMS"
        printf '%s %s\n' "$name" "$sz" >> "$dir/sizes.txt"
    done
    echo "${P}_PASS"
}

case $cmd in
    backup) backup ;;
    restore) die not_implemented ;;
esac
