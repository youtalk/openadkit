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
[ -n "${FAKE_FAIL:-}" ] && case $c in *"$FAKE_FAIL"*) exit 255 ;; esac
case $c in
    *findmnt*) echo "${FAKE_ROOTFS:-nfs}" ;;
    */proc/mounts*) ;;
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

# --- restore -----------------------------------------------------------------
mk_backup() {
    mkdir -p "$1"
    for n in x5h-boot x5h-root autosd-store yocto-boot yocto-root npu-work lu0; do : > "$1/$n.img.zst"; done
    : > "$1/SHA256SUMS"; : > "$1/sizes.txt"; : > "$1/blkid.txt"; echo "${2:-x5h2}" > "$1/board"
}
mk_backup "$d/r"
out=$(FAKE_LUS=$three bash "$s" x5h2 "$d/r" restore 2>&1)
grep -q 'UFS1_RESTORE_FAIL reason=not_single_lu' <<<"$out" || fail "not_single_lu: $out"

: > "$d/ssh.log"
out=$(FAKE_LUS=$one bash "$s" x5h2 "$d/r" restore 2>&1)
grep -q 'PLAN ONLY' <<<"$out" || fail "restore_plan_only: $out"
for want in '-c1:x5h-boot -u1:7c94f5e2-9e2b-4c31-8f0a-1a2b3c4d5e01' '-n2:0:+24G' '-n3:0:+128G' \
            '-c6:npu-work -u6:7c94f5e2-9e2b-4c31-8f0a-1a2b3c4d5e13' '-n6:0:0'; do
    grep -qF -- "$want" <<<"$out" || fail "restore_plan_missing: $want"
done
grep -qE 'sgdisk -o|dd of=' "$d/ssh.log" && fail restore_plan_only_wrote

mk_backup "$d/r2"; rm "$d/r2/npu-work.img.zst"
out=$(FAKE_LUS=$one bash "$s" x5h2 "$d/r2" restore 2>&1)
grep -q 'UFS1_RESTORE_FAIL reason=backup_incomplete' <<<"$out" || fail "backup_incomplete: $out"

# --- final-review fixes --------------------------------------------------------
# A backup that never finished, or that belongs to the other board, is refused.
mk_backup "$d/r3"; rm "$d/r3/board"
out=$(FAKE_LUS=$one bash "$s" x5h2 "$d/r3" restore 2>&1)
grep -q 'UFS1_RESTORE_FAIL reason=backup_incomplete' <<<"$out" || fail "no_stamp_accepted: $out"
mk_backup "$d/r4" x5h1
out=$(FAKE_LUS=$one bash "$s" x5h2 "$d/r4" restore 2>&1)
grep -q 'UFS1_RESTORE_FAIL reason=backup_of_other_board' <<<"$out" || fail "other_board_accepted: $out"
# Leftover metadata from a failed backup counts as a used directory.
mkdir "$d/meta"; : > "$d/meta/SHA256SUMS"
out=$(FAKE_LUS=$three bash "$s" x5h2 "$d/meta" backup 2>&1)
grep -q 'UFS1_BACKUP_FAIL reason=backup_dir_not_empty' <<<"$out" || fail "leftover_metadata_accepted: $out"
# A transport failure is reported as one, not as a layout or a mount verdict.
out=$(FAKE_FAIL=getsize64 FAKE_LUS=$one bash "$s" x5h2 "$d/r" restore 2>&1)
grep -q 'UFS1_RESTORE_FAIL reason=layout_probe_failed' <<<"$out" || fail "probe_failure_misreported: $out"
out=$(FAKE_FAIL=/proc/mounts FAKE_LUS=$one bash "$s" x5h2 "$d/r" restore 2>&1)
grep -q 'UFS1_RESTORE_FAIL reason=board_unreachable' <<<"$out" || fail "mount_check_fails_open: $out"
# The PLAN says that restore destroys, and the read-back bypasses the page cache.
out=$(FAKE_LUS=$one bash "$s" x5h2 "$d/r" restore 2>&1)
grep -q 'DESTROYS' <<<"$out" || fail "restore_plan_hides_destruction: $out"
grep -q 'blockdev --flushbufs /dev/disk/by-partlabel/$name && head -c' "$s" || fail readback_through_page_cache

echo "TEST_PASS $name"
