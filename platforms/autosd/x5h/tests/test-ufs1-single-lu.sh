#!/usr/bin/env bash
# ufs1-single-lu.sh without a board: a fake ssh answers the probes, and the
# tests check the refusals and that a run without --yes never touches a disk.
set -u
name=test-ufs1-single-lu
here=$(cd "$(dirname "$0")" && pwd)
s="$here/../scripts/ufs1-single-lu.sh"
fail() { echo "TEST_FAIL $name reason=$1"; exit 1; }
[ -f "$s" ] || fail script_missing
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
mkdir "$d/bin"
cat > "$d/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
c=${!#}
case $c in
    *findmnt*) echo "${FAKE_ROOTFS:-nfs}" ;;
    */proc/mounts*) exit 1 ;;
    *getsize64*) printf "$FAKE_LUS" ;;
esac
exit 0
FAKE
chmod +x "$d/bin/ssh"
export PATH="$d/bin:$PATH" FAKE_LOG="$d/ssh.log"
lu=/dev/disk/by-path/platform-c0a90000.ufs-scsi-0:0:0
three="$lu:0 402653184\n$lu:1 34359738368\n$lu:2 34359738368\n"
one="$lu:0 255944818688\n"

out=$(bash "$s" 2>&1); rc=$?
[ $rc -eq 2 ] && grep -q 'UFS1_FAIL reason=bad_args' <<<"$out" || fail "bad_args: $out"

mkdir "$d/full"; : > "$d/full/x5h-root.img.zst"
out=$(FAKE_LUS=$three bash "$s" x5h2 "$d/full" backup 2>&1)
grep -q 'UFS1_BACKUP_FAIL reason=backup_dir_not_empty' <<<"$out" || fail "backup_dir_not_empty: $out"

out=$(FAKE_ROOTFS=ext4 FAKE_LUS=$three bash "$s" x5h2 "$d/b1" backup 2>&1)
grep -q 'UFS1_BACKUP_FAIL reason=not_in_rescue' <<<"$out" || fail "not_in_rescue: $out"

out=$(FAKE_LUS=$one bash "$s" x5h2 "$d/b2" backup 2>&1)
grep -q 'UFS1_BACKUP_FAIL reason=not_three_lu_layout' <<<"$out" || fail "not_three_lu_layout: $out"

: > "$d/ssh.log"
out=$(FAKE_LUS=$three bash "$s" x5h2 "$d/b3" backup 2>&1)
grep -q 'PLAN ONLY' <<<"$out" || fail "backup_plan_only: $out"
grep -q 'dd if=' "$d/ssh.log" && fail backup_plan_only_streamed

echo "TEST_PASS $name"
