#!/usr/bin/env bash
# make-ufs-rootfs.sh — derive a dd-able ext4 rootfs image from the aib CI tar.
# Same reassembly the CI gate uses: xattrs must survive (capabilities,
# selinux labels), so plain `tar xf` is wrong here.
# Usage: make-ufs-rootfs.sh <x5h-rootfs.tar> <out.ext4> [size (default 6G)]
set -euo pipefail
tar_in=$1 out=$2 size=${3:-6G}
[ -s "$tar_in" ] || { echo "FATAL: tar not found: $tar_in" >&2; exit 1; }
truncate -s "$size" "$out"
# -F: a rerun leaves the previous superblock in the (same-size) file and
# mkfs would stop to ask about it — this script must run unattended.
mkfs.ext4 -q -F -L x5h-root "$out"
mnt=$(mktemp -d)
trap 'sudo umount "$mnt" 2>/dev/null || true; rmdir "$mnt"' EXIT
sudo mount -o loop "$out" "$mnt"
sudo tar --xattrs --xattrs-include='*.*' -xf "$tar_in" -C "$mnt"
sudo test -x "$mnt/usr/bin/podman" || { echo "FATAL: podman missing in image" >&2; exit 1; }
sudo umount "$mnt"
echo "MAKE_UFS_ROOTFS_OK $out"
