#!/usr/bin/env bash
# Copy test archives + gate-guest.sh into the ext4 export (aib add_files cannot
# write under /var, and embedding containers would dodge the unpack path under test).
# Usage: inject-test-images.sh <rootfs.ext4> <testimages-dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$1"; IMAGES="$2"
MNT="$(mktemp -d)"
sudo mount -o loop "$ROOTFS" "$MNT"
trap 'sudo umount "$MNT" && rmdir "$MNT"' EXIT
sudo mkdir -p "$MNT/var/lib/autosd-test"
sudo cp "$IMAGES/busybox-oci.tar" "$IMAGES/captest-docker.tar" "$HERE/gate-guest.sh" \
        "$MNT/var/lib/autosd-test/"
sudo chmod +x "$MNT/var/lib/autosd-test/gate-guest.sh"
echo "OK: injected into $ROOTFS"
