import 'versions.just'

set shell := ["bash", "-euo", "pipefail", "-c"]

local := justfile_directory() / ".local"
cache := local / "cache"

# for kubectl and docker in recipes; a caller's value wins, devcontainer.json sets the same
export KUBECONFIG := env("KUBECONFIG", local / "vm/cluster/kubeconfig")
export DOCKER_HOST := env("DOCKER_HOST", "tcp://127.0.0.1:2375")
# for setup; in .local, so krew and its plugins survive a rebuild
export KREW_ROOT := env("KREW_ROOT", local / "krew")

# the VM the vm-* recipes act on: cluster or build, e.g. just vm=build vm-up
vm := "cluster"

# image builder for test-hello-up: podman, or docker in the build VM, e.g.
# just builder=docker test-hello-up
builder := "podman"

# VM sizing, e.g. just vm_mem=8G vm-up; empty for the VM's default, see env/vm.sh
vm_cpus := ""
vm_mem := ""
vm_disk := ""
export VM_CPUS := vm_cpus
export VM_MEM := vm_mem
export VM_DISK := vm_disk

# auto uses KVM if /dev/kvm is usable, else TCG; kvm or tcg force one, e.g. to compare
vm_accel := "auto"
export VM_ACCEL := vm_accel

debian_image := cache / debian_image_file
k3s_bin := cache / "k3s-" + k3s_version
k3s_images := cache / replace(k3s_images_file, ".tar.zst", "-" + k3s_version + ".tar.zst")
k3s_install := cache / "k3s-install-" + k3s_install_rev + ".sh"

# list recipes
default:
    @just --list

# devcontainer setup: ID mapping, kubectl, containers config, KVM group, krew; safe to rerun
setup:
    env/setup.sh {{ quote(local) }} {{ quote(cache / "kubectl-" + kubectl_version) }} \
        {{ quote(kubectl_url) }} {{ quote(kubectl_sha256) }}
    env/krew.sh {{ quote(cache) }} {{ krew_version }} {{ quote(krew_url) }} {{ krew_sha256 }} \
        {{ krew_manifest_sha256 }} {{ krew_index_rev }} {{ krew_plugins }}

# start the local registry on 127.0.0.1:5000
registry-up:
    env/registry.sh up {{ quote(local) }}

# stop the local registry
registry-down:
    env/registry.sh down {{ quote(local) }}

# fetch downloads, create the VM's disk and seed; an existing VM is kept, see vm-reset
vm-image:
    #!/usr/bin/env bash
    # a shebang runs the body as one script, as plain recipes run each line in its own shell,
    # which breaks the multi-line case and the array; set shell doesn't apply, hence the set
    set -euo pipefail
    # files for the seed, named as the VM's user-data expects them
    case {{ quote(vm) }} in
        cluster)
            env/fetch.sh {{ quote(k3s_url / "k3s") }} {{ k3s_sha256 }} {{ quote(k3s_bin) }}
            env/fetch.sh {{ quote(k3s_url / k3s_images_file) }} {{ k3s_images_sha256 }} \
                {{ quote(k3s_images) }}
            env/fetch.sh {{ quote(k3s_install_url) }} {{ k3s_install_sha256 }} \
                {{ quote(k3s_install) }}
            files=(
                {{ quote("k3s=" + k3s_bin) }}
                {{ quote(k3s_images_file + "=" + k3s_images) }}
                {{ quote("install.sh=" + k3s_install) }}
            )
            ;;
        # installs Docker from the Debian mirror, nothing to carry
        build) files=() ;;
        *)
            echo "vm-image: unknown vm '{{ vm }}', expected cluster or build" >&2
            exit 1
            ;;
    esac
    env/fetch.sh {{ quote(debian_image_url) }} {{ debian_image_sha512 }} \
        {{ quote(debian_image) }}
    env/vm.sh {{ quote(vm) }} image {{ quote(local) }} {{ quote(debian_image) }} "${files[@]}"

# boot the VM unless it runs, and wait until it's ready
vm-up: vm-image
    env/vm.sh {{ quote(vm) }} up {{ quote(local) }}

# shut the VM down cleanly
vm-down:
    env/vm.sh {{ quote(vm) }} down {{ quote(local) }}

# ssh into the VM, or run a command there with its arguments unchanged
[positional-arguments]
vm-ssh *args:
    @env/vm.sh {{ quote(vm) }} ssh {{ quote(local) }} "$@"

# stop the VM and drop its disk and seed, for a fresh one; the caches stay
vm-reset:
    env/vm.sh {{ quote(vm) }} reset {{ quote(local) }}

# copy the cluster's admin kubeconfig to .local/vm/cluster/kubeconfig
kubeconfig:
    env/vm.sh cluster kubeconfig {{ quote(local) }}

# lint the shell scripts; git's file list skips what .gitignore excludes, like .local/
lint:
    git ls-files -z --cached --others --exclude-standard '*.sh' | xargs -0 shellcheck -x

# check that vm-ssh passes arguments unchanged
test-vm-ssh: vm-up
    test/vm-ssh.sh {{ quote(vm) }}

# deploy the public whoami image and reach it through the ingress; no registry needed
test-whoami: _whoami-up _whoami-down

# deploy whoami and check it's served, then leave it running for a look
_whoami-up:
    just vm=cluster vm-up
    test/whoami.sh up

# remove the whoami deployment, if any
_whoami-down:
    test/whoami.sh down

# build and push hello under a fresh tag, roll it out and check the ingress serves that build;
# builder=docker builds in the build VM, which it starts if needed
test-hello-up: registry-up
    just vm=cluster vm-up
    if [[ {{ quote(builder) }} == docker ]]; then just vm=build vm-up; fi
    test/hello.sh up {{ quote(builder) }}

# remove the hello deployment, if any; test-hello-up leaves it running for a look
test-hello-down:
    test/hello.sh down

# run all tests, on both VMs and with both builders; then remove the hello deployment and stop
# the VMs and registry it started, pass or fail
test-all:
    test/all.sh {{ quote(local) }}
