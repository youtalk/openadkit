#!/usr/bin/env bash
# Boot an AutoSD aarch64 disk image. Usage: run-qemu.sh <disk.qcow2> [extra args...]
# KVM is used only on aarch64 hosts (CI arm64 runner, if /dev/kvm exposed); x86 hosts use TCG.
set -euo pipefail
DISK="$1"; shift || true
if [ "$(uname -m)" = "aarch64" ] && [ -w /dev/kvm ]; then
  ACCEL=(-accel kvm -cpu host)
else
  ACCEL=(-accel tcg -cpu max)
fi
CODE=/usr/share/AAVMF/AAVMF_CODE.fd
VARS="$(mktemp --suffix=.varstore)"
cp /usr/share/AAVMF/AAVMF_VARS.fd "$VARS"
exec qemu-system-aarch64 \
  -machine virt -smp 8 -m 4G "${ACCEL[@]}" \
  -drive "file=$CODE,if=pflash,format=raw,unit=0,readonly=on" \
  -drive "file=$VARS,if=pflash,format=raw,unit=1" \
  -drive "file=$DISK,if=virtio,format=qcow2" \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
  -nographic "$@"
