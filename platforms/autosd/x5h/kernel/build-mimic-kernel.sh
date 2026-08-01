#!/usr/bin/env bash
# Build the BSP-constraint-mimic kernel for the QEMU gate.
# Usage: build-mimic-kernel.sh <outdir>
# Native on aarch64 (CI); cross-compiles from x86_64 (needs gcc-aarch64-linux-gnu).
set -euo pipefail
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="$(curl -fsSL https://www.kernel.org/releases.json |
  python3 -c 'import json,sys; print(next(r["version"] for r in json.load(sys.stdin)["releases"] if r["moniker"]=="longterm" and r["version"].startswith("6.1.")))')"
echo "Using kernel $VER"
cd "$OUT"
[ -d "linux-$VER" ] || { curl -fsSLO "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$VER.tar.xz"; tar xf "linux-$VER.tar.xz"; }
cd "linux-$VER"
export ARCH=arm64
[ "$(uname -m)" = "aarch64" ] || export CROSS_COMPILE=aarch64-linux-gnu-
make defconfig
scripts/kconfig/merge_config.sh -m .config "$HERE/bsp-mimic.config"
make olddefconfig
# Assert the constraint set actually landed (defconfig may re-enable things).
for on in EXT4_FS TMPFS_XATTR BTRFS_FS OVERLAY_FS BLK_DEV_LOOP NETFILTER_XTABLES \
          IP_NF_IPTABLES IP_NF_NAT IP_NF_TARGET_MASQUERADE BRIDGE VETH TUN \
          VIRTIO_BLK VIRTIO_NET SERIAL_AMBA_PL011_CONSOLE; do
  grep -q "^CONFIG_${on}=y" .config || { echo "FATAL: CONFIG_${on} not =y"; exit 1; }
done
for off in SECURITY_SELINUX EXT4_FS_SECURITY NF_TABLES EROFS_FS DM_VERITY \
           NETFILTER_XT_MATCH_COMMENT NETFILTER_XT_MATCH_MULTIPORT; do
  grep -q "^CONFIG_${off}=[ym]" .config && { echo "FATAL: CONFIG_${off} enabled"; exit 1; }
done
make -j"$(nproc)" Image
cp arch/arm64/boot/Image "$OUT/Image"
echo "OK: $OUT/Image"
