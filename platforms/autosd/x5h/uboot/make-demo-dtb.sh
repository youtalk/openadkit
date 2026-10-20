#!/usr/bin/env bash
# make-demo-dtb.sh -- derive the AD Kit device tree from the vendor cacr tree.
#
# demo, dev and yocto all boot the result. The cacr tree
# (r8a78000-ironhide-npu-cacr.dtb) keeps the stock CR52 carveouts, and cr52_1's
# memory-region already resolves: phandle 0x10a is cr52_ram1@96650000, which
# holds the firmware's .resource_table. What the tree lacks are the three rpmsg
# windows. This script adds them and rewrites cr52_1's memory-region to list
# all four:
#
#   cr52_ram1    the vendor node, untouched. Index 0, because
#                rcar_gen5_rproc_prepare walks memory-region in order.
#   vdev0vring0  0x96400000, the two rpmsg vrings, and
#   vdev0vring1  0x96403000
#   vdev0buffer  0x96410000, the rpmsg buffer pool.
#
# The three vdev names are not decoration. rcar_gen5_rproc_prepare registers
# every memory-region phandle as a carveout NAMED AFTER THE NODE, and
# rproc_alloc_vring() and rproc_add_virtio_dev() look carveouts up by exactly
# these three names. Miss them and remoteproc falls back to
# dma_alloc_coherent() on linux,cma@40000000, which no CR52 MPU region maps, so
# the firmware data-aborts in rpmsg_init_vdev the moment it touches a vring.
# That was gate D1b on board 2, 2026-09-17.
#
# A fixed device address in the firmware's own resource table does NOT pin
# them instead: rproc_alloc_vring() matches by name, and rproc_alloc_carveout()
# only warns on an address mismatch when there is no IOMMU, then overwrites the
# firmware's value with the CMA address it allocated. The firmware therefore
# keeps FW_RSC_ADDR_ANY, which rproc_check_carveout_da() skips.
#
# Contract with the CR52 firmware: every window cr52_1 lists must sit inside
# the vendor CR52 MPU row SHARE_CR_CA, 0x8e600000 to 0x9e600000
# (common/memory_map/memory_map_x5h_ironhide.h in the R-Car FreeRTOS BSP). The
# safety island firmware maps no other DRAM. The three windows sit in the hole
# between ldr@8e200000 and cr52_ram0@96600000, which the cacr tree leaves
# unreserved, and this script refuses a tree that reserves any part of them.
#
# no-map on every node is required, not cosmetic: rcar_gen5_rproc_mem_alloc
# maps a carveout with ioremap_wc, and arm64 refuses to ioremap memory that is
# in the linear map.
#
# Input and output are vendor blobs: run this at staging time, never commit
# either file.
#   make-demo-dtb.sh r8a78000-ironhide-npu-cacr.dtb r8a78000-ironhide-demo.dtb
set -euo pipefail
in=${1:?usage: make-demo-dtb.sh <cacr.dtb> <demo.dtb>}
out=${2:?usage: make-demo-dtb.sh <cacr.dtb> <demo.dtb>}
RM=/reserved-memory
CR52_NODE=/soc/cr52_1
# 0x3000 is PAGE_ALIGN(vring_size(256, 4096)) for the 256-descriptor vrings the
# firmware's resource table declares. 0x100000 is virtio_rpmsg_bus's
# MAX_RPMSG_NUM_BUFS (512) times the patched MAX_RPMSG_BUF_SIZE (2048). The
# buffer window starts at +0x10000, not straight after vring1, to leave room
# for a larger vring without moving it.
VDEV_BASE=0x96400000
VDEV_END=$((VDEV_BASE + 0x110000))
die() { echo "FATAL: $*" >&2; exit 1; }
for t in dtc fdtget fdtput; do
    command -v "$t" >/dev/null || die "$t not installed (apt: device-tree-compiler)"
