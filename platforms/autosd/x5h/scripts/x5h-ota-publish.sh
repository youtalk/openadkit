#!/usr/bin/env bash
# Build the OTA artifacts on the desktop and push them (or save them as OCI
# archive files). Usage:
#   x5h-ota-publish.sh visionpilot <version> <base-image-ref>
#   x5h-ota-publish.sh cr52 <version> <actuation_x5h.elf>
# Env: X5H_OTA_REGISTRY (default ghcr.io/youtalk), X5H_OTA_ARCHIVE (file: save, no push).
# The push uses the desktop's existing `podman login` store. No credential is read here.
set -euo pipefail

registry=${X5H_OTA_REGISTRY:-ghcr.io/youtalk}
archive=${X5H_OTA_ARCHIVE:-}
src_label=org.opencontainers.image.source

die() { echo "X5H_OTA_PUBLISH_FAIL reason=$1"; exit 1; }

[ $# -eq 3 ] || die usage
component=$1; version=$2; input=$3
case $component in
  visionpilot) pkg=x5h-visionpilot ;;
  cr52) pkg=x5h-cr52-si ;;
  *) die usage ;;
esac
# A case pattern plus a length check: grep tests each line alone and would accept a new line.
case $version in *[!A-Za-z0-9._-]*) die bad_version ;; esac
{ [ "${#version}" -ge 1 ] && [ "${#version}" -le 64 ]; } || die bad_version
# An archive carries the name localhost/<pkg>:<version>, and the board refuses
# an archive named like a hook tag.
case $version in latest | previous | staged) die bad_version ;; esac

ctx=$(mktemp -d); trap 'rm -rf "$ctx"' EXIT
labels=(--label "org.opencontainers.image.version=$version" --label "x5h.ota.component=$component")

if [ "$component" = visionpilot ]; then
  arch=$(podman image inspect -f '{{.Architecture}}' "$input") || die inspect_failed
  [ "$arch" = arm64 ] || die bad_arch
  echo "FROM $input" > "$ctx/Containerfile"
else
  [ -f "$input" ] || die no_elf
  # The slot payload is the first LOAD segment: field 2 is the offset, field 5 the file size.
  read -r off size < <(readelf -lW "$input" | awk '$1 == "LOAD" { print $2, $5; exit }')
  [ -n "${off:-}" ] || die no_load_segment
  # No pipe: head would close early and tail would die of SIGPIPE under pipefail.
  dd if="$input" of="$ctx/slot.bin" bs=64K iflag=skip_bytes,count_bytes skip="$((off))" count="$((size))" status=none || die cut_failed
  [ "$(stat -c %s "$ctx/slot.bin")" -eq "$((size))" ] || die short_payload
  cp "$input" "$ctx/actuation_x5h.elf"
  # An archive skips this check (gates U2 and U4); a push never does.
  if [ -z "$archive" ]; then
    for f in slot.bin actuation_x5h.elf; do
      # The banner ends the version with a new line, so v1 must not match v10.
      grep -qaE "X5H_SI_VERSION=${version//./\\.}([^A-Za-z0-9._-]|\$)" "$ctx/$f" || die no_version_string
    done
  fi
  labels+=(--label "x5h.ota.sha256=$(sha256sum < "$ctx/slot.bin" | cut -d' ' -f1)"
           --label "x5h.ota.elf_sha256=$(sha256sum < "$ctx/actuation_x5h.elf" | cut -d' ' -f1)")
  printf 'FROM scratch\nCOPY slot.bin actuation_x5h.elf /cr52/\n' > "$ctx/Containerfile"
fi

local_ref=localhost/$pkg:$version
podman build --platform linux/arm64 "${labels[@]}" -t "$local_ref" -f - "$ctx" < "$ctx/Containerfile" >&2 || die build_failed

# A base image can carry the source label, which would link the package to the public repo.
src=$(podman image inspect -f "{{index .Labels \"$src_label\"}}" "$local_ref") || die inspect_failed
[ -z "$src" ] || [ "$src" = '<no value>' ] || die source_label

if [ -n "$archive" ]; then
  podman save --format oci-archive -o "$archive" "$local_ref" >&2 || die save_failed
  echo "X5H_OTA_ARCHIVED component=$component version=$version path=$archive"
  exit 0
fi

podman push --digestfile "$ctx/digest" "$local_ref" "docker://$registry/$pkg:$version" >&2 || die push_failed
echo "X5H_OTA_PUBLISHED component=$component version=$version ref=$registry/$pkg@$(cat "$ctx/digest")"
