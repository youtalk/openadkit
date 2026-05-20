# docker/universe/Dockerfile
# Passthrough aggregator: openadkit:universe-<distro> re-tags the upstream
# universe-<distro> runtime image. The container-build-revamp inventory
# (2026-05-20) confirmed zero openadkit-only sources across all components,
# so upstream universe already IS the aggregator. This Dockerfile exists so
# universe has the same CI shape as every other openadkit component
# (bake target, hadolint pass, image build).

# hadolint ignore=DL3006
ARG UPSTREAM_DEVEL
ARG UPSTREAM_RUN
ARG ROS_DISTRO=jazzy

FROM ${UPSTREAM_RUN} AS universe
