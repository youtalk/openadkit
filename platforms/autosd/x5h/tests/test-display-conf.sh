#!/usr/bin/env bash
# vision_pilot.display.conf is vision_pilot.conf with the HUD composed and the
# KMS sink on, and nothing else. A copy drifts: a speed limit or a model path
# changed in one file and not in the other would put a different VisionPilot
# on the monitor than the one the gates measure. Compare them with comments
# and the two display lines removed.
set -u
name=test-display-conf
here=$(cd "$(dirname "$0")" && pwd)
d="$here/../components/demo"
fail() { echo "TEST_FAIL $name reason=$1"; exit 1; }
[ -r "$d/vision_pilot.conf" ] || fail base_missing
[ -r "$d/vision_pilot.display.conf" ] || fail display_missing
strip() { grep -v -E '^[[:space:]]*(#|$)' "$1" | grep -v -E '^(visualization_on|kms_display)[[:space:]]*='; }
[ "$(strip "$d/vision_pilot.conf")" = "$(strip "$d/vision_pilot.display.conf")" ] || fail drift
cfg=$(grep -v -E '^[[:space:]]*#' "$d/vision_pilot.display.conf")
grep -q -E '^visualization_on[[:space:]]*=[[:space:]]*true$' <<<"$cfg" || fail visualization_off
grep -q -E '^kms_display[[:space:]]*=[[:space:]]*rcar-vcon$' <<<"$cfg" || fail kms_off
base=$(grep -v -E '^[[:space:]]*#' "$d/vision_pilot.conf")
grep -q -E '^kms_display[[:space:]]*=[[:space:]]*$' <<<"$base" || fail base_kms_not_empty
echo "TEST_PASS $name"
