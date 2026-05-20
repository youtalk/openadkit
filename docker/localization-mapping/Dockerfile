# docker/localization-mapping/Dockerfile
# Passthrough component: localization-mapping ships only what is already
# in upstream universe. Will become a two-stage build once openadkit-only
# sources are added to extras/localization-mapping/src/.

# hadolint ignore=DL3006
ARG UPSTREAM_DEVEL
ARG UPSTREAM_RUN
ARG ROS_DISTRO=jazzy

FROM ${UPSTREAM_RUN} AS localization-mapping
