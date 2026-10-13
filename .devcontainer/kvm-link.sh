#!/bin/sh
# Runs on the host, from initializeCommand, before the devcontainer is created.
# devcontainer.json passes .local/host/kvm as --device /dev/kvm, and runArgs can't be
# conditional, so point that link at /dev/kvm if a probe container can open the device, else
# at /dev/null, as --device needs a device. Either way the container starts, and vm.sh picks
# KVM only if it gets a usable /dev/kvm. The link is resolved when the container is created, so
# a change in access needs a rebuild.
set -eu

dir=$(cd "$(dirname "$0")/.." && pwd)/.local/host
link=$dir/kvm
image=docker.io/library/busybox

# the CLI Dev Containers uses: VS Code's dev.containers.dockerPath, else docker, else podman
container_cli() {
    conf=${XDG_CONFIG_HOME:-$HOME/.config} s='[[:space:]]'
    for f in "$conf"/Code*/User/settings.json "$conf"/VSCodium/User/settings.json \
        "$HOME"/.var/app/com.visualstudio.code/config/Code/User/settings.json; do
        [ -f "$f" ] || continue
        # skips commented-out lines, as the key must start the line
        cli=$(sed -n "s/^$s*\"dev\.containers\.dockerPath\"$s*:$s*\"\([^\"]*\)\".*/\1/p" "$f" \
            | tail -n 1)
        if [ "$cli" ]; then
            echo "$cli"
            return
        fi
    done
    if command -v docker > /dev/null; then echo docker; else echo podman; fi
}

# open /dev/kvm in a container, with the given extra run options; prints why on failure
try_open() {
    out=$("$cli" run --rm "$@" --device /dev/kvm:/dev/kvm "$image" \
        sh -c 'exec 3<> /dev/kvm' 2>&1) || { echo "$out" | tail -n 1; return 1; }
}

# Run a container the way Dev Containers runs the devcontainer, with /dev/kvm passed like the
# devcontainer gets it through the link, and open it. Opening, not just checking permissions,
# also catches a device cgroup that denies it. If that fails, retry with the device's group,
# which `just setup` adds the user to in the devcontainer, e.g. for rootful Docker, which
# doesn't carry over the host's ACL for the user. Prints why on failure.
probe() {
    if ! "$cli" image inspect "$image" > /dev/null 2>&1; then
        out=$("$cli" pull -q "$image" 2>&1) || { echo "$out" | tail -n 1; return 1; }
    fi
    # Dev Containers' test for Podman, which then gets these, and keep-id also runs it as this
    # user; for Docker, it gives the container user this user's IDs instead, so pass them, as
    # busybox would run as root
    case $("$cli" -v 2> /dev/null | tr '[:upper:]' '[:lower:]') in
        *podman*) set -- --userns=keep-id --security-opt label=disable ;;
        *) set -- --user "$(id -u):$(id -g)" ;;
    esac
    if first=$(try_open "$@"); then
        echo "usable with $cli"
    elif try_open "$@" --group-add "$(stat -L -c %g /dev/kvm)" > /dev/null; then
        echo "usable with $cli, once just setup adds the device's group"
    else
        echo "$first"
        return 1
    fi
}

mkdir -p "$dir"
# the link changes only once decided
target=/dev/null
if [ ! -c /dev/kvm ]; then
    why="no /dev/kvm on this host"
else
    cli=$(container_cli)
    if ! command -v "$cli" > /dev/null; then
        why="no container CLI '$cli'"
    elif why=$(probe); then
        target=/dev/kvm
    else
        why="$cli: $why"
    fi
fi
ln -sfn "$target" "$link"
echo "kvm-link: $link -> $target, $why"
