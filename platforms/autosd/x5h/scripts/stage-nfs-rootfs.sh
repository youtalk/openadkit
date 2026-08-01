#!/usr/bin/env bash
# Stage the AutoSD tar export as an NFS root for the X5H board.
# Usage: stage-nfs-rootfs.sh <x5h-rootfs.tar> <bsp-rootfs-dir> <dest-dir> <testimages-dir>
# <bsp-rootfs-dir>: the existing BSP NFS root (source of the kernel modules).
# Run as root on the NFS server host. The BSP export is never modified.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TARBALL="$1"; BSP="$2"; DEST="$3"; IMAGES="$4"
KVER=6.1.102-yocto-standard
[ -d "$BSP/lib/modules/$KVER" ] || { echo "FATAL: $BSP/lib/modules/$KVER not found"; exit 1; }
[ -e "$DEST" ] && { echo "FATAL: $DEST exists — refusing to overwrite"; exit 1; }
mkdir -p "$DEST"
tar xf "$TARBALL" -C "$DEST"
# The BSP kernel's modules (overlayfs, veth, bridge, x_tables... are all =m).
cp -a "$BSP/lib/modules/$KVER" "$DEST/lib/modules/"
# fstab was written for a disk image; on NFS root every entry is wrong.
[ -f "$DEST/etc/fstab" ] && mv "$DEST/etc/fstab" "$DEST/etc/fstab.image" && : > "$DEST/etc/fstab"
# Test payload (same layout the QEMU gate used).
mkdir -p "$DEST/var/lib/autosd-test"
cp "$IMAGES/busybox-oci.tar" "$IMAGES/captest-docker.tar" "$HERE/gate-guest.sh" \
   "$HERE/board-podman-smoke.sh" "$DEST/var/lib/autosd-test/"
chmod +x "$DEST/var/lib/autosd-test/"*.sh
echo "OK: staged at $DEST — now add it to /etc/exports (mirror the BSP export line) and run: exportfs -ra"
