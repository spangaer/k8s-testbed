# Decisions

| Topic | Decision | Why |
|---|---|---|
| Cluster runtime | QEMU, KVM if granted, else TCG | TCG needs no privileges; KVM is far faster |
| Guest OS | Debian 13 cloud image + cloud-init | matches the devcontainer, familiar |
| Kubernetes | k3s, single node | light, and provisions persistent volumes via `local-path` |
| Networking | QEMU user mode (slirp) + `hostfwd` | needs no tun device or capabilities |
| Ingress | k3s's bundled traefik | later work needs one, keeps the cluster realistic |
| Image builds | `podman build` in the devcontainer | native speed, no new rights, Docker's CLI |
| Fallback builds | Docker in a separate build VM, on demand | real root, if Podman falls short |
| Local runs | `podman run`, host network, bound `/proc` | build tools, quick image checks |
| Image transport | `docker-registry` process in devcontainer | native speed, survives VM resets |
| Packages | Debian packages, `--no-install-recommends` | small, and keeps systemd out |
| Downloads | pinned versions, cached in `.local/cache/` | spares public mirrors, fast resets |

## Cluster

- **kind, k3d and docker-in-docker** were rejected, as they need a privileged devcontainer.
  kind and k3d run each node as a privileged container, with containerd and the kubelet
  inside, which fails here in 3 ways, see [constraints.md](./constraints.md):
  - cgroups: the kubelet won't start without a cgroup per pod, and `/sys/fs/cgroup` is
    read-only, so even a Podman container gets none of its own
  - `/proc`: every pod mounts a fresh one, which is denied; Podman's recursive bind is a
    setting of Podman, which containerd in a node doesn't have
  - networking: node containers need their own network, a bridge or rootless `pasta` /
    `slirp4netns`, which need `/dev/net/tun`. With the host network, kube-proxy and the CNI
    would rewrite iptables and routes in the devcontainer's namespace, which needs
    `net_admin`, and pod ports would clash on its loopback

  kind's rootless Podman provider still needs delegated cgroups and `tun`. A VM has a kernel
  of its own, so it avoids all 3.
- **Airgapped k3s install.** The seed ISO carries the k3s binary, its airgap images and the
  pinned `install.sh`, so a reset VM needs no downloads. With them, `seed.iso` is ~270 MB,
  which boots fine; a separate read-only data disk was the fallback, not needed. The guest's
  root fs grows to the overlay's size without extra config.
- **The image's default user, `debian`.** cloud-init gives it the ssh key and passwordless
  `sudo`. A `users:` block would replace it rather than add to it; a custom `k3s` user was
  tried first, and dropped to avoid confusion with the k3s service.
- **Bundled addons kept.** Traefik and metrics-server cost startup time under TCG, but later work
  needs an ingress anyway.
- **kubectl is the upstream binary**, pinned to k3s's Kubernetes version. Debian's package
  (1.32) lags behind k3s.
- **Shutdown via QMP.** `vm-down` presses the ACPI power button through QEMU's control socket,
  which needs neither ssh nor `sudo` in the guest, and works while it's still booting, unlike
  `ssh sudo poweroff`.
- **The accelerator is picked by `vm.sh`**, not by QEMU's own fallback, `-accel kvm -accel tcg`,
  which would only warn in `qemu.log`. `vm_accel=kvm` or `tcg` forces one, e.g. to compare.
- **`vm-ssh` quotes each argument** for the remote shell. Plain ssh joins its arguments, and
  the remote shell splits them again, so an `it's` breaks it. `test-vm-ssh` keeps the checks.

## Builds

