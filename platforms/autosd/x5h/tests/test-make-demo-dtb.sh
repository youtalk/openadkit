#!/usr/bin/env bash
# The AD Kit tree is the vendor cacr tree plus the three vdev carveouts cr52_1
# needs, with its memory-region rewritten to list them after the vendor
# cr52_ram1. This builds a small synthetic cacr-shaped tree, runs the
# derivation, and reads the result back with fdtget.
set -u
name=test-make-demo-dtb
here=$(cd "$(dirname "$0")" && pwd)
s="$here/../uboot/make-demo-dtb.sh"
fail() { echo "TEST_FAIL $name reason=$1"; exit 1; }
command -v dtc >/dev/null || fail dtc_missing
command -v fdtget >/dev/null || fail fdtget_missing
[ -x "$s" ] || fail script_missing
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# The shape of the vendor cacr tree around the CR52: the stock cr52_ram0/1 at
# 0x96600000, cr52_1 pointing at 0x10a, NPU regions on both sides of the hole
# the vdev windows go into, and a 40-bit region to exercise the high cell.
cat > "$tmp/cacr.dts" <<'EOF'
/dts-v1/;
/ {
	#address-cells = <2>;
	#size-cells = <2>;
	reserved-memory {
		#address-cells = <2>;
		#size-cells = <2>;
		ranges;
		linux,npu_region@5da00000 {
			reg = <0x0 0x5da00000 0x0 0x3600000>;
			phandle = <0x201>;
		};
		ldr@8e200000 {
			no-map;
			reg = <0x0 0x8e200000 0x0 0x100000>;
		};
		cr52_ram0@96600000 {
			no-map;
			reg = <0x0 0x96600000 0x0 0x50000>;
		};
		cr52_ram1@96650000 {
			no-map;
			reg = <0x0 0x96650000 0x0 0x50000>;
			phandle = <0x10a>;
		};
		linux,npu_region@9e600000 {
			reg = <0x0 0x9e600000 0x0 0x21a00000>;
			phandle = <0x202>;
		};
		linux,npu_region@1400000000 {
			no-map;
			reg = <0x14 0x0 0x0 0x80000000>;
			phandle = <0x203>;
		};
	};
	soc {
		cr52_1 {
			compatible = "renesas,rcar-gen5-rproc";
			memory-region = <0x10a>;
		};
	};
};
EOF
dtc -q -I dts -O dtb -o "$tmp/cacr.dtb" "$tmp/cacr.dts" || fail fixture_compile
out=$(bash "$s" "$tmp/cacr.dtb" "$tmp/demo.dtb") || fail derive_failed
grep -q '^DEMO_DTB_OK ' <<<"$out" || fail no_ok_marker
# The vendor nodes come through unchanged, and cr52_ram1 is still the only one.
while read -r node want; do
    [ "$(fdtget -t x "$tmp/demo.dtb" "/reserved-memory/$node" reg)" = "$want" ] || fail "vendor_node_changed_$node"
done <<'EOF'
cr52_ram1@96650000 0 96650000 0 50000
cr52_ram0@96600000 0 96600000 0 50000
linux,npu_region@5da00000 0 5da00000 0 3600000
linux,npu_region@9e600000 0 9e600000 0 21a00000
linux,npu_region@1400000000 14 0 0 80000000
EOF
[ "$(fdtget -t x "$tmp/demo.dtb" /reserved-memory/cr52_ram1@96650000 phandle)" = 10a ] || fail cr52_ram1_phandle_changed
[ "$(fdtget -l "$tmp/demo.dtb" /reserved-memory | grep -c '^cr52_ram1@')" = 1 ] || fail second_cr52_ram1
# The three vdev nodes. Their names are what rproc_alloc_vring() and
# rproc_add_virtio_dev() look the carveouts up by, so a rename is a defect.
# Each must also sit inside SHARE_CR_CA, the one DRAM row the CR52 firmware maps.
while read -r node want; do
    reg=$(fdtget -t x "$tmp/demo.dtb" "/reserved-memory/$node" reg) || fail "missing_$node"
    [ "$reg" = "$want" ] || fail "reg_wrong_$node"
    fdtget "$tmp/demo.dtb" "/reserved-memory/$node" no-map >/dev/null 2>&1 || fail "no_map_missing_$node"
    set -- $reg
    [ $((0x$2)) -ge $((0x8e600000)) ] && [ $((0x$2 + 0x$4)) -le $((0x9e600000)) ] || fail "outside_share_cr_ca_$node"
