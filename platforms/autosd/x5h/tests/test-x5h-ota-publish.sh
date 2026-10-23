#!/usr/bin/env bash
# x5h-ota-publish.sh with a fake podman and a fake readelf: labels, the
# arm64 and source-label refusals, the slot cut, the version string check and
# the archive mode. No network.
set -u
name=test-x5h-ota-publish
here=$(cd "$(dirname "$0")" && pwd); s="$here/../scripts/x5h-ota-publish.sh"
fail() { echo "TEST_FAIL $name reason=$1"; exit 1; }
exact() { [ "$1" = "$2" ] || fail "$3 out=$1"; }
[ -x "$s" ] || fail script_missing
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"; export T LOG="$T/log"
b64=$(printf 'b%.0s' $(seq 64))

cat > "$T/bin/podman" <<'EOF2'
#!/bin/sh
echo "$*" >> "$LOG"
case "$1 $2" in
  "image inspect")
    case "$4" in
      *Architecture*) echo "${ARCH:-arm64}" ;;
      *) echo "${SRC_LABEL:-}" ;;
    esac ;;
  "build "*)
    for a; do ctx=$a; done
    n=$(ls "$T" | grep -c '^ctx\.')
    cp -r "$ctx" "$T/ctx.$n" ;;
  "push "*)
    echo push >> "$T/pushed"
    printf 'sha256:%s' "$(printf 'b%.0s' $(seq 64))" > "$3" ;;
esac
exit 0
EOF2
# Real firmware shape: EXIDX, the payload LOAD, then a small .resource_table LOAD.
cat > "$T/bin/readelf" <<'EOF2'
#!/bin/sh
cat <<'EOF3'
Program Headers:
  Type           Offset   VirtAddr   PhysAddr   FileSiz  MemSiz    Flg Align
  EXIDX          0x0a0000 0x116a0000 0x116a0000 0x00010 0x00010 R   0x4
  LOAD           0x001000 0x11600000 0x11600000 0x002710 0x086e180 RWE 0x1000
  LOAD           0x00b000 0x96650000 0x96650000 0x00100 0x00100 RW  0x1000
EOF3
EOF2
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

# ELF fixture: 0x1000 bytes of header, then 10000 payload bytes holding the version.
{ printf '\177ELF'; head -c 4092 /dev/zero
  printf 'X5H_SI_VERSION=v1\n'; head -c $((10000 - 18)) /dev/zero | tr '\0' 'p'
  printf 'tail'; } > "$T/fw.elf"
tail -c +4097 "$T/fw.elf" | head -c 10000 > "$T/want.bin"

run() { : > "$LOG"; rm -rf "$T"/ctx.* "$T/pushed"; "$@" 2>&1; }
pushed() { [ -e "$T/pushed" ]; }

out=$(run bash "$s" visionpilot v1 localhost/x5h-visionpilot:cacr) || fail "vp_push rc out=$out"
exact "$out" "X5H_OTA_PUBLISHED component=visionpilot version=v1 ref=ghcr.io/youtalk/x5h-visionpilot@sha256:$b64" vp_push
grep -q -- '--label org.opencontainers.image.version=v1' "$LOG" || fail vp_label_version
grep -q -- '--label x5h.ota.component=visionpilot' "$LOG" || fail vp_label_component
grep -q -- '--platform linux/arm64' "$LOG" || fail vp_platform

out=$(ARCH=amd64 run bash "$s" visionpilot v1 localhost/x5h-visionpilot:cacr) && fail vp_arch_accepted
exact "$out" 'X5H_OTA_PUBLISH_FAIL reason=bad_arch' vp_arch
pushed && fail vp_arch_pushed

