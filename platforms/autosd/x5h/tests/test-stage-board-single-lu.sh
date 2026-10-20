#!/usr/bin/env bash
# stage-board.sh on a board whose UFS1 is one LU: write-root must grow the
# root filesystem to its (bigger) partition, and partition-lun2 must say why
# it does not apply instead of a bare "no device".
set -u
name=test-stage-board-single-lu
here=$(cd "$(dirname "$0")" && pwd)
s="$here/../scripts/stage-board.sh"
fail() { echo "TEST_FAIL $name reason=$1"; exit 1; }
[ -f "$s" ] || fail script_missing
wr=$(sed -n '/^write_root() {/,/^}/p' "$s")
[ -n "$wr" ] || fail no_write_root
# The grow must come after the read-back check, so it never runs on a bad copy.
after=${wr#*readback_mismatch}
[ "$after" != "$wr" ] || fail no_readback_check
grep -q 'resize2fs' <<<"$after" || fail write_root_does_not_grow
grep -q 'STAGE_WRITE_FAIL reason=grow_failed' <<<"$after" || fail grow_failure_not_reported
grep -q 'no_lun2_device.*single-LU' "$s" || fail lun2_message_silent_on_single_lu
echo "TEST_PASS $name"
