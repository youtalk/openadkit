# docker/visualizer/Dockerfile
# Passthrough component: visualizer ships only what is already in upstream
# universe. The VNC/NoVNC desktop layer from components/visualizer/ is
# folded back in as part of Task 7 (add-on layer) in a later PR.

# hadolint ignore=DL3006
ARG UPSTREAM_DEVEL
ARG UPSTREAM_RUN
ARG ROS_DISTRO=jazzy

FROM ${UPSTREAM_RUN} AS visualizer