out=$(SRC_LABEL=https://github.com/example/repo run bash "$s" visionpilot v1 localhost/x5h-visionpilot:cacr) && fail vp_source_accepted
exact "$out" 'X5H_OTA_PUBLISH_FAIL reason=source_label' vp_source
pushed && fail vp_source_pushed
out=$(SRC_LABEL='<no value>' run bash "$s" visionpilot v1 localhost/x5h-visionpilot:cacr) || fail "no_value_refused out=$out"

out=$(run bash "$s" cr52 v1 "$T/fw.elf") || fail "cr52_push rc out=$out"
exact "$out" "X5H_OTA_PUBLISHED component=cr52 version=v1 ref=ghcr.io/youtalk/x5h-cr52-si@sha256:$b64" cr52_push
cmp -s "$T/ctx.0/slot.bin" "$T/want.bin" || fail slot_bytes
cmp -s "$T/ctx.0/actuation_x5h.elf" "$T/fw.elf" || fail elf_copy
grep -q -- "x5h.ota.sha256=$(sha256sum < "$T/want.bin" | cut -d' ' -f1)" "$LOG" || fail label_slot_sha
grep -q -- "x5h.ota.elf_sha256=$(sha256sum < "$T/fw.elf" | cut -d' ' -f1)" "$LOG" || fail label_elf_sha
grep -q -- '--label x5h.ota.component=cr52' "$LOG" || fail cr52_component

out=$(run bash "$s" cr52 v2 "$T/fw.elf") && fail noversion_accepted
exact "$out" 'X5H_OTA_PUBLISH_FAIL reason=no_version_string' cr52_noversion
grep -q '^build' "$LOG" && fail noversion_built

out=$(run bash "$s" cr52 baseline "$T/fw.elf") && fail baseline_push_accepted
exact "$out" 'X5H_OTA_PUBLISH_FAIL reason=no_version_string' baseline_push
pushed && fail baseline_pushed

out=$(X5H_OTA_ARCHIVE="$T/b.tar" run bash "$s" cr52 baseline "$T/fw.elf") || fail "baseline_archive rc out=$out"
exact "$out" "X5H_OTA_ARCHIVED component=cr52 version=baseline path=$T/b.tar" baseline_archive
grep -q -- "save --format oci-archive -o $T/b.tar" "$LOG" || fail save_call
pushed && fail archive_pushed

# A real ELF is far larger than the payload: no SIGPIPE, and a banner ending in a new line.
{ head -c 4096 "$T/fw.elf"; printf 'X5H_SI_VERSION=v1\n'; head -c $((10000 - 18)) /dev/zero | tr '\0' 'p'
  head -c 2097152 /dev/zero | tr '\0' 'q'; } > "$T/big.elf"
out=$(run bash "$s" cr52 v1 "$T/big.elf") || fail "big_elf rc out=$out"
exact "$out" "X5H_OTA_PUBLISHED component=cr52 version=v1 ref=ghcr.io/youtalk/x5h-cr52-si@sha256:$b64" big_elf
tail -c +4097 "$T/big.elf" | head -c 10000 | cmp -s - "$T/ctx.0/slot.bin" || fail big_slot_bytes

# v1 must not match a binary that says v10.
{ head -c 4096 "$T/fw.elf"; printf 'X5H_SI_VERSION=v10\n'; head -c $((10000 - 19)) /dev/zero | tr '\0' 'p'; } > "$T/v10.elf"
out=$(run bash "$s" cr52 v1 "$T/v10.elf") && fail prefix_accepted
exact "$out" 'X5H_OTA_PUBLISH_FAIL reason=no_version_string' prefix_version
grep -q '^build' "$LOG" && fail prefix_built

# A truncated ELF is refused.
head -c 6000 "$T/fw.elf" > "$T/short.elf"
out=$(run bash "$s" cr52 v1 "$T/short.elf") && fail short_accepted
exact "$out" 'X5H_OTA_PUBLISH_FAIL reason=short_payload' short_payload

# latest, previous and staged are hook tag names, and the archive carries the version as its name.
for v in 'v1 x' 'v1;reboot' "$(printf 'v1\nstate=ok')" '' "$(printf 'a%.0s' $(seq 65))" latest previous staged; do
  out=$(run bash "$s" visionpilot "$v" localhost/x:y) && fail "bad_version_accepted"
  exact "$out" "X5H_OTA_PUBLISH_FAIL reason=bad_version" "bad_version[$v]"
  grep -q '^build' "$LOG" && fail "bad_version_built[$v]"
done
echo "TEST_PASS $name"
