#!/usr/bin/env bash

# SPDX-FileCopyrightText: Jean-Luc Deprez <https://github.com/spangaer>
# SPDX-License-Identifier: MIT

# run every test, stopping at the first failure; afterwards, pass or fail, remove the hello
# deployment and stop the VMs and registry that weren't running before, so nothing stays behind
# usage: all.sh <local dir>
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=SCRIPTDIR/../env/lib.sh
source env/lib.sh

local=$1
started=()

# remember what runs now, to stop only what the tests start
env/vm.sh cluster running "$local" || started+=("vm=cluster vm-down")
env/vm.sh build running "$local" || started+=("vm=build vm-down")
env/registry.sh running "$local" || started+=(registry-down)

cleanup() {
    local status=$? recipe
    trap - EXIT
    note "cleaning up"
    # hello.sh down needs the cluster; skip it if it never came up
    if env/vm.sh cluster running "$local"; then
        just test-hello-down || status=1
    fi
    for recipe in "${started[@]}"; do
        # shellcheck disable=SC2086 # split into just's arguments
        just $recipe || status=1
    done
    if ((status == 0)); then
        note "all passed"
    else
        note "FAILED, see above"
    fi
    exit "$status"
}
trap cleanup EXIT

just vm=cluster test-vm-ssh
just vm=build test-vm-ssh
just test-whoami
just builder=podman test-hello-up
just builder=docker test-hello-up
