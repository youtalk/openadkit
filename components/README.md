# Open AD Kit Components

[Open AD Kit](https://autoware.org/open-ad-kit/) offers containers for
Autoware Components to simplify the deployment of Autoware and its
dependencies. This directory holds the per-component Dockerfiles.

Detailed instructions on how to deploy the components can be found in the
[Open AD Kit Deployments](https://autowarefoundation.github.io/openadkit/deployments/).

## Build Pipeline

```mermaid
block-beta
    columns 8

    space:3 UP["autoware:core-devel / core<br/>autoware:base-cuda-{devel,runtime}"]:2 space:3

    space:8

    space:3 UC["universe-common"]:2 space:3

    space:8

    SP["sensing-perception"] SPC["sensing-perception-cuda"] LM["localization-mapping"] PC["planning-control"] VS["vehicle-system"] API["api"] VIZ["visualizer"] SIM["simulator"]

    space:8

    space:3 UNI["universe / universe-cuda"]:2 space:3

    UP --> UC
    UC --> SP
    UC --> LM
    UC --> PC
    UC --> VS
    UC --> API
    UC --> VIZ
    UC --> SIM
    UP --> SPC
    SP --> UNI
    SPC --> UNI
    LM --> UNI
    PC --> UNI
    VS --> UNI
    API --> UNI
    VIZ --> UNI
    SIM --> UNI

    style UP fill:#334155,stroke:#64748b,color:#e2e8f0
    style UC fill:#1e3a5f,stroke:#3b82f6,color:#bfdbfe
    style SP fill:#14532d,stroke:#22c55e,color:#bbf7d0
    style SPC fill:#14532d,stroke:#22c55e,color:#bbf7d0
    style LM fill:#14532d,stroke:#22c55e,color:#bbf7d0
    style PC fill:#14532d,stroke:#22c55e,color:#bbf7d0
    style VS fill:#14532d,stroke:#22c55e,color:#bbf7d0
    style API fill:#14532d,stroke:#22c55e,color:#bbf7d0
    style VIZ fill:#14532d,stroke:#22c55e,color:#bbf7d0
    style SIM fill:#14532d,stroke:#22c55e,color:#bbf7d0
    style UNI fill:#4c1d95,stroke:#a855f7,color:#e9d5ff
```

Images are built with `docker buildx bake` from
[`docker/docker-bake.hcl`](../docker/docker-bake.hcl). The `universe-common`
layer is an openadkit-owned thin intermediate that compiles the
universe-common slice of Autoware on top of upstream `core-devel`/`core`.

### Bake groups

| Group | Description | Targets |
|-------|-------------|---------|
| `universe-common` | Thin intermediate layer | `universe-common-devel`, `universe-common` |
| `components` | Non-CUDA component images | `sensing-perception`, `localization-mapping`, `planning-control`, `vehicle-system`, `api`, `visualizer`, `simulator` |
| `components-cuda` | CUDA component images | `sensing-perception-cuda` |
| `universe` / `universe-cuda` | Aggregated images | `universe`, `universe-cuda` |

See the [components documentation](https://autowarefoundation.github.io/openadkit/components/)
for build commands and the CI pipeline.
