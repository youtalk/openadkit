#!/usr/bin/env bash
# Copy test archives + gate-guest.sh into the ext4 export (aib add_files cannot
# write under /var, and embedding containers would dodge the unpack path under test).
# Usage: inject-test-images.sh <rootfs.ext4> <testimages-dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOTFS="$1"; IMAGES="$2"
MNT="$(mktemp -d)"
sudo mount -o loop "$ROOTFS" "$MNT"
# The umount must actually succeed before we claim success: a failed umount
# would leave dirty pages unflushed and the loop device attached, silently
# handing a half-written export to whoever boots it next. $? is captured as
# the trap's very first statement, before any command in the trap body can
# clobber it, so the "OK" line only prints when the whole script (mount,
# copy, chmod) succeeded *and* the unmount that makes it durable succeeded.
# (st is pre-declared here only so shellcheck can see the assignment that
# actually matters, inside the trap body, below -- it has no visibility into
# variables first assigned inside a trap string.)
st=0
trap '
st=$?
sync
if ! sudo umount "$MNT"; then
    echo "FATAL: umount $MNT failed" >&2
    exit 1
fi
rmdir "$MNT"
if [ "$st" -eq 0 ]; then
    echo "OK: injected into $ROOTFS"
fi
exit "$st"
' EXIT
sudo mkdir -p "$MNT/var/lib/autosd-test"
sudo cp "$IMAGES/busybox-oci.tar" "$IMAGES/captest-docker.tar" "$HERE/gate-guest.sh" \
        "$MNT/var/lib/autosd-test/"
sudo chmod +x "$MNT/var/lib/autosd-test/gate-guest.sh"
