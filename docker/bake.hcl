// docker/bake.hcl - openadkit container build graph
// Mirrors the ctx()/tags() helper pattern from upstream autoware/docker/docker-bake.hcl.

variable "ROS_DISTRO"        { default = "jazzy" }
variable "UPSTREAM_REPO"     { default = "ghcr.io/autowarefoundation/autoware" }
// UPSTREAM_VERSION pins all upstream parent images to a single version
// suffix (e.g. "1.8.0" or "20260520"). Each stage still resolves to its own
// per-stage tag — `devel`/`runtime`/CUDA siblings stay distinct. Empty means
// rolling `universe[-cuda][-devel]-<distro>`.
variable "UPSTREAM_VERSION"  { default = "" }
variable "REGISTRY"          { default = "" }
variable "PLATFORM"          { default = "" }
variable "TAG_DATE"          { default = "" }
variable "TAG_VERSION"       { default = "" }
variable "USE_REGISTRY_CONTEXTS" { default = false }

// Resolve the upstream parent image tag for a given stage suffix.
// stage = "devel" | "devel-cuda" | "runtime" | "runtime-cuda"
function "upstream" {
  params = [stage]
  result = (
    stage == "devel"        ? "${UPSTREAM_REPO}:universe-devel-${ROS_DISTRO}${UPSTREAM_VERSION != "" ? "-${UPSTREAM_VERSION}" : ""}"      :
    stage == "devel-cuda"   ? "${UPSTREAM_REPO}:universe-devel-cuda-${ROS_DISTRO}${UPSTREAM_VERSION != "" ? "-${UPSTREAM_VERSION}" : ""}" :
    stage == "runtime"      ? "${UPSTREAM_REPO}:universe-${ROS_DISTRO}${UPSTREAM_VERSION != "" ? "-${UPSTREAM_VERSION}" : ""}"            :
    stage == "runtime-cuda" ? "${UPSTREAM_REPO}:universe-cuda-${ROS_DISTRO}${UPSTREAM_VERSION != "" ? "-${UPSTREAM_VERSION}" : ""}"       :
    "INVALID-STAGE"
  )
}

function "tags" {
  params = [name]
  result = compact(concat(
    REGISTRY == "" ? ["openadkit:${name}-${ROS_DISTRO}"] : [],
    REGISTRY != "" ? ["${REGISTRY}:${name}-${ROS_DISTRO}-${PLATFORM}"] : [],
    REGISTRY != "" && TAG_DATE    != "" ? ["${REGISTRY}:${name}-${ROS_DISTRO}-${TAG_DATE}-${PLATFORM}"] : [],
    REGISTRY != "" && TAG_VERSION != "" ? ["${REGISTRY}:${name}-${ROS_DISTRO}-${TAG_VERSION}-${PLATFORM}"] : [],
  ))
}

// "target:" locally, "docker-image://" in CI (each group built in separate job).
function "ctx" {
  params = [name]
  result = USE_REGISTRY_CONTEXTS ? "docker-image://${tags(name)[0]}" : "target:${name}"
}

// Forward-looking group definitions. The named targets land alongside
// their Dockerfiles in follow-up commits; bake will report "failed to find
// target ..." until then.
group "default" {
  targets = [
    "sensing-perception",
    "localization-mapping",
    "planning-control",
    "vehicle-system",
    "api",
    "visualizer",
    "simulator",
    "universe",
  ]
}

group "default-cuda" {
  targets = [
    "sensing-perception-cuda",
    "universe-cuda",
  ]
}

// One target per component — non-CUDA path. Each is defined further down once
// its Dockerfile exists. We use `inherits` to share common arg blocks.
target "_component-base" {
  args = {
    ROS_DISTRO     = ROS_DISTRO
    UPSTREAM_DEVEL = upstream("devel")
    UPSTREAM_RUN   = upstream("runtime")
  }
}

target "_component-cuda-base" {
  args = {
    ROS_DISTRO     = ROS_DISTRO
    UPSTREAM_DEVEL = upstream("devel-cuda")
    UPSTREAM_RUN   = upstream("runtime-cuda")
  }
}

target "api" {
  inherits   = ["_component-base"]
  context    = "."
  dockerfile = "docker/api/Dockerfile"
  target     = "api"
  tags       = tags("api")
  platforms  = PLATFORM == "" ? [] : [PLATFORM]
}

target "localization-mapping" {
  inherits   = ["_component-base"]
  context    = "."
  dockerfile = "docker/localization-mapping/Dockerfile"
  target     = "localization-mapping"
  tags       = tags("localization-mapping")
  platforms  = PLATFORM == "" ? [] : [PLATFORM]
}

target "planning-control" {
  inherits   = ["_component-base"]
  context    = "."
  dockerfile = "docker/planning-control/Dockerfile"
  target     = "planning-control"
  tags       = tags("planning-control")
  platforms  = PLATFORM == "" ? [] : [PLATFORM]
}

target "sensing-perception" {
  inherits   = ["_component-base"]
  context    = "."
  dockerfile = "docker/sensing-perception/Dockerfile"
  target     = "sensing-perception"
  tags       = tags("sensing-perception")
  platforms  = PLATFORM == "" ? [] : [PLATFORM]
}

target "simulator" {
  inherits   = ["_component-base"]
  context    = "."
  dockerfile = "docker/simulator/Dockerfile"
  target     = "simulator"
  tags       = tags("simulator")
  platforms  = PLATFORM == "" ? [] : [PLATFORM]
}
