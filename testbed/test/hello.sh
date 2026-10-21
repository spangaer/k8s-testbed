#!/usr/bin/env bash
# build the hello image under a fresh tag, push it to the registry, roll the deployment over to
# it and wait until the ingress serves that build; needs the registry and the cluster VM
# running, which the recipes ensure. `up` leaves it running for a look; `down` removes it.
# usage: hello.sh up <local dir> <builder> | down
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=SCRIPTDIR/../env/lib.sh
source env/lib.sh

base=test/hello
repo=localhost:5000/hello
url=http://hello.localhost:8080/
keep="kept for a look, remove with: just test-hello-down"

# True once the ingress answered with the expected page a few times in a row; keeps the last
# response in body. Traefik may still route to a pod that just went for a moment, which then
# times out, so one good answer isn't enough.
body=
streak=0
served() {
    if body=$(curl -fsS --max-time 5 "$url" 2> /dev/null) && [[ $body == "$expected" ]]; then
        ((++streak))
    else
        streak=0
    fi
    ((streak >= 5))
}
status() {
    local code
    code=$(curl -sS -o /dev/null -w 'HTTP %{http_code}' --max-time 5 "$url" 2>&1 || true)
    printf '%s, last body: %s' "$code" "${body:-none}"
}

# true once all hello pods run the new image, so none of the old ones can still answer
pod_images=
only_new() {
    pod_images=$(kubectl get pods -l app=hello \
        -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort -u)
    [[ $pod_images == "$repo:$tag" ]]
}
pods_status() { echo "pods run: ${pod_images//$'\n'/, }"; }

build() {
    local builder=$1 image
    case $builder in
        podman) image=$repo:$tag ;;
        # pushes run in the build VM, which reaches the same registry as 10.0.2.2
        docker) image=10.0.2.2:5000/${repo#*/}:$tag ;;
        *) die "unknown builder '$builder', use podman or docker" ;;
    esac
    # both take the same arguments
    "$builder" build --build-arg TAG="$tag" -t "$image" test/hello
    "$builder" push "$image"
    # the registry has it now; drop the local tag, so runs don't pile up images
    "$builder" rmi "$image" > /dev/null
}

up() {
    # the overlay is per run, as kustomize takes no values on the command line
    local overlay=$1/hello builder=$2 previous
    # unique per run, so each run rolls out a new image, and the page tells which one answers
    tag=$(date -u +%Y%m%d-%H%M%S-%3N)
    expected="hello from $tag"
    previous=$(kubectl get deployment/hello --ignore-not-found \
        -o jsonpath='{.spec.template.spec.containers[0].image}')

    build "$builder"

    # The base leaves the tag out, so no old build is pinned in git; the overlay sets this run's.
    # Applied without it, the image defaults to :latest, which is never pushed, so the pull fails
    # rather than running an outdated build.
    mkdir -p "$overlay"
    # refers to the base relatively, as kustomize rejects absolute paths
    cat > "$overlay/kustomization.yaml" <<EOF
# written by test/hello.sh, for the last run
resources:
  - $(realpath --relative-to="$overlay" "$base")
images:
  - name: $repo
    newTag: "$tag"
EOF
    kubectl apply -k "$overlay"

    if ! kubectl rollout status deployment/hello --timeout=5m; then
        kubectl get pods -l app=hello -o wide >&2 || true
        die "the hello deployment didn't become ready; $keep"
    fi
    # the rollout is done once the new pods are ready, while old ones may still terminate
    if ! wait_for 60 termination pods_status only_new; then
        die "old hello pods remain ($(pods_status)); $keep"
    fi

    # traefik picks up a new ingress within seconds, until then it answers 404
    if ! wait_for 60 ingress status served; then
        die "$url doesn't serve '$expected' ($(status)); $keep"
    fi
    note "ok: $url serves '$body'${previous:+, replacing $previous}"
}

down() {
    kubectl delete -k "$base" --ignore-not-found --wait
}

case ${1-} in
    up) (($# == 3)) || die "usage: hello.sh up <local dir> <builder>"; up "$2" "$3" ;;
    down) down ;;
    *) die "usage: hello.sh up <local dir> <builder> | down" ;;
esac
