# Devcontainer constraints

The devcontainer runs under rootless Podman. Giving it privileges or devices is off limits, so
docker-in-docker, kind and k3d are out, see [decisions.md](./decisions.md#cluster). KVM is the
one exception: `/dev/kvm` is passed through when the host user already has access to it, but
it's never required.

## What it can and can't do

These were probed, not assumed.

- devices: no `/dev/kvm` (unless passed through), `/dev/net/tun` or `/dev/fuse`
- capabilities: none for `vscode`. Root via `sudo` has a reduced bounding set, `chown
  dac_override fowner fsetid kill setgid setuid setpcap net_bind_service sys_chroot sys_ptrace
  setfcap`, so no `sys_admin`, `net_admin` or `mknod`
- namespaces: nested user, mount, PID and net namespaces work, and `lo` can be brought up
- `/proc`: a fresh mount is denied, as Podman masked parts of it (`/proc/kcore`, `/proc/keys`, a
  read-only `/proc/sys`, ...) with locked mounts. Recursive binds of `/proc`, `/sys` and `/dev`
  work, as do `tmpfs`, `chroot` and `pivot_root`
- IDs: the container's user namespace maps only IDs 0..65536
- cgroups: v2, but `/sys/fs/cgroup` is read-only, so containers get no cgroup of their own
- seccomp: the outer engine's default profile, which denies `sethostname` without `sys_admin`
- file systems: `/` and `$HOME` are overlayfs, the workspace is ext4
- other: no systemd (pinned out in the Dockerfile), `XDG_RUNTIME_DIR` unset, no AppArmor

Some of these differ from first assumptions: nested net namespaces do work, and `sudo` does
grant capabilities, just not the ones that matter.

## How each part works around them

**Kubernetes runs in a VM.** QEMU needs no privileges at all: TCG emulates the CPU in software,
and the slirp network needs no tun device. That's what makes the cluster possible here. KVM
makes it several times faster where the host grants it, see
[decisions.md](./decisions.md#measurements).

**Ports below 1024** can't be bound without `net_bind_service`, so traefik's port 80 is
forwarded to `8080`, and the hello image listens on `8080`.

**No systemd.** The registry runs as a plain process, started by its recipe, not by the
package's unit. Podman uses `cgroupfs` as its cgroup manager.

**Root-level changes are lost on a rebuild**, e.g. `/etc/subuid` or file capabilities applied by
hand. `just setup` makes them with `sudo -n`, as `vscode` has passwordless sudo, and
`postCreateCommand` runs it after every rebuild. Only package installs are in the Dockerfile.
Every devcontainer change is also applied to the running container, the same way, to avoid
rebuild loops.

### Podman

Podman's default setup fails here in 3 places: ID mapping, `/proc` and the network.
[setup.sh](../../../env/setup.sh) fixes each.

**ID mapping.** Rootless Podman maps a range of subordinate IDs into its containers, so files in
images can belong to other users than root.

- The default range, `100000:65536`, is outside the container's IDs. `setup` derives the ranges
  from the container's own ID map instead: every ID but 0 and our own, e.g. `vscode:1:999` and
  `vscode:1001:64536`.
- `newuidmap` and `newgidmap` write the map, as setuid root by default, which fails: writing an
  ID map needs `sys_admin` over the new user namespace. Its owner, `vscode`, holds that
  implicitly, but root isn't the owner and lacks `sys_admin` here. So `setup` drops setuid and
  gives the helpers just `cap_setuid` / `cap_setgid`, which a multi-range map needs on top.
  Running with fewer rights is what makes it work.
- Without either fix, Buildah falls back to mapping a single ID with only a warning, and
  `chown` in builds is silently lost; Podman 5.4 fails outright. `setup` checks for the full
  map, 3 lines in `podman unshare cat /proc/self/uid_map`.

**`/proc`.** crun mounts a fresh `/proc` for every container and every `RUN` step, which is
denied. `containers.conf` adds `/proc:/proc:rbind` as a volume, which replaces Podman's own
`/proc` mount, so crun binds instead. It must be recursive: a plain bind would uncover the
masks, so it's denied just like a fresh mount. Containers keep a private PID namespace, but
`/proc` shows the devcontainer's processes, see [gotchas.md](./gotchas.md#podman).

**Network.** A private network needs `/dev/net/tun`, so containers use the host network:
`netns = "host"`. Ports bind straight on the devcontainer's loopback, so `-p` is meaningless.
`netavark` must still be installed, as Podman initializes its network backend at startup, and
Debian's build only supports `netavark`.

**Hostname.** The default seccomp profile denies `sethostname` without `sys_admin`, even in a
fresh UTS namespace, which fails every `RUN` step and `podman run`. So containers share the
devcontainer's UTS namespace: `utsns = "host"`. Debugger features, like the rust feature's, set
`seccomp=unconfined`, which hides this; check changes without them too.

**Storage** is native overlay under `.local/podman/` on the ext4 workspace; neither
`fuse-overlayfs` nor `vfs` is needed. The runroot goes to `/tmp`, as `XDG_RUNTIME_DIR` is unset.

**Resource limits** are silently ignored, as there's no cgroup per container. Kubernetes in the
VM is the place for realistic runs; Podman is for builds and quick checks of an image.

### KVM

`runArgs` can't be conditional, and `--device` with a missing source fails the container's
creation, so the devcontainer always gets a device:
[kvm-link.sh](../../../.devcontainer/kvm-link.sh) points the link at `/dev/kvm` or at
`/dev/null`. `--device` is used rather than a bind mount,
as it also gets the device past rootful Docker's device cgroup.

What counts is whether the devcontainer's user can open it, not the host user, so the probe
runs a container the way Dev Containers runs the devcontainer, and opens the device:

- **Rootless Podman** passes the host's device node, so the logind `uaccess` ACL of a desktop
  session applies to `vscode`, which maps to the host user. Group-only access, e.g. on a
  headless host, doesn't carry over, as the host's `kvm` group isn't mapped; that falls back
  to TCG. `--group-add=keep-groups` would fix it, but it's Podman-only.
- **Rootful Docker** creates its own node with the host's mode and group, but no ACL. So if a
  real `/dev/kvm` doesn't open, `setup` adds `vscode` to a group with the device's ID,
  creating `host-kvm` if there's none. Untested end to end, for lack of a Docker host.
- **CI**: GitHub's Linux runners have `/dev/kvm`, but the job has neither a seat ACL nor the
  group; a workflow step can open it up with GitHub's udev rule (`MODE="0666"`).

Codespaces has no KVM, so TCG stays fully supported.

## Open

- A fresh `/proc` would fix the PID view in `podman run`. It likely needs Podman's masks lifted
  for the devcontainer itself, with `--security-opt unmask=...` in `runArgs`; untested, and
  whether that counts as an extra privilege is open. Per run, `--security-opt unmask=ALL`
  doesn't help.
