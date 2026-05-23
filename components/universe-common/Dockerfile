# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom,UndefinedVar
ARG CORE_DEVEL_IMAGE
ARG CORE_IMAGE

# =============================================================================
# Stage: universe-common-devel
# Compiles the universe-common slice into /opt/autoware on top of core-devel.
# =============================================================================
FROM ${CORE_DEVEL_IMAGE} AS universe-common-devel
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG ROS_DISTRO

# rosdep install for the universe-common slice (build/test deps).
COPY --parents --chown=${USERNAME}:${USERNAME} \
    autoware/src/universe/autoware_universe/common/**/package.xml \
    autoware/src/universe/autoware_universe/evaluator/**/package.xml \
    autoware/src/universe/external/eagleye/**/package.xml \
    autoware/src/universe/external/glog/**/package.xml \
    autoware/src/universe/external/llh_converter/**/package.xml \
    autoware/src/universe/external/managed_transform_buffer/**/package.xml \
    autoware/src/universe/external/morai_msgs/**/package.xml \
    autoware/src/universe/external/muSSP/**/package.xml \
    autoware/src/universe/external/pointcloud_to_laserscan/**/package.xml \
    autoware/src/universe/external/rtklib_ros_bridge/**/package.xml \
    autoware/src/universe/external/tier4_autoware_msgs/**/package.xml \
    autoware/src/middleware/external/**/package.xml \
    /tmp/

RUN --mount=type=cache,id=apt-cache-${ROS_DISTRO},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lists-${ROS_DISTRO},target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    . "/opt/ros/${ROS_DISTRO}/setup.sh" && \
    . /opt/autoware/setup.sh && \
    rosdep install -y --from-paths /tmp/autoware/src \
      --ignore-src --rosdistro "${ROS_DISTRO}" \
      --dependency-types=build --dependency-types=build_export \
      --dependency-types=buildtool --dependency-types=buildtool_export \
      --dependency-types=test

# colcon build the universe-common slice into /opt/autoware (next to core).
RUN --mount=type=bind,source=autoware/src,target=/tmp/autoware/src \
    --mount=type=cache,id=ccache-${ROS_DISTRO},target=/home/aw/.ccache,uid=1000,gid=1000 \
    . "/opt/ros/${ROS_DISTRO}/setup.sh" && \
    . /opt/autoware/setup.sh && \
    colcon build \
      --base-paths \
        /tmp/autoware/src/universe/autoware_universe/common \
        /tmp/autoware/src/universe/autoware_universe/evaluator \
        /tmp/autoware/src/universe/external/eagleye \
        /tmp/autoware/src/universe/external/glog \
        /tmp/autoware/src/universe/external/llh_converter \
        /tmp/autoware/src/universe/external/managed_transform_buffer \
        /tmp/autoware/src/universe/external/morai_msgs \
        /tmp/autoware/src/universe/external/muSSP \
        /tmp/autoware/src/universe/external/pointcloud_to_laserscan \
        /tmp/autoware/src/universe/external/rtklib_ros_bridge \
        /tmp/autoware/src/universe/external/tier4_autoware_msgs \
        /tmp/autoware/src/middleware/external \
      --install-base /opt/autoware \
      --cmake-args -DCMAKE_BUILD_TYPE=Release && \
    rm -rf build log

# Exec-only rosdep for the universe-common slice.
RUN --mount=type=cache,id=apt-cache-${ROS_DISTRO},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lists-${ROS_DISTRO},target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    . "/opt/ros/${ROS_DISTRO}/setup.sh" && \
    rosdep install -y --from-paths /tmp/autoware/src \
      --ignore-src --rosdistro "${ROS_DISTRO}" \
      --dependency-types=exec && \
    rm -rf /tmp/autoware

# =============================================================================
# Stage: universe-common
# Runtime variant: exec deps + the compiled tree, on top of core.
# =============================================================================
FROM ${CORE_IMAGE} AS universe-common
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG ROS_DISTRO

USER root
COPY --from=universe-common-devel /opt/autoware /opt/autoware
RUN find /opt/autoware -name '*.so' -exec strip --strip-unneeded {} +

COPY --parents --chown=${USERNAME}:${USERNAME} \
    autoware/src/universe/autoware_universe/common/**/package.xml \
    autoware/src/universe/autoware_universe/evaluator/**/package.xml \
    autoware/src/universe/external/**/package.xml \
    autoware/src/middleware/external/**/package.xml \
    /tmp/

RUN --mount=type=cache,id=apt-cache-${ROS_DISTRO},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lists-${ROS_DISTRO},target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    . "/opt/ros/${ROS_DISTRO}/setup.sh" && \
    rosdep install -y --from-paths /tmp \
      --dependency-types=exec --ignore-src --rosdistro "${ROS_DISTRO}" && \
    rm -rf /tmp/*