Podman builds in the devcontainer are the default, as they're 5 to 30 times faster than the
build VM, with no idle cost, see [measurements](#measurements). The build VM stays as a
second builder, for when Podman falls short. Both push to the same registry, so the cluster
can't tell them apart.

### Podman

- **`podman build`, default `oci` isolation.** crun runs each `RUN` step in its own PID
  namespace, so daemons a step leaves behind are killed when it ends. `--isolation chroot`
  works too, and needs no runtime, but runs steps in the devcontainer's PID namespace, so
  leftovers keep running, reparented to its PID 1. Buildah needn't be installed: `podman build`
  uses it as a library, and its arguments match `docker build`'s.
- **`podman run` with a private PID namespace** and the bound `/proc`, rather than
  `--pid=host`. With `--pid=host`, `podman stop` hangs in `Stopping`: Podman then signals
  every process in the container's cgroup, and there's none. Signalling the main process
  directly ends it, but its children survive. With a private namespace, Podman signals PID 1,
  and when it exits, the kernel kills the rest. The catch is the outer `/proc`, see
  [gotchas.md](./gotchas.md#podman); `--pid=host` per run remains for tools that need it.
- **A `registries.conf.d/` drop-in** marks `localhost:5000` insecure. A user
  `registries.conf` would disable the system's short-name aliases.
- **Storage in the workspace**, so images survive a rebuild.

### Build VM

- **A separate VM, not the cluster VM.** Builds don't compete with k3s, and each VM resets on
  its own, so `vm-reset` keeps the build cache. Building in the cluster VM, with Debian's
  Buildah or BuildKit on k3s's containerd, would also still need a way to get the context in.
- **Docker from Debian**: `docker.io`, `docker-cli` and `docker-buildx`, installed on first
  boot from the mirror. BuildKit is used, with no fallback to the legacy builder, and the build
  context streams from the devcontainer's CLI, with no copying or shared folder.
- **The CLI talks TCP, through a `hostfwd`** to `127.0.0.1:2375`. QEMU owns the forward, so it
  lives and dies with the VM, and there's no ssh process to track. The API is
  unauthenticated, so root in the VM for any process in the devcontainer; acceptable, as it's
  bound to loopback and the devcontainer is a single-user dev environment. Alternatives,
  measured under TCG with a small image:

  | `DOCKER_HOST` | cached build | context change | catch |
  |---|---|---|---|
  | `ssh://` | 12-13 s | 14 s | an ssh handshake per connection; `http2` noise |
  | `ssh://`, `ControlMaster` | 4-5 s | 5 s | same noise |
  | `unix://`, ssh socket forward | 3-4 s | 2 s | an extra process to manage |
  | `tcp://`, QEMU `hostfwd` | 3-4 s | 2 s | unauthenticated |

- **The TCP socket comes from a `docker.socket` drop-in** adding a `ListenStream=`: dockerd
  takes all sockets passed with the unit's `-H fd://`. Rejected: `hosts` in `daemon.json`,
  which conflicts with `-H fd://`; replacing `docker.service`'s `ExecStart`, which goes stale
  with a package change; and `DOCKER_OPTS` in an `Environment=` or extra `EnvironmentFile=`,
  which overrides or is overridden by `/etc/default/docker`, never merged.

## Registry

In the devcontainer rather than in the cluster: native speed, it survives a `vm-reset`, and both
builders reach it. Plain HTTP is acceptable, as it's bound to loopback and local dev only.

## Downloads and pins

All pins are in `versions.just`, with checksums from upstream checksum files. Downloads are
cached with the version in the file name, so a version bump fetches anew, and every use
verifies the checksum. `install.sh` is fetched at the commit of the k3s tag, so it's immutable
too. krew plugins install from their manifests at a pinned krew-index commit, which pin their
archives in turn, so they're "detached": a pin bump updates them, `kubectl krew upgrade` doesn't.

Public images pulled in the guest, like `traefik/whoami`, aren't cached, so they're fetched
again after a `vm-reset`; so is Docker in the build VM.

## Measurements

Unless stated otherwise: 16 host vCPUs, 31 GB host RAM with ~11.7 GB available with nothing
running.

### Cluster VM

| | TCG | KVM |
|---|---|---|
| first boot, k3s installed, ingress serving | 6-7 min | ~1m10s |
| warm start, ingress serving | 2-3 min | 33-40 s |
| `vm-up` when already up | 16 s | |
| shutdown, from a running guest | 9-16 s | |

With 8 vCPUs and 6 GB. A first TCG boot in detail, with 6 vCPUs and 8 GB: ssh after
59 s, cloud-init done after 67 s; then, counted from the start of the k3s install, node `Ready`
after 95 s, traefik and metrics-server running after 262 s. A power button press 6 s into boot
is lost; with the repeats, shutdown then took 43 s.

Idle under TCG, with traefik and metrics-server running: ~1 host core for QEMU, ~560m CPU and
~1.2 GB used in the guest, QEMU RSS ~4.3 GB. The clock stays NTP synced, with no drift seen.

Startup saturates the vCPUs (load ~7.7 with 6), so more vCPUs mostly speed up startup, hence
half the host's. RAM went from 8 to 6 GB, as the guest uses little and host RAM is tight.

### Build VM

With 4 vCPUs and 3 GB.

| | TCG | KVM |
|---|---|---|
| first boot, Docker installed | 2m35s-3m25s | 1m04s-1m17s |
| warm start | 68-82 s | 15-28 s |

The first boot depends on the mirror's speed. Shutdown takes 3-5 s.

Idle: ~3% of one host core, QEMU RSS ~1.2 GB, ~300 MB used in the guest, 1.3 GB of its root fs.
The build cache survives a restart. Both VMs fit side by side in the host's RAM.

### Builders

The test image: `debian:trixie-slim`, an `apt-get install`, a `useradd` and `chown`.

| | Podman, devcontainer | Docker, build VM (TCG) |
|---|---|---|
| cold build, incl. base image pull | 5-11 s | 80 s |
| rebuild, nothing changed | 0 s | 3-4 s |
| rebuild after a context change | 1 s | 2 s |
| push, fresh / updated image | 1 s / 0 s | 29 s / 1 s |
| idle cost | none | the build VM |

`test-hello-up`, a busybox `httpd` image, build to served: 5-15 s with Podman. With Docker,
under KVM, 14 s with the build VM up and 45 s from a stopped one; 33 s under TCG.

### Timeouts

Readiness phases share one time budget, several times the measured boots, by accelerator:

| | TCG first / warm | KVM first / warm |
|---|---|---|
| cluster VM | 15 / 6 min | 5 / 2 min |
| build VM | 10 / 5 min | 5 / 2 min |

Each check costs an ssh connection and often a `k3s kubectl`, ~1 s and ~3 s idle under TCG, far
more while k3s starts, so TCG polls every 5 s and KVM every 2 s.

### Downloads

Cloud image 341 MB, k3s airgap images 194 MB, k3s 79 MB, kubectl 60 MB.
