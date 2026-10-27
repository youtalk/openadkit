#!/usr/bin/env bash
# stage-board.sh check-stack with a fake ssh and podman: PASS when the three
# demo images exist, missing_image (rc 30 on the board) naming the absent
# image, and board_unreachable when ssh itself fails.
set -u
name=test-stage-board-check-stack
here=$(cd "$(dirname "$0")" && pwd); s="$here/../scripts/stage-board.sh"
fail() { echo "TEST_FAIL $name reason=$1"; exit 1; }
[ -r "$s" ] || fail script_missing
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# The fake ssh runs the remote command locally, against the fake podman.
cat > "$tmp/ssh" <<'EOF'
#!/bin/sh
[ -z "${UNREACHABLE:-}" ] || exit 255
for a; do cmd=$a; done
exec sh -c "$cmd"
EOF
cat > "$tmp/podman" <<'EOF'
#!/bin/sh
case " ${MISSING:-} " in *" $3 "*) exit 1 ;; esac
EOF
chmod +x "$tmp/ssh" "$tmp/podman"
run() { PATH="$tmp:$PATH" X5H_STAGE_WORK="$tmp/work" bash "$s" x5h1 "$tmp" check-stack 2>&1; }
out=$(run | tail -1)
[ "$out" = STAGE_STACKCHECK_PASS ] || fail "pass out=$out"
out=$(MISSING=localhost/x5h-image-republish:latest run)
[ "$(printf '%s\n' "$out" | tail -1)" = "STAGE_STACKCHECK_FAIL reason=missing_image" ] || fail "missing out=$out"
printf '%s\n' "$out" | grep -qx '| missing localhost/x5h-image-republish:latest' || fail "missing_not_named out=$out"
out=$(UNREACHABLE=1 run | tail -1)
[ "$out" = "STAGE_STACKCHECK_FAIL reason=board_unreachable rc=255" ] || fail "unreachable out=$out"
echo "TEST_PASS $name"
