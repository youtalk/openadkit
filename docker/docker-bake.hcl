// Docker Bake configuration for Open AD Kit images.
//
// Local builds: leave REGISTRY/USE_REGISTRY_CONTEXTS unset — every target
// resolves cross-references via `target:` within one build graph.
//
// CI: each bake-group builds in its own job; USE_REGISTRY_CONTEXTS=true makes
// cross-group references resolve to already-pushed `docker-image://` tags.

variable "ROS_DISTRO" {
  default = "jazzy"
}

// CI variables: set via environment in GitHub Actions, empty for local builds.
variable "REGISTRY" {
  default = ""
}
variable "PLATFORM" {
  default = ""
}
variable "TAG_DATE" {
  default = ""
}
variable "TAG_VERSION" {
  default = ""
}
variable "TAG_REF" {
  default = ""
}

// Pin for upstream Autoware images. A concrete release tag (e.g. "1.2.3") is
// the production default, set via a repo Variable in CI. Empty string yields
// the upstream "plain" <name>-<distro> multi-arch manifest — handy for local
// experiments, but NOT what CI should run with.
variable "UPSTREAM_TAG" {
  default = ""
}
variable "UPSTREAM_REPO" {
  default = "ghcr.io/autowarefoundation/autoware"
}

// CI sets this true to pull cross-group dependencies as already-pushed GHCR
// images; local builds leave it false and let bake stitch within one graph.
variable "USE_REGISTRY_CONTEXTS" {
  default = false
}

// IMPORTANT: the first element must always be the plain name-distro-platform
// tag, because ctx() uses tags(name)[0] to construct docker-image:// refs.
function "tags" {
  params = [name]
  result = compact(concat(
    REGISTRY == "" ? ["openadkit:${name}-${ROS_DISTRO}"] : [],
    REGISTRY != "" && TAG_REF == "" ? ["${REGISTRY}:${name}-${ROS_DISTRO}-${PLATFORM}"] : [],
    REGISTRY != "" && TAG_DATE != "" && TAG_REF == "" ? ["${REGISTRY}:${name}-${ROS_DISTRO}-${TAG_DATE}-${PLATFORM}"] : [],
    REGISTRY != "" && TAG_VERSION != "" ? ["${REGISTRY}:${name}-${ROS_DISTRO}-${TAG_VERSION}-${PLATFORM}"] : [],
    REGISTRY != "" && TAG_REF != "" ? ["${REGISTRY}:${name}-${ROS_DISTRO}-${TAG_REF}-${PLATFORM}"] : [],
  ))
}

// Returns "docker-image://..." when USE_REGISTRY_CONTEXTS is true (CI),
// or "target:..." when false (local builds).
function "ctx" {
  params = [name]
  result = USE_REGISTRY_CONTEXTS ? "docker-image://${tags(name)[0]}" : "target:${name}"
}

// Resolves an upstream Autoware image reference. UPSTREAM_TAG="" yields the
// plain <name>-<distro> multi-arch tag; non-empty yields <name>-<distro>-<tag>.
function "upstream" {
  params = [name]
  result = "docker-image://${UPSTREAM_REPO}:${name}-${ROS_DISTRO}${UPSTREAM_TAG == "" ? "" : "-${UPSTREAM_TAG}"}"
}

group "default" {
  targets = ["universe-common", "components", "components-cuda", "universe", "universe-cuda"]
}

group "universe-common" {
  targets = ["universe-common-devel", "universe-common"]
}

group "components" {
  targets = [
    "sensing-perception", "localization-mapping", "planning-control",
    "vehicle-system", "api", "visualizer", "simulator",
  ]
}

group "components-cuda" {
  targets = ["sensing-perception-cuda"]
}

// CI-facing groups: one per docker-build.yaml invocation.
group "ci-universe-common" {
  targets = ["universe-common-devel", "universe-common"]
}

group "ci-components" {
  targets = [
    "sensing-perception", "localization-mapping", "planning-control",
    "vehicle-system", "api", "visualizer", "simulator",
  ]
}

group "ci-components-cuda" {
  targets = ["sensing-perception-cuda"]
}

group "ci-universe" {
  targets = ["universe"]
}

group "ci-universe-cuda" {
  targets = ["universe-cuda"]
}

// Common base for both universe-common stages. The Dockerfile has FROM lines
// for both ${CORE_DEVEL_IMAGE} (devel stage) and ${CORE_IMAGE} (runtime
// stage), so BuildKit needs both ARGs and both contexts resolved at parse
// time regardless of which target stage is being built — mirrors upstream's
// `_universe-base` / `_universe-cuda-base` inheritable pattern.
target "_universe-common-base" {
  dockerfile = "components/universe-common/Dockerfile"
  contexts = {
    autoware-core-devel = upstream("core-devel")
    autoware-core       = upstream("core")
  }
  args = {
    CORE_DEVEL_IMAGE = "autoware-core-devel"
    CORE_IMAGE       = "autoware-core"
    ROS_DISTRO       = ROS_DISTRO
  }
}