done
[ -r "$in" ] || die "input not readable: $in"
# The firmware links its resource table to 0x96650000, so the vendor node must
# sit exactly there, under the phandle cr52_1 already uses.
ph=$(fdtget -t x "$in" "$RM/cr52_ram1@96650000" phandle 2>/dev/null) || ph=
[ "$ph" = 10a ] || die "$in has no cr52_ram1@96650000 with phandle 0x10a; is it the cacr tree?"
[ "$(fdtget "$in" "$RM" '#address-cells')" = 2 ] && [ "$(fdtget "$in" "$RM" '#size-cells')" = 2 ] \
    || die "$RM in $in does not use two address cells and two size cells"
# One pass over reserved-memory serves both refusals: a vdev node that is
# already there (double derivation), and a vendor reg that overlaps the windows.
for n in $(fdtget -l "$in" "$RM"); do
    case "$n" in vdev0*) die "$in already carries $n (double derivation?)" ;; esac
    reg=$(fdtget -t x "$in" "$RM/$n" reg 2>/dev/null) || continue
    # shellcheck disable=SC2086 # split the cells on purpose
    set -- $reg
    while [ $# -ge 4 ]; do
        b=$(( (0x$1 << 32) | 0x$2 )); e=$(( b + ((0x$3 << 32) | 0x$4) ))
        [ "$b" -ge "$VDEV_END" ] || [ "$e" -le $((VDEV_BASE)) ] || die "$n overlaps the vdev windows at $VDEV_BASE"
        shift 4
    done
done

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
dtc -q -I dtb -O dts -o "$tmp/in.dts" "$in"
# The three new phandles are allocated above the highest one the vendor tree
# already uses, not hardcoded: the values next to 0x10a are live nodes.
maxph=0
for h in $(grep -o 'phandle = <0x[0-9a-fA-F]*>' "$tmp/in.dts" | grep -o '0x[0-9a-fA-F]*'); do
    [ $((h)) -gt "$maxph" ] && maxph=$((h))
done
nodes=""
phandles=(0x10a)
while read -r name base size; do
    ph=$(printf '0x%x' $((maxph + ${#phandles[@]})))
    nodes+=$'\t\t'"$name@${base#0x} { reg = <0x0 $base 0x0 $size>; no-map; phandle = <$ph>; };"$'\n'
    phandles+=("$ph")
done <<EOF
vdev0vring0 $(printf '0x%x' $((VDEV_BASE))) 0x3000
vdev0vring1 $(printf '0x%x' $((VDEV_BASE + 0x3000))) 0x3000
vdev0buffer $(printf '0x%x' $((VDEV_BASE + 0x10000))) 0x100000
EOF

# Appended just inside reserved-memory's closing brace, not straight after its
# opening one: dtc refuses a tree where a subnode precedes the properties of
# the node holding it, and reserved-memory carries #address-cells, #size-cells
# and ranges. Brace depth is counted with the gsub-returns-a-count idiom.
awk -v nodes="$nodes" '
    !found && !inblock && /^[[:space:]]*reserved-memory[[:space:]]*\{/ { inblock = 1; depth = 1; print; next }
    inblock {
        depth += gsub(/\{/, "{") - gsub(/\}/, "}")
        if (depth == 0) { printf "%s", nodes; found = 1; inblock = 0 }
        print; next
    }
    { print }
    END { if (!found) exit 3 }
' "$tmp/in.dts" > "$tmp/out.dts" || die "no reserved-memory node in $in"
dtc -q -I dts -O dtb -o "$out" "$tmp/out.dts"
# fdtput rather than a second awk pass: memory-region lives in a node this
# script does not otherwise rewrite, and dtc has already validated the tree.
# It fails loudly if $CR52_NODE is absent, which is the check we want.
fdtput -t x "$out" "$CR52_NODE" memory-region "${phandles[@]}"
echo "DEMO_DTB_OK out=$out vdev_base=$VDEV_BASE regions=${#phandles[@]} phandles=${phandles[*]}"
