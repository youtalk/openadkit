# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom,UndefinedVar
ARG UNIVERSE_COMMON_DEVEL_IMAGE
ARG UNIVERSE_COMMON_IMAGE

# =============================================================================
# Build stage: planning-control-devel
# =============================================================================
FROM ${UNIVERSE_COMMON_DEVEL_IMAGE} AS planning-control-devel
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG ROS_DISTRO

# autoware_pcl_extensions / autoware_pointcloud_preprocessor / autoware_cuda_utils /
# autoware_tensorrt_common / autoware_tensorrt_plugins / autoware_external_cmd_converter /
# autoware_raw_vehicle_cmd_converter / autoware_command_mode_types are pulled in until
# https://github.com/autowarefoundation/autoware_universe/issues/8805 is resolved.
COPY --parents --chown=${USERNAME}:${USERNAME} \
    autoware/src/launcher/autoware_launch/tier4_universe_launch/tier4_control_launch/**/package.xml \
    autoware/src/launcher/autoware_launch/tier4_universe_launch/tier4_planning_launch/**/package.xml \
    autoware/src/universe/autoware_universe/control/**/package.xml \
    autoware/src/universe/autoware_universe/planning/**/package.xml \
    autoware/src/universe/autoware_universe/sensing/autoware_pcl_extensions/**/package.xml \
    autoware/src/universe/autoware_universe/sensing/autoware_pointcloud_preprocessor/**/package.xml \
    autoware/src/universe/autoware_universe/sensing/autoware_cuda_utils/**/package.xml \
    autoware/src/universe/autoware_universe/perception/autoware_tensorrt_common/**/package.xml \
    autoware/src/universe/autoware_universe/perception/autoware_tensorrt_plugins/**/package.xml \
    autoware/src/universe/autoware_universe/vehicle/autoware_external_cmd_converter/**/package.xml \
    autoware/src/universe/autoware_universe/vehicle/autoware_raw_vehicle_cmd_converter/**/package.xml \
    autoware/src/universe/autoware_universe/system/autoware_command_mode_types/**/package.xml \
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

RUN --mount=type=bind,source=autoware/src,target=/tmp/autoware/src \
    --mount=type=cache,id=ccache-${ROS_DISTRO},target=/home/aw/.ccache,uid=1000,gid=1000 \
    . "/opt/ros/${ROS_DISTRO}/setup.sh" && \
    . /opt/autoware/setup.sh && \
    colcon build \
      --base-paths \
        /tmp/autoware/src/launcher/autoware_launch/tier4_universe_launch/tier4_control_launch \
        /tmp/autoware/src/launcher/autoware_launch/tier4_universe_launch/tier4_planning_launch \
        /tmp/autoware/src/universe/autoware_universe/control \
        /tmp/autoware/src/universe/autoware_universe/planning \
        /tmp/autoware/src/universe/autoware_universe/sensing/autoware_pcl_extensions \
        /tmp/autoware/src/universe/autoware_universe/sensing/autoware_pointcloud_preprocessor \
        /tmp/autoware/src/universe/autoware_universe/sensing/autoware_cuda_utils \
        /tmp/autoware/src/universe/autoware_universe/perception/autoware_tensorrt_common \
        /tmp/autoware/src/universe/autoware_universe/perception/autoware_tensorrt_plugins \
        /tmp/autoware/src/universe/autoware_universe/vehicle/autoware_external_cmd_converter \
        /tmp/autoware/src/universe/autoware_universe/vehicle/autoware_raw_vehicle_cmd_converter \
        /tmp/autoware/src/universe/autoware_universe/system/autoware_command_mode_types \
      --install-base /opt/autoware \
      --cmake-args -DCMAKE_BUILD_TYPE=Release && \
    rm -rf build log

RUN --mount=type=cache,id=apt-cache-${ROS_DISTRO},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lists-${ROS_DISTRO},target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    . "/opt/ros/${ROS_DISTRO}/setup.sh" && \
    rosdep install -y --from-paths /tmp/autoware/src \
      --ignore-src --rosdistro "${ROS_DISTRO}" \
      --dependency-types=exec && \
    rm -rf /tmp/autoware

# =============================================================================
# Runtime stage: planning-control
# =============================================================================
FROM ${UNIVERSE_COMMON_IMAGE} AS planning-control
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG ROS_DISTRO

USER root
COPY --from=planning-control-devel /opt/autoware /opt/autoware
RUN find /opt/autoware -name '*.so' -exec strip --strip-unneeded {} +

COPY --parents --chown=${USERNAME}:${USERNAME} \
    autoware/src/launcher/autoware_launch/tier4_universe_launch/tier4_control_launch/**/package.xml \
    autoware/src/launcher/autoware_launch/tier4_universe_launch/tier4_planning_launch/**/package.xml \
    autoware/src/universe/autoware_universe/control/**/package.xml \
    autoware/src/universe/autoware_universe/planning/**/package.xml \
    autoware/src/universe/autoware_universe/sensing/autoware_pcl_extensions/**/package.xml \
    autoware/src/universe/autoware_universe/sensing/autoware_pointcloud_preprocessor/**/package.xml \
    autoware/src/universe/autoware_universe/sensing/autoware_cuda_utils/**/package.xml \
    autoware/src/universe/autoware_universe/perception/autoware_tensorrt_common/**/package.xml \
    autoware/src/universe/autoware_universe/perception/autoware_tensorrt_plugins/**/package.xml \
    autoware/src/universe/autoware_universe/vehicle/autoware_external_cmd_converter/**/package.xml \
    autoware/src/universe/autoware_universe/vehicle/autoware_raw_vehicle_cmd_converter/**/package.xml \
    autoware/src/universe/autoware_universe/system/autoware_command_mode_types/**/package.xml \
    /tmp/

RUN --mount=type=cache,id=apt-cache-${ROS_DISTRO},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lists-${ROS_DISTRO},target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    . "/opt/ros/${ROS_DISTRO}/setup.sh" && \
    rosdep install -y --from-paths /tmp \
      --dependency-types=exec --ignore-src --rosdistro "${ROS_DISTRO}" && \
    rm -rf /tmp/*
