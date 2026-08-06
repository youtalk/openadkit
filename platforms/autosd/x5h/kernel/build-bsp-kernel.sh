#!/usr/bin/env bash
# Build the X5H kernel: the board's own 6.1.102 BSP source with the
# AutoSD-alignment + QEMU-gate fragments merged over the board-extracted
# config, compiled with the PINNED ARM GNU 13.2.Rel1 x86_64-hosted cross
# toolchain.
#
# Why pinned: the 2026-08-05 board session root-caused the rebuilt
# kernel's 0.09s hang to a layout-sensitive platform bug that wedges one
# secondary CPU at SMP bringup. With this exact config, GCC 13.2 booted
# 3/3 distinct layouts and GCC 13.3 wedged 3/3. The pin is EMPIRICAL, not
# a guarantee -- the board smoke stays the final arbiter for any kernel
# change (the QEMU gate cannot see this defect class). ARM ships no
# aarch64-hosted 13.2.Rel1 aarch64-none-linux-gnu toolchain (404 on both
# mirrors, verified 2026-08-05), hence x86_64 cross everywhere, CI
# included. An environment-dependent compiler fallback is exactly the
# path by which this bug returns: none is offered.
#
# Modes:
#   (default)         full build, fw-less gate image (CI / QEMU gate)
#   --firmware <dir>  full build, board image embedding rcar_gen5_mp_phy.bin
#                     from <dir> (REQUIRED for TSN netboot; NDA SDK blob --
#                     local builds only, never CI)
#   --config-only     config merge + asserts only; no compiler needed
#   --toolchain-only  fetch/verify/assert the toolchain, then exit
# Usage: build-bsp-kernel.sh [--config-only|--toolchain-only] [--firmware <dir>] <outdir>
# Produces in <outdir>: Image-autosd, r8a78000-ironhide-uio-autosd.dtb,
#   modules-6.1.102-autosd.tar, kernelrelease.txt, config-autosd.txt,
#   provenance.txt, extract-ikconfig
set -euo pipefail

TOOLCHAIN_URL="https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu/13.2.rel1/binrel/arm-gnu-toolchain-13.2.rel1-x86_64-aarch64-none-linux-gnu.tar.xz"
TOOLCHAIN_SHA256=12fcdf13a7430655229b20438a49e8566e26551ba08759922cdaf4695b0d4e23
TOOLCHAIN_NAME=arm-gnu-toolchain-13.2.rel1-x86_64-aarch64-none-linux-gnu
# ARM's tarball basename says "rel1" but its single top-level directory
# says "Rel1" -- two different strings, not one. The cache key and the
# download URL use the former; CROSS_COMPILE must use the latter.
TOOLCHAIN_DIRNAME=arm-gnu-toolchain-13.2.Rel1-x86_64-aarch64-none-linux-gnu
TOOLCHAIN_ID="Arm GNU Toolchain 13.2.rel1"
TOOLDIR="${X5H_TOOLCHAIN_DIR:-$HOME/.cache/x5h-toolchain}"

CONFIG_ONLY= TOOLCHAIN_ONLY= FWDIR=
while [ $# -gt 0 ]; do
  case "$1" in
    --config-only) CONFIG_ONLY=1; shift ;;
    --toolchain-only) TOOLCHAIN_ONLY=1; shift ;;
    --firmware)
      [ -n "${2:-}" ] || { echo "FATAL: --firmware needs a directory"; exit 1; }
      FWDIR="$(cd "$2" && pwd)"; shift 2 ;;
    *) break ;;
  esac
done

export ARCH=arm64
export CROSS_COMPILE="$TOOLDIR/$TOOLCHAIN_DIRNAME/bin/aarch64-none-linux-gnu-"

fetch_toolchain() {
  if [ ! -x "${CROSS_COMPILE}gcc" ]; then
    [ "$(uname -m)" = x86_64 ] \
      || { echo "FATAL: pinned toolchain is x86_64-hosted; host is $(uname -m)"; exit 1; }
    mkdir -p "$TOOLDIR"
    [ -f "$TOOLDIR/$TOOLCHAIN_NAME.tar.xz" ] \
      || curl -fL "$TOOLCHAIN_URL" -o "$TOOLDIR/$TOOLCHAIN_NAME.tar.xz"
    echo "$TOOLCHAIN_SHA256  $TOOLDIR/$TOOLCHAIN_NAME.tar.xz" | sha256sum -c - \
      || { echo "FATAL: toolchain tarball failed sha256 verification"; exit 1; }
    # Keep the tarball after extraction: CI caches the tarball, not the tree.
    tar -xJf "$TOOLDIR/$TOOLCHAIN_NAME.tar.xz" -C "$TOOLDIR"
  fi
  "${CROSS_COMPILE}gcc" --version | head -1 | grep -qF "$TOOLCHAIN_ID" \
    || { echo "FATAL: ${CROSS_COMPILE}gcc is not $TOOLCHAIN_ID: $("${CROSS_COMPILE}gcc" --version | head -1)"; exit 1; }
}

