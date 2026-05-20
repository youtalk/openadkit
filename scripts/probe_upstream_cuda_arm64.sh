#!/usr/bin/env bash
# scripts/probe_upstream_cuda_arm64.sh
# Prints "true" or "false" on stdout depending on whether the upstream CUDA
# image manifest for the given distro contains a linux/arm64 entry.
#
# CI workflows call this at job start to decide whether to include arm64 in
# the CUDA build matrix (see spec D3). Always exits 0 so the calling step
# can branch on stdout without worrying about set -e.
set -euo pipefail

distro="${1:?usage: $0 <ros_distro>}"
image="ghcr.io/autowarefoundation/autoware:universe-cuda-${distro}"

# The raw manifest list is JSON, sometimes compact and sometimes pretty-printed
# (`docker buildx imagetools inspect --raw` formatting varies by buildx version).
# Match the architecture field tolerantly to whitespace so both forms work.
if docker buildx imagetools inspect --raw "${image}" 2>/dev/null \
   | grep -Eq '"architecture"[[:space:]]*:[[:space:]]*"arm64"'; then
  echo "true"
else
  echo "false"
fi
