# Components

Open AD Kit is a component based project, which means that it is designed to be deployed on a variety of platforms with microservices architecture. Each **Autoware component** is designed to be independent and can be configured to work together to achieve a particular task, such as a simulation or a full autonomous driving stack.

![Granular Components](../assets/images/granular-components.png)

## Autoware Components

### Sensing

The sensing component is responsible for collecting data from the vehicle's sensors. Sensing component can be configured to collect data from a variety of sensors, including **cameras, lidars, and radars**. For more details on the [Autoware sensing design document](https://autowarefoundation.github.io/autoware-documentation/main/design/autoware-architecture-v1/components/sensing/).

### Perception

The perception component is responsible for processing the data from the vehicle's sensors and creating a map of the environment. Perception component can be configured to use a variety of perception algorithms, including **object detection, tracking, and mapping**. For more details, see the [Autoware perception design document](https://autowarefoundation.github.io/autoware-documentation/main/design/autoware-architecture-v1/components/perception/).

### Mapping

The mapping component is responsible for creating a map of the environment. Mapping component can be configured to use a variety of mapping algorithms, including **occupancy grid mapping and point cloud mapping**. For more details, see the [Autoware mapping design document](https://autowarefoundation.github.io/autoware-documentation/main/design/autoware-architecture-v1/components/map/).

### Localization

The localization component is responsible for determining the vehicle's position in the map. Localization component can be configured to use a variety of localization algorithms, including **GPS, IMU, and visual odometry**. For more details, see the [Autoware localization design document](https://autowarefoundation.github.io/autoware-documentation/main/design/autoware-architecture-v1/components/localization/).

### Planning

The planning component is responsible for planning the vehicle's path. Planning component can be configured to use a variety of planning algorithms, including **Route Planning, Goal Planning, and Behavior Planning**. For more details, see the [Autoware planning design document](https://autowarefoundation.github.io/autoware-documentation/main/design/autoware-architecture-v1/components/planning/).

### Control

The control component is responsible for controlling the vehicle's actuators. Control component can be configured to use a variety of control algorithms, including **PID and MPC**. For more details, see the [Autoware control design document](https://autowarefoundation.github.io/autoware-documentation/main/design/autoware-architecture-v1/components/control/).

### Vehicle

The vehicle component is responsible for managing the vehicle's state. Vehicle component can be configured to use a variety of vehicle algorithms, including **vehicle state estimation and vehicle control**. For more details, see the [Autoware vehicle design document](https://autowarefoundation.github.io/autoware-documentation/main/design/autoware-architecture-v1/components/vehicle/).

### API

The API component is responsible for providing [AD API](https://autowarefoundation.github.io/autoware-documentation/main/design/autoware-interfaces/ad-api/) interface for the vehicle's state. API component can be configured to enable/disable various interfaces. For more details, see the [Autoware Interface design document](https://autowarefoundation.github.io/autoware-documentation/main/design/autoware-architecture-v1/interfaces/).

### System

The system component is responsible for managing the vehicle's system. System component can be configured to use a variety of system algorithms, including **system health monitoring and system error handling**.

## Building from source

Open AD Kit images are built with `docker buildx bake` using
[`docker/docker-bake.hcl`](https://github.com/autowarefoundation/openadkit/blob/main/docker/docker-bake.hcl).
The build graph is:

```
upstream autoware:core-devel / core / base-cuda-{devel,runtime}
        │
        ▼
universe-common  (openadkit-owned thin intermediate)
        │
        ▼
seven component images (sensing-perception, localization-mapping,
planning-control, vehicle-system, api, visualizer, simulator) + sensing-perception-cuda
        │
        ▼
universe / universe-cuda
```

The `universe-common` layer compiles only the universe-common slice of
Autoware on top of upstream `core-devel`/`core`; everything below
`universe-common` (base OS, ROS, core) is owned and built by upstream.

### Bake groups

| Group | Targets |
|-------|---------|
| `universe-common` | `universe-common-devel`, `universe-common` |
| `components` | the seven non-CUDA component images |
| `components-cuda` | `sensing-perception-cuda` |
| `universe` / `universe-cuda` | the aggregated images |

### Upstream pin

The `UPSTREAM_TAG` bake variable pins the upstream Autoware release the
images are built against. CI sets it from a repository Variable; leaving it
empty uses upstream's plain `<name>-<distro>` multi-arch tag.

## CI pipeline

`docker-build-and-push.yaml` is the entrypoint. On pushes to `main` (and on
release tags) it runs a changed-files gate, then fans out into a
per-`(distro, arch)` five-stage pipeline (`docker-build-pipeline.yaml`),
where each stage builds one bake-group via `docker-build.yaml`. After both
architectures finish, `docker-manifest.yaml` stitches the per-arch tags into
multi-arch manifests.

The Jazzy manifest job additionally publishes no-distro-suffix alias tags
(`openadkit:<name>`), so existing `ghcr.io/autowarefoundation/openadkit:<name>`
references resolve to the Jazzy multi-arch image. Humble consumers must use
the explicit `-humble` suffix.
