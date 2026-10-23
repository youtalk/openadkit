#!/usr/bin/env bash
# npu-contract-smoke.sh runs infer inside the VisionPilot image with the
# contract's devices and mounts, and grades it by exit status and latency
# line. Fake systemctl and podman, and check each verdict and the command line.
set -u
name=test-npu-contract-smoke
here=$(cd "$(dirname "$0")" && pwd)
s="$here/../scripts/npu-contract-smoke.sh"
fail() { echo "TEST_FAIL $name reason=$1"; exit 1; }
[ -x "$s" ] || fail script_missing
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/npu/ort-2.0.1" "$tmp/npu/perf/merged/set"
printf '#!/bin/sh\n' > "$tmp/npu/ort-2.0.1/infer"
printf '#!/bin/sh\nexit "${SYSTEMCTL_RC:-0}"\n' > "$tmp/bin/systemctl"
cat > "$tmp/bin/podman" <<'EOT'
#!/bin/sh
[ "$1" = image ] && exit "${IMAGE_RC:-0}"
printf '%s\n' "$*" > "$ARGS"
printf '%b' "$INFER_OUT"
exit "${INFER_RC:-0}"
EOT
chmod +x "$tmp/bin/"* "$tmp/npu/ort-2.0.1/infer"
echo demo > "$tmp/role"
run() { PATH="$tmp/bin:$PATH" ROLE_FILE="$tmp/role" NPU_DIR="$tmp/npu" ARGS="$tmp/args" sh "$s" "$@"; }
# The tail of a real infer run (vendor infer.cpp).
good='Registering Renesas EP...\n\n========== Latency Results ==========\n  Average Latency / Run : 21.328 ms\n  Total Runs            : 20\n'
out=$(INFER_OUT="$good" run perf/merged/set 20) || fail "good_failed out=$out"
[ "$out" = 'NPU_CONTRACT_PASS avg_ms=21.328 runs=20 image=localhost/x5h-visionpilot:latest' ] || fail "pass_line out=$out"
# The contract is the command line: devices by destination name, both mounts,
# infer from the EP package as the entrypoint, and the ARC parent directory.
args=$(cat "$tmp/args")
for tok in '--device /dev/uio2:/dev/npuc0' '--device /dev/uio3:/dev/npuc1' '--device /dev/cmem0 ' \
    '--device /dev/cmem_other0' '--device /dev/cmem_other3' "-v $tmp/npu:/npu" \
    "-v $tmp/npu/perf/merged:/home/youtalk/src/openadkit/x5h-work/npu/merged:ro" \
    '--entrypoint /npu/ort-2.0.1/infer localhost/x5h-visionpilot:latest' \
    '--artifacts /npu/perf/merged/set' '--binary /npu/ort-2.0.1/binary ' '--runs 20'; do
    grep -qF -- "$tok" <<<"$args" || fail "missing_arg: $tok"
done
grep -q 'arc_prog_npus' <<<"$args" && fail binary_names_arc_subdir
# infer returns -1 (255) on an ONNX Runtime exception.
out=$(INFER_OUT='ONNX Runtime Exception: RenesasBackendExecute failed\n' INFER_RC=255 run perf/merged/set) && fail exception_accepted
grep -q 'reason=infer_rc_255$' <<<"$out" || fail "exception_reason out=$out"
# A clean exit with no latency line is not a pass.
out=$(INFER_OUT='Registering Renesas EP...\n' run perf/merged/set) && fail no_latency_accepted
grep -q 'reason=no_latency$' <<<"$out" || fail no_latency_reason
for bad in yocto cr52 ''; do
    echo "$bad" > "$tmp/role"; out=$(INFER_OUT="$good" run perf/merged/set) && fail "role_${bad:-unset}_accepted"
    grep -q "reason=wrong_role role=$bad\$" <<<"$out" || fail "role_${bad:-unset}_reason"
done
echo dev > "$tmp/role"; out=$(INFER_OUT="$good" run perf/merged/set) || fail dev_refused
echo demo > "$tmp/role"
out=$(SYSTEMCTL_RC=3 INFER_OUT="$good" run perf/merged/set) && fail npu_not_ready_accepted
grep -q 'reason=npu_not_ready$' <<<"$out" || fail npu_not_ready_reason
out=$(INFER_OUT="$good" run perf/merged/none) && fail missing_artifacts_accepted
grep -q 'reason=no_artifacts ' <<<"$out" || fail no_artifacts_reason
out=$(IMAGE_RC=1 INFER_OUT="$good" run perf/merged/set) && fail missing_image_accepted
grep -q 'reason=no_image$' <<<"$out" || fail no_image_reason
chmod -x "$tmp/npu/ort-2.0.1/infer"
out=$(INFER_OUT="$good" run perf/merged/set) && fail missing_infer_accepted
grep -q 'reason=no_infer$' <<<"$out" || fail no_infer_reason
out=$(run) && fail no_args_accepted
grep -q 'reason=bad_args$' <<<"$out" || fail bad_args_reason
echo "TEST_PASS $name"
