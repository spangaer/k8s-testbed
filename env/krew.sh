#!/usr/bin/env bash
# krew, the kubectl plugin manager, and plugins, all pinned; user-level, so no sudo
# Safe to rerun: it only installs what's missing or differs from its pin, offline once cached.
# Plugins come from krew-index at a commit, so they're "detached": a pin bump updates them, not
# kubectl krew upgrade.
# usage: krew.sh <cache dir> <krew version> <krew url> <archive sha256> <manifest sha256>
#            <index rev> <plugin>...
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env/lib.sh
source "$here/lib.sh"

cache=$1 version=$2 url=$3 archive_sha256=$4 manifest_sha256=$5 index_rev=$6
shift 6
root=${KREW_ROOT:?"KREW_ROOT must be set, the justfile and devcontainer.json do"}

# Run krew, showing its output only on failure. Otherwise it's usage notes and a PATH warning,
# which devcontainer.json handles. Its stdin is a terminal for a manual run, so close it, or
# it warns about that too.
quiet() {
    local out
    out=$("$@" 2>&1 < /dev/null) || die "$out"
}

# --- krew, offline from the release's own manifest and archive

archive=$cache/krew-$version.tar.gz
manifest=$cache/krew-$version.yaml
"$here/fetch.sh" "$url/krew-linux_amd64.tar.gz" "$archive_sha256" "$archive"
"$here/fetch.sh" "$url/krew.yaml" "$manifest_sha256" "$manifest"

if [[ $(version_of "$root/receipts/krew.yaml") != "$version" ]]; then
    # krew neither removes nor reinstalls itself, so drop an old one by hand
    rm -rf "$root/receipts/krew.yaml" "$root/store/krew"
    tmp=$(mktemp -d)
    tar -xzf "$archive" -C "$tmp" ./krew-linux_amd64
    quiet "$tmp/krew-linux_amd64" install --manifest="$manifest" --archive="$archive"
    rm -rf "$tmp"
    note "installed krew $version"
fi

krew=$root/bin/kubectl-krew

# Installs by manifest skip the index, but uninstall, search and installs by name need it. Only
# when missing, as an update pulls it, so reruns stay offline.
if [[ ! -d $root/index/default ]]; then
    quiet "$krew" update
    note "added krew's default plugin index"
fi

# --- plugins, by their manifests at the pinned index commit

index_url=https://raw.githubusercontent.com/kubernetes-sigs/krew-index/$index_rev/plugins
index_dir=$cache/krew-index-$index_rev

for plugin; do
    manifest=$index_dir/$plugin.yaml
    if [[ ! -f $manifest ]]; then
        mkdir -p "$index_dir"
        note "$index_url/$plugin.yaml"
        curl -fsSL --retry 3 -o "$manifest.part" "$index_url/$plugin.yaml"
        mv "$manifest.part" "$manifest"
    fi
    want=$(version_of "$manifest")
    have=$(version_of "$root/receipts/$plugin.yaml")
    if [[ $have == "$want" ]]; then
        continue
    fi
    # install skips a plugin that's there, whatever its version
    if [[ $have ]]; then
        quiet "$krew" uninstall "$plugin"
    fi
    quiet "$krew" install --manifest="$manifest"
    note "installed $plugin $want"
done
