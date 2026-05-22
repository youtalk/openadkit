# Contributing

Thank you for your interest in contributing to the Open AD Kit!

We welcome contributions from the community, whether they are bug reports, feature requests, documentation improvements, or code changes.

Please refer to the open issues and pull requests on the [Open AD Kit GitHub repository](https://github.com/autowarefoundation/openadkit) to see how you can help.

## Building and verifying changes

Open AD Kit images are built with `docker buildx bake`. To verify a change
to the build pipeline locally, build the affected bake-group, e.g.:

```bash
docker buildx bake -f docker/docker-bake.hcl components
```

To validate only the bake configuration without building images, use
`--print`:

```bash
docker buildx bake -f docker/docker-bake.hcl --print default
```

See the [components documentation](../components/) for the full build graph
and CI pipeline.
