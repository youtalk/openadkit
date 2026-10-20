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
    local fstype mounted
    fstype=$(run 'findmnt -n -o FSTYPE /') || die board_unreachable
    case $fstype in nfs|nfs4) ;; *) die not_in_rescue ;; esac
    # `; true` keeps grep's "no match" apart from a transport failure (255).
    mounted=$(run "grep '^/dev/sd' /proc/mounts; true") || die board_unreachable
    [ -z "$mounted" ] || die ufs_mounted
}

# "<by-path> <bytes>" for every UFS1 LU, partitions excluded. Callers run it
# in $(...), so it returns its status instead of dying in the subshell.
lus() {
    run "for p in $LU:*; do case \$p in *-part*) continue ;; esac; echo \"\$p \$(blockdev --getsize64 \$p)\"; done"
}

backup() {
    # Any image or metadata means an earlier run used this directory: the
    # sums and sizes would be appended to, and restore would read two values.
    local f
    for f in "$dir"/*.img.zst "$dir/SHA256SUMS" "$dir/sizes.txt" "$dir/board"; do
        [ -e "$f" ] && die backup_dir_not_empty
    done
    rescue_check
    local l n
    l=$(lus) || die layout_probe_failed
    n=$(printf '%s\n' "$l" | grep -c .)
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
    # Written last: it marks the backup complete and binds it to this board,
    # because the pinned PARTUUIDs are the same on both boards.
    echo "$board" > "$dir/board" || die stamp_failed
    echo "${P}_PASS"
}

# The new GPT keeps every label and GUID of the two-LUN map, so the kernel
# command line, the mount units and U-Boot (partition 1 of the LU) all find
# their partitions unchanged. Only the sizes and the partition numbers change.
SIZES=(+1G +24G +128G +1G +8G 0)
SUFFIX=(01 02 03 11 12 13)
GUID=7c94f5e2-9e2b-4c31-8f0a-1a2b3c4d5e

restore() {
    rescue_check
    local l n dev name f args="" i=0 real p want bytes got
    l=$(lus) || die layout_probe_failed
    n=$(printf '%s\n' "$l" | grep -c .)
    [ "$n" -eq 1 ] && printf '%s\n' "$l" | grep -qxF "$LU:0 255944818688" || die not_single_lu
    for name in $LABELS lu0; do [ -e "$dir/$name.img.zst" ] || die backup_incomplete; done
    for f in SHA256SUMS sizes.txt blkid.txt board; do [ -e "$dir/$f" ] || die backup_incomplete; done
    [ "$(cat "$dir/board")" = "$board" ] || die backup_of_other_board
    dev=$LU:0
    for name in $LABELS; do
        args="$args -n$((i + 1)):0:${SIZES[i]} -t$((i + 1)):8300 -c$((i + 1)):$name -u$((i + 1)):$GUID${SUFFIX[i]}"
        i=$((i + 1))
    done
    echo "PLAN: this DESTROYS everything on $dev of $board ($ip). Its current table:"
    run "sgdisk -p $dev 2>&1" | sed 's/^/| /'
    echo "PLAN: sgdisk -o$args $dev"
    echo "PLAN: write each <label>.img.zst from $dir to /dev/disk/by-partlabel/<label>, sha256 checked"
    echo "PLAN: grow x5h-root and npu-work (resize2fs) and autosd-store (btrfs resize max)"
    need_yes

    run "sgdisk -o$args $dev >/dev/null && blockdev --rereadpt $dev && udevadm settle" || die partition_failed
    # udev can still hold the OLD by-partlabel links; prove each one is on the new LU.
    real=$(run "readlink -f $dev") || die readlink_failed
    for name in $LABELS; do
        p=$(run "readlink -f /dev/disk/by-partlabel/$name") || die "partlabel_missing_$name"
        case $p in "$real"[0-9]*) ;; *) die "partlabel_not_on_target_$name" ;; esac
    done
    for name in $LABELS; do
        echo "== $name"
        want=$(awk -v n="$name" '$2 == n {print $1}' "$dir/SHA256SUMS")
        bytes=$(awk -v n="$name" '$1 == n {print $2}' "$dir/sizes.txt")
        [ -n "$want" ] && [ -n "$bytes" ] || die "backup_incomplete_$name"
        zstd -dc "$dir/$name.img.zst" \
            | ssh "${SSHO[@]}" "root@$ip" "dd of=/dev/disk/by-partlabel/$name bs=4M conv=fsync status=none" \
            || die "write_$name"
        # flushbufs drops the cached pages, so the hash reads the device.
        got=$(run "blockdev --flushbufs /dev/disk/by-partlabel/$name && head -c $bytes /dev/disk/by-partlabel/$name | sha256sum" | cut -c1-64) \
            || die "remote_hash_$name"
        [ "$got" = "$want" ] || die "hash_mismatch_$name"
    done
    # e2fsck -p exits 1 when it fixed something, which is still a usable fs.
    for name in x5h-root npu-work; do
        p=/dev/disk/by-partlabel/$name
        run "e2fsck -f -p $p; [ \$? -le 1 ] && resize2fs $p" > "$dir/grow-$name.txt" 2>&1 || die "grow_$name"
    done
    run 'm=$(mktemp -d) && mount /dev/disk/by-partlabel/autosd-store $m && { btrfs filesystem resize max $m; r=$?; umount $m; rmdir $m; exit $r; }' \
        > "$dir/grow-autosd-store.txt" 2>&1 || die grow_autosd-store
    for name in $LABELS; do
        want=$(grep "PARTLABEL=\"$name\"" "$dir/blkid.txt" | grep -oE ' (UUID|PARTUUID)="[^"]*"' | sort | tr -d '\n')
        got=$(run "blkid /dev/disk/by-partlabel/$name" | grep -oE ' (UUID|PARTUUID)="[^"]*"' | sort | tr -d '\n')
        [ -n "$want" ] && [ "$got" = "$want" ] || die "id_mismatch_$name"
    done
    echo "${P}_PASS"
}

case $cmd in
    backup) backup ;;
    restore) restore ;;
esac
