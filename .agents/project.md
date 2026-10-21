# Project structure & building instructions

## Layout

The repo is a devcontainer with self-contained components next to each other. Each component
has its own folder with a `justfile` and its own docs; new code goes in a new folder beside
them, rather than into an existing one.

```
.devcontainer/    the devcontainer: package installs, KVM pass-through, environment
justfile          mounts each component as a just module, plus repo-wide recipes
testbed/          single-node Kubernetes testbed, see its docs/udd/
.agents/          agent instructions and skills, see the index below
.local/           runtime state and caches, a dir per component; gitignored, survives a rebuild
PLAN.<ticket>/    the plan for the ticket in the branch name, if any
```

The agent index is [README.md](./README.md).

Components:

- [testbed/](../testbed/): k3s in a QEMU VM, a local registry and 2 image builders, all
  without giving the devcontainer privileges; read
  [docs/udd/](../testbed/docs/udd/README.md) before changing it

## Recipes

`just` lists the recipes where it runs: in the root, the repo-wide ones and the modules; in a
component's folder, that component's. From the root, a module's recipes run as
`just <module>::<recipe>`, but its variables can only be set in its folder, e.g.
`cd testbed && just vm=build vm-up`.

## Conventions

- devcontainer changes must apply to the running container too: install packages by hand with
  the Dockerfile's `apt-get install` line, and put setup logic in an idempotent `setup` recipe,
  which the root's `setup` calls, never only in the Dockerfile
- giving the devcontainer privileges or devices is off limits, except for `/dev/kvm` when the
  host already grants it
- a component keeps its state in `.local/<component>/`
- the why of a detail goes in a comment next to it; what spans files goes in the component's
  `docs/udd/`
