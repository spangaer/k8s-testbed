# k8s-testbed

A single-node Kubernetes testbed that runs from inside a devcontainer, without giving it
privileges: k3s in a QEMU VM, a local registry and a separate VM to build images.

The objective is a Kubernetes testbed to learn on and to develop against.
The code itself has no ambition to be production grade.

Sources are thrown online with proper license notices, just in case anyone would want to put
them to use anyway.

## Usage

Open the repo in its devcontainer; creating it runs `just setup`. KVM is used if the host grants
access to `/dev/kvm`, else QEMU falls back to much slower software emulation. Then, in
`testbed/`:

```sh
just up                              # registry and cluster VM; the first run downloads and boots
                                     # for minutes
kubectl get nodes                    # KUBECONFIG is set in the devcontainer
just test-hello-up                   # build, push and deploy hello with Podman
curl http://hello.localhost:8080/    # served through the ingress
just down                            # stop it all, the build VM too; the cluster state stays
```

`just` lists all recipes. From the repo root, run them as `just testbed::<recipe>`.

How it fits together, and why, is in [testbed/docs/udd/](./testbed/docs/udd/README.md).
