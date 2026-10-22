# Gotchas

Surprises that span files. Those tied to one spot are commented there.

## Podman

- **Storage holds files owned by mapped IDs**, so plain `rm`, `du` and file search tools hit
  `Permission denied` in `.local/testbed/podman/`. Clean up with `podman rmi`,
  `podman system prune`, or `podman system reset` to wipe it all; for raw file access, use
  `podman unshare`.
- **A missing ID mapping fix only warns.** Buildah then maps a single ID, and `chown` in builds
  is silently lost. If `podman unshare cat /proc/self/uid_map` shows fewer than 3 lines, rerun
  `just setup`; reinstalling `uidmap` resets the helpers' setuid bit and capabilities.
- **`/proc` in `podman run` shows the devcontainer's processes.** PIDs come from the
  container's own namespace, `/proc` from the devcontainer's: `$$` is 1, while `/proc/1` is the
  devcontainer's init. `/proc/self` and `kill` work, but `ps`, `pgrep`, `/proc/$$/...` and
  runtimes inspecting child processes by PID, e.g. Java's `ProcessHandle.info()`, get the wrong
  or no data. `--pid=host` fixes that per run, but then `podman stop` hangs.
- **Ports bind straight on the devcontainer's loopback**, so 2 containers, or a container and
  a devcontainer process, can clash. Resource limits like `--memory` are silently ignored.
- **`seccomp=unconfined` hides breakage.** Debugger features, like the rust feature, add it, and
  then `sethostname` works without `utsns = "host"`. Check changes without such features too.
- `podman unshare <cmd> | head` can log `signal: broken pipe`, which is harmless.

## Containers in general

- **A PID 1 without a `SIGTERM` handler ignores it**, so stopping waits for the grace period,
  and a replaced pod keeps serving meanwhile; busybox `httpd` is one. Wrap it in a shell that
  traps `TERM`, as `test/hello/Dockerfile` does.
- **Docker only looks for `Dockerfile`**, not `Containerfile`, without `-f`; Podman takes both.
- **Build VM pushes use `10.0.2.2:5000/<name>`**, as `localhost` in the VM is the VM itself.
  It's the same repository as `localhost:5000/<name>`, so manifests don't change.

## Cluster

- **`kubectl` without `KUBECONFIG`** falls back to `localhost:8080`, which is traefik's forward,
  so errors read as a missing resource rather than a missing config.
- **A warm start shows a stale `Ready`.** `get nodes` can still show the condition from before
  the shutdown, so readiness also checks the addons and traefik.
- **Right after the k3s install, no pods exist yet**, so "no pod isn't running" passes too early;
  readiness checks the deployments' ready replicas instead.
- **`helm-install-traefik` restarts** a few times on a first boot, while it waits for its
  CustomResourceDefinitions (CRDs), which the `traefik-crd` chart installs. That's normal.
- **Traefik needs a moment.** It answers `404` until it picks up a new ingress, within seconds,
  and after a rollout it may briefly route to pods that are gone, which shows as `504` or a
  timeout. Checks wait for several good answers in a row.
- **Public images in the guest aren't cached**, so they're pulled again after a `vm-reset`.

## VMs

- **A power button press in early boot is lost**, before systemd-logind listens, so `vm-down`
  repeats it every 10 s.
- **Never delete a cached cloud image while an overlay uses it** as its backing image.
- **A changed user-data template asks for a `vm-reset`**, even if only a comment changed, as
  `settings` records its hash.
- **QEMU can't take paths with a comma**, which it uses to separate options.

## Devcontainer

- **Groups are fixed when a process starts.** After `setup` adds `vscode` to the KVM group,
  shells started before don't have it; restart the container, or use `newgrp`. The VS Code
  server survives a window reload, so `waitFor: postCreateCommand` makes it connect only after
  `setup`, and it starts with the group.
- **`remoteEnv` changes apply after a window reload**, but only to terminals opened after it;
  terminals restored by the reload keep their old environment.
- **The KVM link is resolved when the container is created**, so a change in host access needs
  a rebuild.
- **Background starts race.** Right after `cmd &`, `$!` is often still the forked shell or
  `setsid`, about 1 in 4 times, before it execs the command, so a pid file check by executable
  fails. `registry.sh` checks the child by PID during startup, and the pid file once it answers.

## Downloads

- **cloud.debian.org's directory listing sometimes stalls**; bound requests with a timeout and
  retry.
- **k3s versions contain a `+`**, which must be URL-encoded as `%2B` in release URLs.
- **krew skips an installed plugin, whatever its version**, so a change needs an uninstall
  first; it doesn't remove or reinstall itself either. Installs by manifest skip the index,
  which `uninstall` and `search` need, so `krew.sh` adds it once.
