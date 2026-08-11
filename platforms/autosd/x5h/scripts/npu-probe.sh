#!/bin/sh
# npu-probe.sh — board-side proof that the NPU is actually reachable.
#
# Every layer between the device tree and the execution provider fails in a
# way that looks like the layer below it, so this checks them in order and
# names the one that broke rather than reporting "it did not work". Run it
# before spending time in the runtime.
#
# Markers: NPU_PROBE_PASS / NPU_PROBE_FAIL reason=<...>
#
# Usage: npu-probe.sh [artifacts-dir] [image]
set -u

ARTIFACTS=${1:-/root/npu/ort/sample/resnet18/resnet18_artifacts}
IMAGE=${2:-localhost/x5h-ort:1.1.0}
SCRIPT=${NPU_EVAL_SCRIPT:-/root/npu/ort/renesas_ep_eval_latency.py}

fail() { echo "NPU_PROBE_FAIL reason=$1"; exit 1; }

# --- layer 1: UIO devices bound at all ---------------------------------
# uio_pdrv_genirq binds nothing without of_id=generic-uio, and says nothing
# when it does not; an empty class directory here means x5h-uio.conf did not
# reach the image (see uio.md), not a device-tree fault.
uio_count=$(ls -d /sys/class/uio/uio* 2>/dev/null | wc -l)
[ "$uio_count" -gt 0 ] || fail uio_unbound

# --- layer 2: the NPU nodes exist in the device tree --------------------
# The names come from each node's linux,uio-name. No npuc* in sysfs means the
# NPU is not described in the booted dtb -- the udev rule cannot invent it.
npuc_sysfs=$(grep -l '^npuc' /sys/class/uio/uio*/name 2>/dev/null | wc -l)
[ "$npuc_sysfs" -ge 2 ] || fail "npuc_not_in_dtb sysfs_matches=$npuc_sysfs uio_devices=$uio_count"

# --- layer 3: udev turned those names into paths ------------------------
for d in /dev/npuc0 /dev/npuc1; do
  [ -e "$d" ] || fail "udev_symlink_missing dev=$d"
  [ -r "$d" ] && [ -w "$d" ] || fail "npuc_mode dev=$d ($(ls -l "$d"))"
done

# --- layer 4: contiguous memory ----------------------------------------
# cmem0 comes from the default CMA and proves only that the module loaded.
# The runtime wants cmem_other*, which exist one per phandle in /cmem's
# memory-region list -- so their absence is a device-tree gap, not a module
# argument to tune (npu-bringup.md).
lsmod | grep -q '^cmemdrv' || fail cmem_not_loaded
ls /dev/cmem_other* >/dev/null 2>&1 || fail cmem_other_missing

# --- layer 5: the runtime container -------------------------------------
podman image exists "$IMAGE" || fail "image_missing image=$IMAGE"
[ -f "$SCRIPT" ] || fail "eval_script_missing path=$SCRIPT"
[ -d "$ARTIFACTS" ] || fail "artifacts_missing path=$ARTIFACTS"

# --- layer 6: the execution provider actually ran ------------------------
# A run that merely completes proves nothing, in two separate ways. The sample
# script lists CPUExecutionProvider as a fallback, so a board with no NPU still
# produces correct results and a latency figure; and its run_inference()
# swallows every exception into a printed "Error occurred:" line and returns
# normally, so the exit status is 0 even when nothing ran. Hence three
# assertions on the output text rather than one on $?.
#
# What this does not prove is which subgraphs the NPU executed -- the provider
# list only says the EP registered. The ORT profiler (--enable-rtt) carries the
# per-node assignment; check it by hand the first time the NPU comes up, and
# turn it into an assertion here once its schema is known rather than guessed.
devs=""
for d in /dev/npuc0 /dev/npuc1 /dev/cmem_other*; do
  devs="$devs --device $d"
done
# The manifest's artifact_path is relative to the artifacts directory's PARENT
# and starts with that directory's own name ("resnet18_artifacts/nnx/..."), so
# the mount point has to keep the directory name. Mounting it as /work/artifacts
# makes the backend look for /work/resnet18_artifacts and miss.
art_name=$(basename "$ARTIFACTS")
out=$(podman run --rm $devs \
        -v "$ARTIFACTS":"/work/$art_name":ro \
        -v "$SCRIPT":/work/eval.py:ro \
        "$IMAGE" python /work/eval.py --artifacts "/work/$art_name" 2>&1)
echo "$out"
echo "$out" | grep -q 'Error occurred:' && fail "runtime_error ($(echo "$out" | grep -m1 'Error occurred:'))"
echo "$out" | grep -q 'providers:.*RenesasExecutionProvider' || fail ep_not_selected
echo "$out" | grep -q 'avg Latency' || fail no_latency_result

echo "NPU_PROBE_PASS uio=$uio_count npuc=$npuc_sysfs cmem_other=$(ls -d /dev/cmem_other* | wc -l)"
