# docker/planning-control/Dockerfile
# Passthrough component: planning-control ships only what is already in
# upstream universe. Will become a two-stage build once openadkit-only
# sources are added to extras/planning-control/src/.

# hadolint ignore=DL3006
ARG UPSTREAM_DEVEL
ARG UPSTREAM_RUN
ARG ROS_DISTRO=jazzy

FROM ${UPSTREAM_RUN} AS planning-control
