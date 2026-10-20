#!/usr/bin/env bash
# Resolve the latest upstream value of each pin in versions.just, with checksums from the
# upstream checksum files, and print them next to the current ones. Changes nothing.
# usage: latest.sh [<k3s channel>], e.g. stable (default), latest, or v1.36 to stay on a minor
set -euo pipefail

channel=${1:-stable}
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# shellcheck source=env/lib.sh
source "$root/env/lib.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

get() { curl -fsSL --retry 3 "$@"; }
# where a redirect, like a GitHub latest release or a k3s channel, points to
target() { curl -fsS --retry 3 -o /dev/null -w '%{redirect_url}' "$1"; }
# the checksum of a file from a `<sum>  <name>` list on stdin, fails if it's not there
sum_of() { awk -v f="$1" '$2 == f || $2 == "*" f { print $1; n++ } END { exit n != 1 }'; }
current() { just --justfile "$root/justfile" --evaluate "$1"; }

declare -A want
order=()
pin() {
    [[ $2 =~ ^[0-9a-zA-Z.+-]+$ ]] || die "odd value for $1: '$2'"
    want[$1]=$2
    order+=("$1")
}

# --- Debian cloud image: the newest dated dir, and its SHA512SUMS

debian=https://cloud.debian.org/images/cloud/trixie
rev=$(get "$debian/" | grep -oE 'href="[0-9]{8}-[0-9]+/"' | grep -oE '[0-9]{8}-[0-9]+' \
    | sort -u | tail -n 1)
[[ $rev ]] || die "no dated image dirs at $debian/"
file=debian-13-genericcloud-amd64-$rev.qcow2
sum=$(get "$debian/$rev/SHA512SUMS" | sum_of "$file") \
    || die "$file isn't in $debian/$rev/SHA512SUMS"
pin debian_image_rev "$rev"
pin debian_image_sha512 "$sum"

# --- k3s: the channel's release and its sha256sum file, install.sh at the tagged commit

version=$(target "https://update.k3s.io/v1-release/channels/$channel" | sed 's#.*/tag/##') \
    || die "no k3s channel '$channel', see https://docs.k3s.io/upgrades/manual#release-channels"
[[ $version == v*+k3s* ]] || die "no k3s release for channel '$channel'"
release=https://github.com/k3s-io/k3s/releases/download/${version/+/%2B}
get -o "$tmp/k3s.sums" "$release/sha256sum-amd64.txt"
sum=$(sum_of k3s < "$tmp/k3s.sums") || die "no k3s in $release/sha256sum-amd64.txt"
images=$(sum_of k3s-airgap-images-amd64.tar.zst < "$tmp/k3s.sums") \
    || die "no airgap images in $release/sha256sum-amd64.txt"
pin k3s_version "$version"
pin k3s_sha256 "$sum"
pin k3s_images_sha256 "$images"

# an annotated tag also lists the commit it points to, as ^{}, which sorts last
rev=$(git ls-remote https://github.com/k3s-io/k3s "refs/tags/$version" \
    "refs/tags/$version^{}" | sort -k 2 | awk 'END { print $1 }')
[[ $rev ]] || die "no tag $version in k3s-io/k3s"
# no upstream checksum, but the URL names the commit, so its content can't change
get -o "$tmp/install.sh" "https://raw.githubusercontent.com/k3s-io/k3s/$rev/install.sh"
pin k3s_install_rev "$rev"
pin k3s_install_sha256 "$(sha256sum < "$tmp/install.sh" | cut -d ' ' -f 1)"

# --- kubectl: the Kubernetes version k3s wraps, so it's always on the same minor

version=${version%%+*}
sum=$(get "https://dl.k8s.io/release/$version/bin/linux/amd64/kubectl.sha256")
pin kubectl_version "$version"
pin kubectl_sha256 "$sum"

# --- krew: the latest release; its manifest has no checksum file, but must give the archive
# the same checksum as the release's checksum file

