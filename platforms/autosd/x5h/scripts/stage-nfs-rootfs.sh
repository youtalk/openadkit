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
[ -e "$DEST" ] && { echo "FATAL: $DEST exists — refusing to overwrite (rm -rf it and rerun if a previous stage failed partway)"; exit 1; }
mkdir -p "$DEST"
tar xf "$TARBALL" -C "$DEST"
# The BSP kernel's modules (overlayfs, veth, bridge, x_tables... are all =m).
# mkdir the destination explicitly first: GNU `cp -a src dest` copies src AS
# dest (losing the $KVER name entirely, and exiting 0) whenever dest's parent
# exists but dest itself does not -- the assert right after catches that
# instead of staging a rootfs where modprobe finds nothing.
mkdir -p "$DEST/lib/modules"
cp -a "$BSP/lib/modules/$KVER" "$DEST/lib/modules/"
[ -d "$DEST/lib/modules/$KVER" ] || { echo "FATAL: module tree not at $DEST/lib/modules/$KVER after copy"; exit 1; }
# fstab was written for a disk image; on NFS root every entry is wrong. A
# missing fstab (plausible from a podman-export-derived rootfs) is a
# harmless no-op below. An `mv` that exists but fails must abort the script:
# it is a plain statement inside this `if`'s body, not part of an `&&` list,
# so `set -e` does apply to its failure here (unlike a `[ -f x ] && mv ...`
# one-liner, where only the failure of the *last* list member is fatal).
if [ -f "$DEST/etc/fstab" ]; then
    mv "$DEST/etc/fstab" "$DEST/etc/fstab.image"
    : > "$DEST/etc/fstab"
fi
# Test payload (same layout the QEMU gate used).
mkdir -p "$DEST/var/lib/autosd-test"
cp "$IMAGES/busybox-oci.tar" "$IMAGES/captest-docker.tar" "$HERE/gate-guest.sh" \
   "$HERE/board-podman-smoke.sh" "$DEST/var/lib/autosd-test/"
chmod +x "$DEST/var/lib/autosd-test/"*.sh
# Completion stamp: $DEST existing is no longer proof staging finished (a
# partial run also leaves $DEST behind); this is.
: > "$DEST/.x5h-stage-complete"
echo "OK: staged at $DEST — now add it to /etc/exports (mirror the BSP export line) and run: exportfs -ra"
