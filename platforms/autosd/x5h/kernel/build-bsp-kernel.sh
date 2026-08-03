#!/usr/bin/env bash
# Build the one-image X5H kernel: the board's own 6.1.102 BSP source with
# the AutoSD-alignment + QEMU-gate fragments merged over the board-extracted
# config. Native aarch64 in CI; --config-only also runs on x86_64 (config
# targets need no cross-compiler binaries).
# Usage: build-bsp-kernel.sh [--config-only] <outdir>
# Produces in <outdir>: Image-autosd, r8a78000-ironhide-uio-autosd.dtb,
#   modules-6.1.102-autosd.tar, kernelrelease.txt, config-autosd.txt
set -euo pipefail
CONFIG_ONLY=
[ "${1:-}" = "--config-only" ] && { CONFIG_ONLY=1; shift; }
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
export ARCH=arm64
[ "$(uname -m)" = "aarch64" ] || export CROSS_COMPILE=aarch64-linux-gnu-
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
