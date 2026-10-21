# Testbed

A single-node Kubernetes cluster that's driven from inside the devcontainer, plus a local
registry and 2 ways to build images, all without giving the devcontainer privileges or devices.

- this page: how the pieces fit together, and where their state lives
- [constraints.md](./constraints.md): what the devcontainer can't do, and how each part works
  around it
- [decisions.md](./decisions.md): the choices made, the alternatives that were rejected, and the
  measurements behind sizing and timeouts
- [gotchas.md](./gotchas.md): surprises that don't belong to a single file

The why of a single detail is in a comment next to it, in the scripts, recipes, config and
cloud-init templates. These pages cover what spans files.

Paths are relative to `testbed/`, except `.devcontainer/` and `.local/` in the repo root. Run
recipes with `just` in `testbed/`, or as `just testbed::<recipe>` from the root, which can't set
variables like `vm=build`.

## Pieces

```
devcontainer                                   cluster VM (KVM or TCG), Debian 13
┌───────────────────────────────┐              ┌───────────────────────────┐
│ podman build/push             │              │ k3s / containerd          │
│   → registry 127.0.0.1:5000 ◄─┼── slirp ─────┼── pull 10.0.2.2:5000      │
│ kubectl → 127.0.0.1:6443 ─────┼── hostfwd ──►│   apiserver :6443         │
│ ssh     → 127.0.0.1:2222 ─────┼── hostfwd ──►│   sshd :22                │
│ curl    → 127.0.0.1:8080 ─────┼── hostfwd ──►│   traefik :80             │
│                               │              └───────────────────────────┘
│                               │              build VM (KVM or TCG), on demand
│                               │              ┌───────────────────────────┐
│ docker  → 127.0.0.1:2375 ─────┼── hostfwd ──►│   dockerd :2375           │
│ ssh     → 127.0.0.1:2223 ─────┼── hostfwd ──►│   sshd :22                │
│   registry 127.0.0.1:5000 ◄───┼── slirp ─────┼── push 10.0.2.2:5000      │
└───────────────────────────────┘              └───────────────────────────┘
```

- **Cluster VM.** QEMU runs a Debian 13 cloud image, as an unprivileged process in the
  devcontainer. KVM is used when the host passes a usable `/dev/kvm`, else TCG, QEMU's
  software emulation. cloud-init installs k3s airgapped, from files on the seed ISO, with its
  bundled traefik ingress and metrics-server.
- **Networking.** QEMU's user-mode network (slirp) needs no tun device. Its `hostfwd` rules
  bind the guest's ssh, API server and traefik to the devcontainer's loopback. In the other
  direction, the guest reaches the devcontainer's loopback as `10.0.2.2`.
- **Registry.** Debian's `docker-registry` runs as a plain process in the devcontainer, on
  `127.0.0.1:5000`, over HTTP. k3s's `registries.yaml` mirrors `localhost:5000` to
  `http://10.0.2.2:5000`, so manifests use `image: localhost:5000/<name>`, whichever builder
  pushed it.
- **Ingress.** Traefik's port 80 is forwarded to `127.0.0.1:8080`. Ingress hosts use
  `<name>.localhost`, which curl and browsers resolve to loopback:
  `curl http://hello.localhost:8080/`.
- **Podman**, the default builder, runs rootless in the devcontainer, for builds and quick local
  runs, and pushes to `localhost:5000` directly.
- **Build VM**, the second builder, for builds rootless Podman can't handle, or when the
  devcontainer setup breaks. A separate QEMU VM with Docker and BuildKit, started on demand.
  The devcontainer's `docker` CLI reaches its daemon through a forward on `127.0.0.1:2375`.
  Pushes run in the VM, so they're tagged `10.0.2.2:5000/<name>`: the same registry and
  repository as `localhost:5000/<name>`.
- **Setup.** `just setup` makes the devcontainer changes that need root, like the ID mapping
  Podman needs, and writes the user-level Podman config. `postCreateCommand` runs it, as
  root-level changes are lost on a rebuild; it's safe to rerun, and repairs what a package
  upgrade reset.
- **KVM.** On the host, before the devcontainer is created, `.devcontainer/kvm-link.sh` points
  `.local/testbed/host/kvm` at `/dev/kvm` if a probe container can open it, else at
  `/dev/null`; `runArgs` passes that link as `/dev/kvm`. `env/vm.sh` picks KVM only for the real
  device.

Both builders take the same `build` and `push` arguments, so recipes pick the command from the
`builder` variable. The `vm-*` recipes act on the cluster VM, or on the build VM with
`vm=build`; per-VM settings, like ports, sizing, readiness phases and timeouts, are in
[vm.sh](../../env/vm.sh).

### Lifecycle of a VM

1. `vm-image` fetches the pinned downloads into the cache, verifying their checksums, then
   creates a qcow2 overlay backed by the cached cloud image, and a NoCloud `seed.iso`: the
   rendered `user-data`, `meta-data`, and for the cluster VM the k3s files. It records what
   the VM was created from in `settings`. If a pin or bootstrap setting changed since, it
   lists the difference and asks for `vm-reset`, rather than silently changing a VM.
2. `vm-up` starts QEMU daemonized, then waits through the VM's readiness phases, printing a
   status line about every 20 s. The cluster VM's phases are `boot` (ssh answers),
   `cloud-init` (done, or its errors are reported), `node` (`Ready`), `addons` (the bundled
   deployments are ready) and `ingress` (traefik answers through the forward); the build VM's
   end with `docker` (the daemon answers through the forward). Then it copies the kubeconfig
   out.
3. `vm-down` presses the ACPI power button through QEMU's QMP socket and waits for QEMU to
   exit.
4. `vm-reset` stops the VM and deletes its dir: disk, seed, host keys and kubeconfig. The
   cache, the ssh key and the registry and Podman storage stay, so the next `vm-up` gives a
   fresh VM without downloads.

Every recipe is safe to repeat. A pid file is only trusted if its process has the expected
executable and a marker in its command line, like the disk or config path, so a stale file
can't get an unrelated process stopped.

## State

Everything at runtime lives under `.local/testbed/` in the repo root, which is gitignored and
sits in the workspace bind mount, so it survives a devcontainer rebuild.

| Path | Holds |
|---|---|
| `.local/testbed/cache/` | pinned downloads, with the version in the file name |
| `.local/testbed/vm/id_ed25519` | the ssh key, shared by both VMs |
| `.local/testbed/vm/<vm>/` | overlay disk, seed, `settings`, `known_hosts`, pid file, QMP, logs |
| `.local/testbed/vm/cluster/kubeconfig` | admin credentials for the cluster, mode `0600` |
| `.local/testbed/registry/` | registry storage, pid file and log |
| `.local/testbed/podman/` | Podman's image and build storage |
| `.local/testbed/krew/` | `KREW_ROOT`: krew and its plugins |
| `.local/testbed/host/kvm` | the link `kvm-link.sh` writes on the host |
| `.local/testbed/hello/` | the kustomize overlay of the last `test-hello-up` |

Outside the workspace, `setup` writes `/etc/subuid`, `/etc/subgid`, `/usr/local/bin/kubectl`
and the Podman config in `~/.config/containers/`, and Podman's runroot goes to `/tmp`. All of
it is recreated on a rebuild.
