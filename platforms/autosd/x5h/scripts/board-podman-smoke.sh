#!/bin/sh
# On-board podman smoke for AutoSD on the BSP kernel.
# Usage: board-podman-smoke.sh tmpfs
#        board-podman-smoke.sh btrfs /dev/disk/by-partlabel/autosd-store
# Phase order is a safety invariant: tmpfs (zero board mutation) must pass
# before btrfs (writes the previously-empty 32 GB UFS LUN) is attempted.
set -x
T=/var/lib/autosd-test
MODE="$1"
case "$MODE" in
tmpfs)
    modprobe overlay veth bridge br_netfilter 2>/dev/null
    mount -t tmpfs -o size=8g tmpfs /var/lib/containers || exit 1
    ;;
btrfs)
    DEV="$2"
    [ -b "$DEV" ] || { echo "FATAL: $DEV is not a block device"; exit 1; }
    modprobe btrfs overlay veth bridge br_netfilter 2>/dev/null
    mount "$DEV" /var/lib/containers || exit 1
    ;;
*)
    echo "usage: $0 tmpfs | btrfs <blockdev>"; exit 2
    ;;
esac
podman load -i "$T/captest-docker.tar" || { echo "SMOKE_${MODE}_LOAD_FAIL"; exit 1; }
podman run --rm localhost/x5h-captest:latest getcap /usr/bin/ping | grep cap_net_raw \
    || { echo "SMOKE_${MODE}_CAPS_FAIL"; exit 1; }
podman load -i "$T/busybox-oci.tar"
BB="$(podman images --format '{{.Repository}}:{{.Tag}}' | grep -m1 busybox)"
podman run -d --name web -p 8080:80 "$BB" \
    sh -c 'echo ok > /tmp/index.html && exec httpd -f -p 80 -h /tmp'
sleep 3
curl -fsS --max-time 10 http://127.0.0.1:8080/ | grep -q ok \
    && echo "SMOKE_${MODE}_NET_OK" || echo "SMOKE_${MODE}_NET_FAIL (try firewall none / direct container IP, as in the QEMU gate)"
podman rm -f web
echo "SMOKE_${MODE}_PASS"
