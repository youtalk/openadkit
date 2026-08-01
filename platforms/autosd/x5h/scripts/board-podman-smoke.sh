#!/bin/sh
# On-board podman smoke for AutoSD on the BSP kernel.
# Usage: board-podman-smoke.sh tmpfs
#        board-podman-smoke.sh btrfs /dev/disk/by-partlabel/autosd-store
# Phase order is a safety invariant: tmpfs (zero board mutation) must pass
# before btrfs (writes the previously-empty 32 GB UFS LUN) is attempted.
# This is enforced, not just documented: a genuine tmpfs pass stamps
# TMPFS_STAMP below, and the btrfs arm refuses to run without it.
set -x
T=/var/lib/autosd-test
TMPFS_STAMP=/run/x5h-smoke-tmpfs-passed
MODE="$1"
case "$MODE" in
tmpfs)
    # modprobe(8) is "modprobe [modulename] [module parameters...]" -- without
    # -a, only the first name is a module; the rest are parsed as parameters
    # to it (and silently ignored by a module that doesn't take them), so a
    # bare "modprobe overlay veth bridge br_netfilter" loads overlay ONLY and
    # still exits 0.
    modprobe -a overlay veth bridge br_netfilter \
        || { echo "SMOKE_${MODE}_MODPROBE_FAIL"; exit 1; }
    mount -t tmpfs -o size=8g tmpfs /var/lib/containers \
        || { echo "SMOKE_${MODE}_MOUNT_FAIL"; exit 1; }
    # Required marker, mirroring gate-guest.sh's GATE3_STORE_FS/GATE4_STORE_FS:
    # proves the podman probe below actually ran against tmpfs, not a
    # silently-failed mount that fell through to the ext4 root underneath.
    echo "SMOKE_${MODE}_STORE_FS=$(findmnt -no FSTYPE --target /var/lib/containers | tail -1)"
    ;;
btrfs)
    if [ ! -f "$TMPFS_STAMP" ]; then
        echo "SMOKE_${MODE}_TMPFS_GATE_FAIL (no tmpfs pass recorded this boot; re-run 'tmpfs' first, or touch $TMPFS_STAMP to override deliberately)"
        exit 1
    fi
    DEV="$2"
    [ -b "$DEV" ] || { echo "FATAL: $DEV is not a block device"; exit 1; }
    modprobe -a btrfs overlay veth bridge br_netfilter \
        || { echo "SMOKE_${MODE}_MODPROBE_FAIL"; exit 1; }
    mount "$DEV" /var/lib/containers \
        || { echo "SMOKE_${MODE}_MOUNT_FAIL"; exit 1; }
    echo "SMOKE_${MODE}_STORE_FS=$(findmnt -no FSTYPE --target /var/lib/containers | tail -1)"
    ;;
*)
    echo "usage: $0 tmpfs | btrfs <blockdev>"; exit 2
    ;;
esac

# From here on, record failures in FAIL instead of exiting immediately, so
# every run reaches exactly one terminal marker -- SMOKE_<mode>_PASS or
# SMOKE_<mode>_FAIL -- and the tmpfs cleanup below always runs.
FAIL=
podman load -i "$T/captest-docker.tar" || { echo "SMOKE_${MODE}_LOAD_FAIL"; FAIL=1; }
if [ -z "$FAIL" ]; then
    podman run --rm localhost/x5h-captest:latest getcap /usr/bin/ping | grep cap_net_raw \
        || { echo "SMOKE_${MODE}_CAPS_FAIL"; FAIL=1; }
fi
if [ -z "$FAIL" ]; then
    podman load -i "$T/busybox-oci.tar" || { echo "SMOKE_${MODE}_BUSYBOX_LOAD_FAIL"; FAIL=1; }
fi
BB=
if [ -z "$FAIL" ]; then
    BB="$(podman images --format '{{.Repository}}:{{.Tag}}' | grep -m1 busybox)"
    [ -n "$BB" ] || { echo "SMOKE_${MODE}_BUSYBOX_LOAD_FAIL"; FAIL=1; }
fi
if [ -z "$FAIL" ]; then
    podman run -d --name web -p 8080:80 "$BB" \
        sh -c 'echo ok > /tmp/index.html && exec httpd -f -p 80 -h /tmp'
    sleep 3
    if curl -fsS --max-time 10 http://127.0.0.1:8080/ | grep -q ok; then
        echo "SMOKE_${MODE}_NET_OK"
    else
        echo "SMOKE_${MODE}_NET_FAIL (try firewall none / direct container IP, as in the QEMU gate)"
        FAIL=1
    fi
    podman rm -f web >/dev/null 2>&1
fi

# tmpfs is the zero-mutation phase: leave the board as found so a later btrfs
# run doesn't stack its mount on top of a still-mounted tmpfs store.
if [ "$MODE" = "tmpfs" ]; then
    umount /var/lib/containers \
        || echo "SMOKE_${MODE}_UMOUNT_WARN (stale tmpfs mount may remain over the ext4 root)"
fi

if [ -n "$FAIL" ]; then
    echo "SMOKE_${MODE}_FAIL"
    exit 1
fi

# Only a genuine, complete tmpfs pass unlocks the btrfs arm.
if [ "$MODE" = "tmpfs" ]; then
    : > "$TMPFS_STAMP"
fi
echo "SMOKE_${MODE}_PASS"
