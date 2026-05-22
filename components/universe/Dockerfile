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
# sensing-perception is copied LAST so its packages win on any overlap with
# other components (matches the pre-rewrite Dockerfile.cuda invariant; for the
# non-CUDA case this is hygienic only — overlapping packages are functionally
# identical, but determinism beats luck).
COPY --from=localization-mapping /opt/autoware /opt/autoware
COPY --from=planning-control     /opt/autoware /opt/autoware
COPY --from=vehicle-system       /opt/autoware /opt/autoware
COPY --from=api                  /opt/autoware /opt/autoware
COPY --from=visualizer           /opt/autoware /opt/autoware
COPY --from=simulator            /opt/autoware /opt/autoware
COPY --from=sensing-perception   /opt/autoware /opt/autoware
RUN find /opt/autoware -name '*.so' -exec strip --strip-unneeded {} +

USER ${USERNAME}