version=$(target https://github.com/kubernetes-sigs/krew/releases/latest | sed 's#.*/tag/##')
[[ $version == v* ]] || die "no latest krew release"
release=https://github.com/kubernetes-sigs/krew/releases/download/$version
sum=$(get "$release/krew-linux_amd64.tar.gz.sha256" | cut -d ' ' -f 1)
get -o "$tmp/krew.yaml" "$release/krew.yaml"
grep -A 1 '/krew-linux_amd64\.tar\.gz$' "$tmp/krew.yaml" | grep -qx " *sha256: $sum" \
    || die "krew.yaml of $version doesn't match krew-linux_amd64.tar.gz.sha256"
pin krew_version "$version"
pin krew_sha256 "$sum"
pin krew_manifest_sha256 "$(sha256sum < "$tmp/krew.yaml" | cut -d ' ' -f 1)"

# --- krew-index: master, if it still has all our plugins, and only if a plugin version
# changes, as a bump otherwise changes nothing

index=https://raw.githubusercontent.com/kubernetes-sigs/krew-index
index_old=$(current krew_index_rev)
index_master=$(git ls-remote https://github.com/kubernetes-sigs/krew-index refs/heads/master \
    | cut -f 1)
[[ $index_master ]] || die "can't resolve krew-index master"
plugins=()
declare -A plugin_old plugin_new
index_moves=
for plugin in $(current krew_plugins); do
    plugins+=("$plugin")
    rc=0
    get -o "$tmp/$plugin.yaml" "$index/$index_master/plugins/$plugin.yaml" || rc=$?
    case $rc in
        0) ;;
        22) die "plugin '$plugin' is gone from krew-index at $index_master" ;;
        *) die "can't fetch $index/$index_master/plugins/$plugin.yaml, curl exit code $rc" ;;
    esac
    plugin_new[$plugin]=$(version_of "$tmp/$plugin.yaml")
    [[ ${plugin_new[$plugin]} ]] \
        || die "no version in $index/$index_master/plugins/$plugin.yaml"
    # curl's exit code 22 is an HTTP error, a 404 here: a plugin added to krew_plugins since;
    # anything else, like a network error, must not pass as a missing plugin
    rc=0
    get -o "$tmp/$plugin.old.yaml" "$index/$index_old/plugins/$plugin.yaml" 2> /dev/null \
        || rc=$?
    case $rc in
        0) plugin_old[$plugin]=$(version_of "$tmp/$plugin.old.yaml") ;;
        22) plugin_old[$plugin]= ;;
        *) die "can't fetch $index/$index_old/plugins/$plugin.yaml, curl exit code $rc" ;;
    esac
    # no manifest or no version reads as none, so it differs from any real one
    : "${plugin_old[$plugin]:=none}"
    [[ ${plugin_old[$plugin]} == "${plugin_new[$plugin]}" ]] || index_moves=1
done
if [[ $index_moves ]]; then
    pin krew_index_rev "$index_master"
else
    pin krew_index_rev "$index_old"
fi

# --- report, changed pins marked with *

changed=0
for name in "${order[@]}"; do
    have=$(current "$name")
    if [[ $have == "${want[$name]}" ]]; then
        printf '  %-21s %s\n' "$name" "$have"
    else
        printf '* %-21s %s\n  %-21s -> %s\n' "$name" "$have" "" "${want[$name]}"
        changed=$((changed + 1))
    fi
done
# the plugins krew-index pins, informational, as they follow krew_index_rev
for plugin in "${plugins[@]}"; do
    if [[ ${plugin_old[$plugin]} == "${plugin_new[$plugin]}" ]]; then
        printf '  %-21s %s\n' "plugin $plugin" "${plugin_old[$plugin]}"
    else
        printf '* %-21s %s -> %s\n' "plugin $plugin" "${plugin_old[$plugin]}" \
            "${plugin_new[$plugin]}"
    fi
done
if [[ ! $index_moves && $index_master != "$index_old" ]]; then
    echo "krew-index master $index_master changes no plugin, kept"
fi
echo "$changed of ${#order[@]} pins differ, k3s channel $channel"
