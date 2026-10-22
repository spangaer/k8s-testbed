#!/usr/bin/env bash

# SPDX-FileCopyrightText: Jean-Luc Deprez <https://github.com/spangaer>
# SPDX-License-Identifier: MIT

# smoke test: deploy the public traefik/whoami image and reach it through the ingress, which
# checks the cluster without the registry; needs the cluster VM running, which the recipes
# ensure. `up` deploys and checks, and leaves it running for a look; `down` removes it.
# usage: whoami.sh up|down
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=SCRIPTDIR/../env/lib.sh
source env/lib.sh

manifest=test/whoami/whoami.yaml
url=http://whoami.localhost:8080/
keep="kept for a look, remove with: just _whoami-down"

hostname_of() { sed -n 's/^Hostname: //p' <<< "$1" | tr -d '\r'; }

# true once a whoami pod answers through the ingress; keeps the response in body
body=
served() {
    local pods
    body=$(curl -fsS --max-time 5 "$url" 2> /dev/null) || return 1
    pods=$(kubectl get pods -l app=whoami -o jsonpath='{.items[*].metadata.name}')
    [[ " $pods " == *" $(hostname_of "$body") "* ]]
}
status() { curl -sS -o /dev/null -w 'HTTP %{http_code}' --max-time 5 "$url" 2>&1 || true; }

up() {
    kubectl apply -f "$manifest"

    # generous for a first pull under TCG
    if ! kubectl rollout status deployment/whoami --timeout=5m; then
        kubectl get pods -l app=whoami -o wide >&2 || true
        die "the whoami deployment didn't become ready; $keep"
    fi

    # traefik picks up a new ingress within seconds, until then it answers 404
    if ! wait_for 60 ingress status served; then
        die "no answer from a whoami pod at $url ($(status)); $keep"
    fi
    note "ok: $url is served by $(hostname_of "$body")"
}

down() {
    kubectl delete -f "$manifest" --ignore-not-found --wait
}

case ${1-} in
    up | down) "$1" ;;
    *) die "usage: whoami.sh up|down" ;;
esac
