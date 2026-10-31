#!/usr/bin/env bash
# Invariants of the S-CORE twin configuration (the CES 2027 digital twin on
# a Corellium arm64 VM, no NPU, no CR52 link). The twin keeps the demo's run
# targets and fallback, relaxes only the frame deadline, and runs its own
# exec scripts from /usr/local/sbin.
set -u
here=$(cd "$(dirname "$0")" && pwd)
x5h=$here/..
cfg=$x5h/score/config/twin/launch_manager_config.json
fail() { echo "SCORE_TWIN_CONFIG_FAIL reason=$1"; exit 1; }

[ -f "$cfg" ] || fail missing_config
[ -f "$x5h/score/config/twin/BUILD.bazel" ] || fail missing_build
python3 -m json.tool "$cfg" >/dev/null 2>&1 || fail json

out=$(python3 - "$cfg" "$x5h/score/config/demo/launch_manager_config.json" <<'EOF'
import json, sys
twin, demo = (json.load(open(p)) for p in sys.argv[1:3])
comps = twin["components"]
ms = comps.get("visionpilot", {}).get("deployment_config", {}).get("environmental_variables", {}).get("SCORE_VP_FRAME_MAX_MS", "")
if not ms.isdigit() or not 80 < int(ms) <= 400:
    print(f"frame_max_ms={ms}"); sys.exit()
names = sorted(c["component_properties"].get("binary_name", "") for c in comps.values())
if names != ["twin-score-camera", "twin-score-vp", "twin-si-fault"]:
    print("binaries=" + ",".join(names)); sys.exit()
for n in comps:
    if any(s in n for s in ("hb", "bridge", "restamp")):
        print(f"relay_component_{n}"); sys.exit()
for k in ("run_targets", "initial_run_target", "fallback_run_target"):
    if twin.get(k) != demo.get(k):
        print(f"differs_from_demo_{k}"); sys.exit()
print("ok")
EOF
)
[ "$out" = ok ] || fail "$out"

for s in twin-score-camera twin-score-vp twin-si-fault; do
    f=$x5h/score/twin/$s.sh
    [ -f "$f" ] || fail "missing_script_$s"
    if grep -q -E '/dev/uio|cmem|/opt/npu|x5h-si-link' "$f"; then fail "board_only_$s"; fi
done

b=$x5h/score/build-score.sh
[ "$(grep -c -E '^for c in .*\btwin\b' "$b")" = 2 ] || fail build_score_loops
grep -q 'twin/\.' "$b" || fail build_score_twin_dir

echo SCORE_TWIN_CONFIG_PASS