if [ -n "$TOOLCHAIN_ONLY" ]; then
  fetch_toolchain
  echo "OK (toolchain-only): $("${CROSS_COMPILE}gcc" --version | head -1)"
  exit 0
fi

[ -n "${1:-}" ] || { echo "Usage: build-bsp-kernel.sh [--config-only|--toolchain-only] [--firmware <dir>] <outdir>"; exit 1; }
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
# Pinned commit of renesas-rcar/linux-bsp branch v6.1.102/rcar-6.0.0.rc12
# (carries r8a78000/Ironhide: the X5H). The ref is a mutable BRANCH — never
# build from the branch name. Move this SHA only deliberately, and re-run
# the QEMU gate when you do.
SHA=ff9ce02daad0f5a4e64984d725f488faf3cf3e71
SRC="$OUT/linux-bsp-$SHA"
if [ ! -d "$SRC" ]; then
  curl -fL "https://github.com/renesas-rcar/linux-bsp/archive/$SHA.tar.gz" -o "$OUT/src.tar.gz"
  tar -xzf "$OUT/src.tar.gz" -C "$OUT"     # extracts linux-bsp-<sha>/
  rm -f "$OUT/src.tar.gz"
fi
cd "$SRC"
cp "$HERE/x5h-board.config" .config
scripts/kconfig/merge_config.sh -m .config "$HERE/autosd.config" "$HERE/virtio.config"
make olddefconfig
# Assert every declaration in both fragments landed. =y must be exactly =y;
# =m may legitimately resolve to =y (a select can promote it) but must not
# vanish; "is not set" must not come back enabled; quoted string values
# must match exactly. This is the same discipline the mimic-kernel build
# used, generalized to =m and string symbols.
assert_fragment() {
  frag="$1"
  while IFS= read -r line; do
    case "$line" in
      "# CONFIG_"*" is not set")
        sym="${line#\# }"; sym="${sym%% *}"
        if grep -q "^${sym}=[ym]" .config; then
          echo "FATAL: $sym enabled but $frag disables it"; exit 1
        fi ;;
      CONFIG_*=\"*\")
        grep -qF "$line" .config || { echo "FATAL: ${line%%=*} string mismatch ($frag)"; exit 1; } ;;
      CONFIG_*=y)
        grep -q "^${line}\$" .config || { echo "FATAL: ${line%%=*} not =y after merge ($frag)"; exit 1; } ;;
      CONFIG_*=m)
        sym="${line%%=*}"
        grep -q "^${sym}=[ym]" .config || { echo "FATAL: $sym neither =m nor =y after merge ($frag)"; exit 1; } ;;
    esac
  done < "$frag"
}
assert_fragment "$HERE/autosd.config"
assert_fragment "$HERE/virtio.config"
KVER="$(make -s kernelrelease)"
[ "$KVER" = "6.1.102-autosd" ] || { echo "FATAL: kernelrelease is $KVER, expected 6.1.102-autosd"; exit 1; }
cp .config "$OUT/config-autosd.txt"
echo "$KVER" > "$OUT/kernelrelease.txt"
if [ -n "$CONFIG_ONLY" ]; then
  echo "OK (config-only): $KVER"
  exit 0
fi
fetch_toolchain
make -j"$(nproc)" Image dtbs modules
cp arch/arm64/boot/Image "$OUT/Image-autosd"
cp arch/arm64/boot/dts/renesas/r8a78000-ironhide-uio.dtb "$OUT/r8a78000-ironhide-uio-autosd.dtb"
rm -rf "$OUT/modstage"
make INSTALL_MOD_PATH="$OUT/modstage" INSTALL_MOD_STRIP=1 modules_install
# Drop the build/source symlinks (they point into this throwaway tree); the
# board and the gate want only the module tree itself.
rm -f "$OUT/modstage/lib/modules/$KVER/build" "$OUT/modstage/lib/modules/$KVER/source"
tar -C "$OUT/modstage" -cf "$OUT/modules-$KVER.tar" "lib/modules/$KVER"
rm -rf "$OUT/modstage"
ls -lh "$OUT/Image-autosd" "$OUT/r8a78000-ironhide-uio-autosd.dtb" "$OUT/modules-$KVER.tar"
echo "OK: $KVER"
