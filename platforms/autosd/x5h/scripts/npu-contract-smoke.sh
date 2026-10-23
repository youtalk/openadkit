#!/bin/sh
# On-board proof of the NPU container contract (demo and dev roles).
#   npu-contract-smoke.sh <artifacts-dir-relative-to-/opt/npu> [runs]
# Runs the vendor C++ infer from the EP v2.0.1 package (/opt/npu/ort-2.0.1)
# inside the VisionPilot image, on the image's own ONNX Runtime library, with
# the devices and mounts x5h-score-vp gives VisionPilot. A pass therefore
# proves the board, the image's EP build and the EP's ARC set together. infer
# feeds random inputs: a pass says the NPU runs the set, not that it is right.
# infer exits non-zero on an ONNX Runtime exception, so the exit status counts,
# and the latency line is its last output:
#   Average Latency / Run : 21.328 ms
# THE CONTRACT -- what a VisionPilot image gets from a board in either of
# those roles:
#   --device /dev/uio2:/dev/npuc0 --device /dev/uio3:/dev/npuc1  (npuc* are udev
#       symlinks; podman resolves --device /dev/npuc0 to uio2 and the backend's
#       literal open("/dev/npuc1") then fails -- name the destinations)
#   --device /dev/cmem0 --device /dev/cmem_other0 ... cmem_other3
#   -v /opt/npu:/npu   (artifact sets and the EP package are addressed under /npu)
#   -v /opt/npu/perf/merged:<compile-host merged dir>:ro  (a compiled set's
#       manifest.json records the absolute path it was compiled at)
# --binary is the directory that holds arc_prog_npus: the EP appends
# /arc_prog_npus itself.
# Markers: NPU_CONTRACT_PASS avg_ms=<v> runs=<n> image=<ref>
#          NPU_CONTRACT_FAIL reason=<wrong_role|npu_not_ready|no_artifacts|no_infer|no_image|infer_rc_<n>|no_latency|bad_args>
set -u
IMAGE=${X5H_NPU_IMAGE:-localhost/x5h-visionpilot:latest}
NPU=${NPU_DIR:-/opt/npu}
ROLE_FILE=${ROLE_FILE:-/run/x5h/role}
ORT=/npu/ort-2.0.1
ART=${1:-}; RUNS=${2:-20}
fail() { echo "NPU_CONTRACT_FAIL reason=$1"; exit 1; }
[ -n "$ART" ] || fail bad_args
# demo and dev boot the identical derived tree, so the NPU regions this
# contract depends on are present under both. Refusing either would refuse
# the roles that exist to run the NPU.
role=$(cat "$ROLE_FILE" 2>/dev/null)
case "$role" in
    demo|dev) ;;
    *) fail "wrong_role role=$role" ;;
esac
systemctl is-active --quiet x5h-npu.service || fail npu_not_ready
[ -d "$NPU/$ART" ] || fail "no_artifacts path=$NPU/$ART"
[ -x "$NPU/ort-2.0.1/infer" ] || fail no_infer
podman image exists "$IMAGE" || fail no_image
out=$(podman run --rm --privileged \
    --device /dev/uio2:/dev/npuc0 --device /dev/uio3:/dev/npuc1 \
    --device /dev/cmem0 --device /dev/cmem_other0 --device /dev/cmem_other1 \
    --device /dev/cmem_other2 --device /dev/cmem_other3 \
    -v "$NPU:/npu" \
    -v "$NPU/perf/merged:/home/youtalk/src/openadkit/x5h-work/npu/merged:ro" \
    --entrypoint "$ORT/infer" "$IMAGE" \
    --artifacts "/npu/$ART" --binary "$ORT/binary" --runs "$RUNS" 2>&1)
rc=$?
[ "$rc" -eq 0 ] || { printf '%s\n' "$out" | tail -20; fail "infer_rc_$rc"; }
avg=$(printf '%s\n' "$out" | sed -n 's/.*Average Latency \/ Run : *\([0-9][0-9.]*\) ms.*/\1/p' | tail -1)
[ -n "$avg" ] || { printf '%s\n' "$out" | tail -20; fail no_latency; }
echo "NPU_CONTRACT_PASS avg_ms=$avg runs=$RUNS image=$IMAGE"