done <<'EOF'
vdev0vring0@96400000 0 96400000 0 3000
vdev0vring1@96403000 0 96403000 0 3000
vdev0buffer@96410000 0 96410000 0 100000
EOF
# cr52_1 lists all four, cr52_ram1 first: rcar_gen5_rproc_prepare walks the
# list in order and rproc_add_virtio_dev falls back to index 0. The three vdev
# phandles are derived above the vendor tree's highest (0x203 here), so the
# check is the linkage, not a constant.
mr=$(fdtget -t x "$tmp/demo.dtb" /soc/cr52_1 memory-region)
[ "$mr" = "10a 204 205 206" ] || fail "cr52_ref_wrong: $mr"
i=2
for node in vdev0vring0@96400000 vdev0vring1@96403000 vdev0buffer@96410000; do
    ph=$(fdtget -t x "$tmp/demo.dtb" "/reserved-memory/$node" phandle)
    [ "$ph" = "$(cut -d' ' -f$i <<<"$mr")" ] || fail "not_linked_$node"
    i=$((i + 1))
done
# Derived from the highest phandle, not from a count or the last one seen.
sed 's/phandle = <0x201>/phandle = <0x2ff>/' "$tmp/cacr.dts" > "$tmp/high.dts"
dtc -q -I dts -O dtb -o "$tmp/high.dtb" "$tmp/high.dts" || fail fixture_high_compile
bash "$s" "$tmp/high.dtb" "$tmp/h.dtb" >/dev/null 2>&1 || fail high_derive_failed
[ "$(fdtget -t x "$tmp/h.dtb" /soc/cr52_1 memory-region)" = "10a 300 301 302" ] || fail max_phandle_not_used
# Refusals. Each one prints FATAL and writes no output file.
refused() { # <fixture-dts> <slug>
    dtc -q -I dts -O dtb -o "$tmp/r.dtb" "$1" || fail "fixture_compile_$2"
    rm -f "$tmp/r-out.dtb"
    bash "$s" "$tmp/r.dtb" "$tmp/r-out.dtb" >/dev/null 2>&1 && fail "accepts_$2"
    [ ! -e "$tmp/r-out.dtb" ] || fail "wrote_output_$2"
}
# The old v4.35 NPU tree: no cr52_ram1 at all. Feeding it is a stale input.
sed '/cr52_ram1@96650000 {/,/};/d' "$tmp/cacr.dts" > "$tmp/npu435.dts"
refused "$tmp/npu435.dts" npu435_tree
# cr52_ram1 present, but under a phandle cr52_1 does not point at.
sed 's/phandle = <0x10a>/phandle = <0x10b>/' "$tmp/cacr.dts" > "$tmp/ph.dts"
refused "$tmp/ph.dts" wrong_phandle
# Double derivation.
dtc -q -I dtb -O dts -o "$tmp/demo.dts" "$tmp/demo.dtb" || fail decompile_demo
refused "$tmp/demo.dts" double_derivation
# A vendor tree that reserves part of the hole: the windows would overlap it.
sed 's/^\t\tcr52_ram0@96600000 {/\t\tfw@96500000 { no-map; reg = <0x0 0x96500000 0x0 0x20000>; };\n&/' "$tmp/cacr.dts" > "$tmp/overlap.dts"
grep -q 'fw@96500000' "$tmp/overlap.dts" || fail overlap_fixture_not_built
refused "$tmp/overlap.dts" overlapping_reservation
echo "TEST_PASS $name"
