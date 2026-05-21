#!/usr/bin/env bash
# scripts/build.sh - local convenience wrapper around `docker buildx bake -f docker/bake.hcl`.
#
# Drives the docker/bake.hcl pipeline used by the CI workflows under
# .github/workflows/build-all-images.yaml and release-all-images.yaml.
# Component images inherit from upstream
# ghcr.io/autowarefoundation/autoware:universe[-devel][-cuda]-<distro>.
set -euo pipefail

# Resolve the bake file via the script's own location so the wrapper works
# regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAKE_FILE="$REPO_ROOT/docker/bake.hcl"

ROS_DISTRO="jazzy"
UPSTREAM_VERSION=""
CUDA=0
TARGET=""

print_help() {
  cat <<EOF
Usage: scripts/build.sh [--ros-distro humble|jazzy] [--cuda] [--upstream-version VERSION] [--target NAME]

Wraps the docker/bake.hcl pipeline. Each component image is built on
top of upstream ghcr.io/autowarefoundation/autoware:universe[-devel][-cuda]-<distro>.

--upstream-version pins every upstream parent stage to the same version
suffix; each stage still resolves to its own per-stage tag
(devel/runtime, CUDA siblings).

Examples:
  scripts/build.sh
  scripts/build.sh --ros-distro humble --cuda
  scripts/build.sh --target sensing-perception
  scripts/build.sh --upstream-version 1.8.0
EOF
}

require_value() {
  local flag="$1" val="${2:-}"
  if [ -z "$val" ] || [[ "$val" == --* ]]; then
    echo "$flag requires a value" >&2
    exit 1
  fi
  printf '%s' "$val"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)            print_help; exit 0 ;;
    --ros-distro)         ROS_DISTRO=$(require_value --ros-distro "${2:-}"); shift 2 ;;
    --cuda)               CUDA=1; shift ;;
    --upstream-version)   UPSTREAM_VERSION=$(require_value --upstream-version "${2:-}"); shift 2 ;;
    --target)             TARGET=$(require_value --target "${2:-}"); shift 2 ;;
    *) echo "Unknown option: $1" >&2; print_help; exit 1 ;;
  esac
done

case "$ROS_DISTRO" in humble|jazzy) ;; *) echo "ros-distro must be humble|jazzy" >&2; exit 1 ;; esac

if [ -n "$TARGET" ]; then
  bake_targets=("$TARGET")
elif [ "$CUDA" -eq 1 ]; then
  bake_targets=(default-cuda)
else
  bake_targets=(default)
fi

# Pass ROS_DISTRO and UPSTREAM_VERSION as environment variables so they bind to
# the HCL `variable` declarations in docker/bake.hcl; the args blocks in
# _component-base then propagate them into Dockerfile ARGs. (`--set
# "*.args.NAME=..."` would only set the Dockerfile ARG and leave the HCL
# variable at its default, which would silently break the `upstream()` and
# `tags()` helpers.)
set -x
exec env \
  ROS_DISTRO="$ROS_DISTRO" \
  UPSTREAM_VERSION="$UPSTREAM_VERSION" \
  docker buildx bake -f "$BAKE_FILE" "${bake_targets[@]}"
