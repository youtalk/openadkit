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

# Test dependencies are left out because the build below disables testing.
RUN apt-get update && \
    rosdep update --rosdistro "${ROS_DISTRO}" && \
    rosdep install -y --from-paths /tmp/ros2/src --ignore-src --rosdistro "${ROS_DISTRO}" \
      --dependency-types=build --dependency-types=build_export \
      --dependency-types=buildtool --dependency-types=buildtool_export \
      --dependency-types=exec && \
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

# Register each package built above as an installed ros-jazzy-* deb, so rosdep
# and apt treat it as present and never look for a riscv64 binary. The hold also
# makes the Autoware ansible rmw role skip its apt install. python3-colcon-mixin
# is in the same position: pip installed it, and Ubuntu has no riscv64 build.
RUN cd /tmp/ros2 && mkdir debs && cd debs && \
    for name in python3-colcon-mixin \
        $(colcon list --names-only --base-paths ../src | sed "s/_/-/g; s/^/ros-${ROS_DISTRO}-/"); do \
      mkdir -p "${name}/DEBIAN" && \
      printf 'Package: %s\nVersion: 0.0.0+src\nArchitecture: all\nMaintainer: Open AD Kit\nDescription: provided by the source build in /opt/ros/%s\n' \
        "${name}" "${ROS_DISTRO}" > "${name}/DEBIAN/control" && \
      dpkg-deb --build "${name}" >/dev/null && \
      echo "${name}" >> ../held; \
    done && \
    dpkg -i ./*.deb >/dev/null && \
    xargs apt-mark hold < ../held >/dev/null && \
    rm -rf /tmp/ros2 /tmp/ros2.repos

COPY --chmod=755 <<'EOF' /ros_entrypoint.sh
#!/bin/bash
set -e
source "/opt/ros/${ROS_DISTRO}/setup.bash"
exec "$@"
EOF
ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["bash"]