target "universe-common-devel" {
  inherits = ["_universe-common-base"]
  target   = "universe-common-devel"
  tags     = tags("universe-common-devel")
}

target "universe-common" {
  inherits = ["_universe-common-base"]
  target   = "universe-common"
  tags     = tags("universe-common")
  contexts = {
    universe-common-devel = ctx("universe-common-devel")
  }
}

target "_component-base" {
  contexts = {
    universe-common-devel = ctx("universe-common-devel")
    universe-common       = ctx("universe-common")
  }
  args = {
    UNIVERSE_COMMON_DEVEL_IMAGE = "universe-common-devel"
    UNIVERSE_COMMON_IMAGE       = "universe-common"
    ROS_DISTRO                  = ROS_DISTRO
  }
}

target "sensing-perception" {
  inherits   = ["_component-base"]
  dockerfile = "components/sensing-perception/Dockerfile"
  target     = "sensing-perception"
  tags       = tags("sensing-perception")
}

target "localization-mapping" {
  inherits   = ["_component-base"]
  dockerfile = "components/localization-mapping/Dockerfile"
  target     = "localization-mapping"
  tags       = tags("localization-mapping")
}

target "planning-control" {
  inherits   = ["_component-base"]
  dockerfile = "components/planning-control/Dockerfile"
  target     = "planning-control"
  tags       = tags("planning-control")
}

target "vehicle-system" {
  inherits   = ["_component-base"]
  dockerfile = "components/vehicle-system/Dockerfile"
  target     = "vehicle-system"
  tags       = tags("vehicle-system")
}

target "api" {
  inherits   = ["_component-base"]
  dockerfile = "components/api/Dockerfile"
  target     = "api"
  tags       = tags("api")
}

target "visualizer" {
  inherits   = ["_component-base"]
  dockerfile = "components/visualizer/Dockerfile"
  target     = "visualizer"
  tags       = tags("visualizer")
}

target "simulator" {
  inherits   = ["_component-base"]
  dockerfile = "components/simulator/Dockerfile"
  target     = "simulator"
  tags       = tags("simulator")
}

target "sensing-perception-cuda" {
  dockerfile = "components/sensing-perception/Dockerfile.cuda"
  target     = "sensing-perception-cuda"
  tags       = tags("sensing-perception-cuda")
  contexts = {
    universe-common-devel      = ctx("universe-common-devel")
    universe-common            = ctx("universe-common")
    autoware-base-cuda-runtime = upstream("base-cuda-runtime")
    autoware-base-cuda-devel   = upstream("base-cuda-devel")
  }
  args = {
    UNIVERSE_COMMON_DEVEL_IMAGE = "universe-common-devel"
    UNIVERSE_COMMON_IMAGE       = "universe-common"
    BASE_CUDA_RUNTIME_IMAGE     = "autoware-base-cuda-runtime"
    BASE_CUDA_DEVEL_IMAGE       = "autoware-base-cuda-devel"
    ROS_DISTRO                  = ROS_DISTRO
  }
}

target "universe" {
  dockerfile = "components/universe/Dockerfile"
  target     = "universe"
  tags       = tags("universe")
  contexts = {
    autoware-core        = upstream("core")
    sensing-perception   = ctx("sensing-perception")
    localization-mapping = ctx("localization-mapping")
    planning-control     = ctx("planning-control")
    vehicle-system       = ctx("vehicle-system")
    api                  = ctx("api")
    visualizer           = ctx("visualizer")
    simulator            = ctx("simulator")
  }
  args = {
    ROS_DISTRO = ROS_DISTRO
  }
}

target "universe-cuda" {
  dockerfile = "components/universe/Dockerfile.cuda"
  target     = "universe-cuda"
  tags       = tags("universe-cuda")
  contexts = {
    autoware-base-cuda-runtime = upstream("base-cuda-runtime")
    autoware-core              = upstream("core")
    sensing-perception-cuda    = ctx("sensing-perception-cuda")
    localization-mapping       = ctx("localization-mapping")
    planning-control           = ctx("planning-control")
    vehicle-system             = ctx("vehicle-system")
    api                        = ctx("api")
    visualizer                 = ctx("visualizer")
    simulator                  = ctx("simulator")
  }
  args = {
    ROS_DISTRO = ROS_DISTRO
  }
}
