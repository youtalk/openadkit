#!/usr/bin/env bash
# Stage the rebuilt 6.1.102-autosd kernel onto an ALREADY-STAGED AutoSD NFS
# root (stage-nfs-rootfs.sh must have completed — its stamp is checked) and
# into the TFTP directory. Strictly additive: no BSP kernel file or module
# tree is touched, so the same NFS root keeps booting under either kernel
# and rollback is one U-Boot variable away.
# Usage: stage-rebuilt-kernel.sh <staged-nfs-root> <kernel-bundle-dir> <tftp-dir>
# Run as root on the NFS server host.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$1"; BUNDLE="$2"; TFTP="$3"
[ -f "$DEST/.x5h-stage-complete" ] \
    || { echo "FATAL: $DEST has no .x5h-stage-complete stamp (run stage-nfs-rootfs.sh first)"; exit 1; }
KVER="$(cat "$BUNDLE/kernelrelease.txt")"
[ -f "$BUNDLE/Image-autosd" ] || { echo "FATAL: $BUNDLE/Image-autosd not found"; exit 1; }
[ -f "$BUNDLE/modules-$KVER.tar" ] || { echo "FATAL: $BUNDLE/modules-$KVER.tar not found"; exit 1; }
tar -xf "$BUNDLE/modules-$KVER.tar" -C "$DEST"
[ -d "$DEST/lib/modules/$KVER" ] \
    || { echo "FATAL: module tree not at $DEST/lib/modules/$KVER after extract"; exit 1; }
# depmod is arch-independent; the x86 NFS host can index aarch64 modules.
depmod -b "$DEST" "$KVER"
[ -f "$DEST/lib/modules/$KVER/modules.dep" ] \
    || { echo "FATAL: depmod produced no modules.dep"; exit 1; }
install -D -m 0644 "$HERE/../config/60-nftables.conf" \
    "$DEST/etc/containers/containers.conf.d/60-nftables.conf"
install -m 0644 "$BUNDLE/Image-autosd" "$TFTP/Image-autosd"
install -m 0644 "$BUNDLE/r8a78000-ironhide-uio-autosd.dtb" "$TFTP/r8a78000-ironhide-uio-autosd.dtb"
echo "OK: $KVER staged into $DEST and $TFTP"
echo "U-Boot (rebuilt): setenv kernel_file Image-autosd ; setenv dtb_file r8a78000-ironhide-uio-autosd.dtb ; setenv selinux_arg enforcing=0"
echo "U-Boot (rollback): setenv kernel_file Image ; setenv dtb_file <bsp-dtb> ; setenv selinux_arg selinux=0"
