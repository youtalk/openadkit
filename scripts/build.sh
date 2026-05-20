#!/usr/bin/env bash
# scripts/build.sh - local convenience wrapper around `docker buildx bake -f docker/bake.hcl`
set -euo pipefail

ROS_DISTRO="jazzy"
UPSTREAM_TAG=""
CUDA=0
TARGET=""

print_help() {
  cat <<EOF
Usage: scripts/build.sh [--ros-distro humble|jazzy] [--cuda] [--upstream-tag TAG] [--target NAME]

Examples:
  scripts/build.sh
  scripts/build.sh --ros-distro humble --cuda
  scripts/build.sh --target sensing-perception
  scripts/build.sh --upstream-tag universe-jazzy-1.8.0
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
    -h|--help)         print_help; exit 0 ;;
    --ros-distro)      ROS_DISTRO=$(require_value --ros-distro "${2:-}"); shift 2 ;;
    --cuda)            CUDA=1; shift ;;
    --upstream-tag)    UPSTREAM_TAG=$(require_value --upstream-tag "${2:-}"); shift 2 ;;
    --target)          TARGET=$(require_value --target "${2:-}"); shift 2 ;;
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

set -x
exec docker buildx bake -f docker/bake.hcl \
  ${UPSTREAM_TAG:+--set "*.args.UPSTREAM_TAG=${UPSTREAM_TAG}"} \
  --set "*.args.ROS_DISTRO=${ROS_DISTRO}" \
  "${bake_targets[@]}"
