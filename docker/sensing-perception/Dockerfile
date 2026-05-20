# docker/sensing-perception/Dockerfile
# Passthrough component: sensing-perception ships only what is already in
# upstream universe. Will become a two-stage build once openadkit-only
# sources are added to extras/sensing-perception/src/.

# hadolint ignore=DL3006
ARG UPSTREAM_DEVEL
ARG UPSTREAM_RUN
ARG ROS_DISTRO=jazzy

FROM ${UPSTREAM_RUN} AS sensing-perception
