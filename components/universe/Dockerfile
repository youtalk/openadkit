# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom,UndefinedVar

# =============================================================================
# Runtime stage: universe
# Aggregates the seven component install trees onto upstream core.
# =============================================================================
FROM autoware-core AS universe
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG ROS_DISTRO

USER root
COPY --from=sensing-perception   /opt/autoware /opt/autoware
COPY --from=localization-mapping /opt/autoware /opt/autoware
COPY --from=planning-control     /opt/autoware /opt/autoware
COPY --from=vehicle-system       /opt/autoware /opt/autoware
COPY --from=api                  /opt/autoware /opt/autoware
COPY --from=visualizer           /opt/autoware /opt/autoware
COPY --from=simulator            /opt/autoware /opt/autoware
RUN find /opt/autoware -name '*.so' -exec strip --strip-unneeded {} +

USER ${USERNAME}
