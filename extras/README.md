# extras/

Openadkit-only ROS sources that augment upstream `universe-<distro>` images.

Each subdirectory corresponds to one container component. Sources are placed
under `extras/<component>/src/` and built into `/opt/autoware` inside the
component image's build stage.

`repos.yaml` lists external repositories to fetch via `vcs import` when you
want to develop the extras locally:

    vcs import extras < extras/repos.yaml

For a clean container build, sources baked into this repo under
`extras/<component>/src/` are used as-is; `repos.yaml` is for developer
convenience only.
