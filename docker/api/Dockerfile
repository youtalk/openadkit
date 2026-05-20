# docker/api/Dockerfile
# Passthrough component: api ships only what is already in upstream universe.
# Kept as a real Dockerfile (not a bare bake re-tag) so every openadkit
# component has the same CI shape — bake target, hadolint pass, image build.

# hadolint ignore=DL3006
ARG UPSTREAM_DEVEL
ARG UPSTREAM_RUN
ARG ROS_DISTRO=jazzy

FROM ${UPSTREAM_RUN} AS api
