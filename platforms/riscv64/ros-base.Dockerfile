# syntax=docker/dockerfile:1
# ROS 2 Jazzy for linux/riscv64, built from source because packages.ros.org
# publishes no riscv64 binaries. The image stands in for ros:jazzy-ros-base,
# so the upstream Autoware Dockerfiles build on top of it unchanged.
FROM ubuntu:24.04
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV ROS_DISTRO=jazzy \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# Ubuntu ships only colcon-core for riscv64, so the ROS tools come from PyPI.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential ca-certificates cmake curl git \
      python3-dev python3-pip python3-setuptools && \
    pip3 install --no-cache-dir --break-system-packages \
      colcon-common-extensions colcon-mixin rosdep vcstool && \
    rosdep init && \
    rm -rf /var/lib/apt/lists/*

COPY platforms/riscv64/ros2.repos /tmp/ros2.repos
RUN mkdir -p /tmp/ros2/src && \
    vcs import --shallow --workers 16 --input /tmp/ros2.repos /tmp/ros2/src

# placeholder-debs registers packages that are present in the image but were
# not installed by apt as held, empty debs. rosdep and apt then treat them as
# installed and never look for a riscv64 binary. The hold also makes the
# Autoware ansible rmw role skip its apt install.
COPY --chmod=755 <<'EOF' /usr/local/bin/placeholder-debs
#!/bin/bash
set -euo pipefail
dir="$(mktemp -d)"
cd "${dir}"
for name in "$@"; do
  mkdir -p "${name}/DEBIAN"
  printf 'Package: %s\nVersion: 0.0.0+src\nArchitecture: all\nMaintainer: Open AD Kit\nDescription: present in the image, not installed by apt\n' \
    "${name}" > "${name}/DEBIAN/control"
  dpkg-deb --build "${name}" >/dev/null
done
dpkg -i ./*.deb >/dev/null
apt-mark hold "$@" >/dev/null
rm -rf "${dir}"
EOF

# Only packages.ros.org has these as debs. pip installed the modules that the
# image builds use. The Autoware ros2_dev_tools role asks for all of them, and
# it does not use bloom or vcs2l.
RUN placeholder-debs \
      python3-catkin-pkg-modules python3-rosdistro-modules python3-rospkg-modules \
      python3-rosdep-modules python3-rosdep python3-colcon-common-extensions \
      python3-colcon-mixin python3-vcstool ros-build-essential python3-bloom python3-vcs2l

# Test dependencies are left out because the build below disables testing.
# The skipped keys are the packages that gen-ros2-repos.sh leaves out.
# rosdep runs apt-get once per package, which takes about 45 minutes under
# emulation, so collect the list and run apt-get once.
RUN apt-get update && \
    rosdep update --rosdistro "${ROS_DISTRO}" && \
    pkgs="$(rosdep install --simulate -y --from-paths /tmp/ros2/src --ignore-src \
      --rosdistro "${ROS_DISTRO}" \
      --skip-keys "mimick_vendor rmw_connextdds rmw_connextdds_common rti_connext_dds_cmake_module" \
      --dependency-types=build --dependency-types=build_export \
      --dependency-types=buildtool --dependency-types=buildtool_export \
      --dependency-types=exec | sed -n 's/.*apt-get install -y //p')" && \
    apt-get install -y ${pkgs} && \
    rm -rf /var/lib/apt/lists/*

# The build tree is a cache mount, so a failed build resumes where it stopped.
# On failure, print the log tail of each package that failed.
RUN --mount=type=cache,id=ros2-jazzy-riscv64-build,target=/tmp/ros2/build \
    cd /tmp/ros2 && \
    { MAKEFLAGS="-j8 -l128" colcon build \
        --merge-install --install-base "/opt/ros/${ROS_DISTRO}" \
        --parallel-workers 32 \
        --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
        2>&1 | tee /tmp/colcon.out || \
      { for p in $(sed -n 's/^Failed *<<< \([^ ]*\).*/\1/p' /tmp/colcon.out); do \
          echo "===== ${p}"; tail -n 60 "log/latest_build/${p}/stdout_stderr.log"; \
        done; exit 1; }; } && \
    rm -rf log /tmp/colcon.out

# Register each package built above as an installed ros-jazzy-* deb.
RUN placeholder-debs $(colcon list --names-only --base-paths /tmp/ros2/src | \
      sed "s/_/-/g; s/^/ros-${ROS_DISTRO}-/") && \
    rm -rf /tmp/ros2 /tmp/ros2.repos

# The images built on top of this one need these riscv64 adjustments, which
# live here so that their Dockerfiles stay unchanged:
# - PyPI has no riscv64 wheels for cryptography (needed by ansible) and some
#   other packages. The RISE Project index has them. Prefer an older wheel to
#   building a newer sdist. clang-format and casadi still build from source,
#   and the clang-format build needs ninja. This goes in /etc/pip.conf, not
#   in the environment, because the ansible roles run pip through sudo.
# - colcon and make start one job per CPU by default. Under emulation on a
#   many-core host, that uses more memory than the host has.
ARG COLCON_WORKERS=16
ARG MAKE_JOBS=4
ARG MAKE_LOAD=96
RUN apt-get update && \
    apt-get install -y --no-install-recommends ninja-build && \
    rm -rf /var/lib/apt/lists/* && \
    printf '[global]\nextra-index-url = https://gitlab.com/api/v4/projects/56254198/packages/pypi/simple\nprefer-binary = true\n' \
      > /etc/pip.conf && \
    mkdir -p /etc/colcon && \
    printf 'build:\n  parallel-workers: %s\n' "${COLCON_WORKERS}" > /etc/colcon/defaults.yaml
ENV COLCON_DEFAULTS_FILE=/etc/colcon/defaults.yaml \
    MAKEFLAGS="-j${MAKE_JOBS} -l${MAKE_LOAD}" \
    CMAKE_BUILD_PARALLEL_LEVEL=64

COPY --chmod=755 <<'EOF' /ros_entrypoint.sh
#!/bin/bash
set -e
source "/opt/ros/${ROS_DISTRO}/setup.bash"
exec "$@"
EOF
ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["bash"]
