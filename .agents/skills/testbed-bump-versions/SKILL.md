---
name: testbed-bump-versions
description: 'Bump the pinned versions and checksums in testbed/versions.just: Debian cloud
  image, k3s binary, airgap images and install.sh, kubectl, krew and the krew-index revision.
  Use when asked to update, upgrade, bump or refresh pins, versions, checksums, k3s,
  Kubernetes, kubectl, krew or the Debian image, or to check whether newer versions exist.'
argument-hint: 'optional k3s channel: stable (default), latest, or a minor like v1.36'
---

# Bump the testbed's pinned versions

Every download is pinned in [versions.just](../../../testbed/versions.just), with its checksum,
and cached in `.local/testbed/cache/` under a file name that carries the version. A bump fetches
anew and leaves the old files; the VMs refuse the new pins until they're reset.

## Rules

- checksums come from upstream checksum files, never from hashing a download, except for the
  2 files that have none: `install.sh`, fetched by commit, and krew's `krew.yaml`, whose
  archive checksum must match the release's own; [latest.sh](./scripts/latest.sh) handles all
  of it
- k3s and kubectl stay on the same Kubernetes minor; the script takes kubectl's version from
  k3s's
- k3s follows its `stable` channel unless the user asks otherwise; `v1.36` stays on a minor, see
  [release channels](https://docs.k3s.io/upgrades/manual#release-channels)
- bump all pins together, as one change, unless the user picks some
- the user's `vm-reset`s replace both VMs: say so before running them, as the cluster's state
  goes, and ask if they hold anything worth keeping

## Procedure

1. Run `.agents/skills/testbed-bump-versions/scripts/latest.sh [<channel>]`. It changes nothing, and
   prints each pin, marked with `*` and followed by the new value where it differs, then the
   krew plugins' versions, which `krew_index_rev` pins. If no pin differs, report that and
   stop. In the report, name the plugins whose version changes.
2. For a new k3s minor, skim its release notes for breaking changes, e.g. in the bundled
   traefik, and mention them: `https://github.com/k3s-io/k3s/releases/tag/<version>`.
3. Edit [versions.just](../../../testbed/versions.just): only the values, keep its comments and
   expressions; split long strings with `+` to stay within 100 chars, as `debian_image_sha512`
   is. Check with `just --evaluate <name>` in `testbed/`, and rerun `latest.sh`: it must report
   0 differing.
4. Apply and validate, by what changed, stopping at the first failure, running `just` in
   `testbed/`:
   - kubectl, krew or krew-index: `just setup`; `kubectl version --client` and
     `kubectl krew list` show the new versions
   - Debian image or k3s: `just vm-reset`, then `just vm-up`; it fetches the new files, and
     the node is `Ready`
   - Debian image: `just vm=build vm-reset`, then `just vm=build vm-up`, until `docker: ready`
   - always: `just test-all`, until `all passed`; it stops the VMs and registry it started

   With the cluster VM up, `kubectl get nodes -o wide` shows the k3s version and the guest's
   kernel and OS. End by stopping the build VM again if it wasn't running before the bump.
5. Old cache files are only removed when asked. A cloud image must not be removed while a VM
   disk still uses it as backing file, check with
   `qemu-img info -U --backing-chain .local/testbed/vm/*/disk.qcow2 | grep '^backing file:'`.
6. Report old and new values, what ran and how long the first boots took. Write
   `commit-message.md`, following the commit rules in [AGENTS.md](../../../AGENTS.md), naming
   the versions, not the checksums. Don't commit.

## Sources

What [latest.sh](./scripts/latest.sh) reads, for when it breaks:

- `debian_image_*`: the newest dated dir at `https://cloud.debian.org/images/cloud/trixie/`,
  checksum from `SHA512SUMS` in that dir
- `k3s_version`, `k3s_sha256`, `k3s_images_sha256`: where
  `https://update.k3s.io/v1-release/channels/<channel>` redirects to, checksums from the
  release's `sha256sum-amd64.txt`
- `k3s_install_*`: the commit of the k3s tag, its `^{}` if annotated, and the sha256 of
  `install.sh` at that commit
- `kubectl_*`: k3s's version without `+k3sN`, checksum from
  `https://dl.k8s.io/release/<version>/bin/linux/amd64/kubectl.sha256`
- `krew_*`: where krew's `releases/latest` redirects to, checksum from
  `krew-linux_amd64.tar.gz.sha256`, and the sha256 of `krew.yaml`
- `krew_index_rev`: `master` of `kubernetes-sigs/krew-index`, if all plugins are found there,
  and only if one of their `version:`s differs from the current commit; else it's kept
