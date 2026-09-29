# Sourced by create.sh, verify.sh and destroy.sh. Not executable on its own.

SLICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="${CLUSTER:-gpu-slice}"
HELM_IMAGE="alpine/helm:3.19.0"

# Never inherit an ambient KUBECONFIG. The machine may already run a cluster, and
# its kubectl may default to it: one test host had kubectl symlinked to k3s, which
# targets /etc/rancher/k3s/k3s.yaml. A readable file there would have let this
# suite mutate a live cluster and still report every check as passing.
export KUBECONFIG="${SLICE_KUBECONFIG:-$HOME/.kube/k3d-${CLUSTER}.yaml}"

say() { printf '==> %s\n' "$*"; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# Refuse to touch any cluster but ours. Call before the first kubectl that reads
# or writes cluster state.
assert_context() {
  local want="k3d-${CLUSTER}" got
  got="$(kubectl config current-context 2>/dev/null || true)"
  [ "$got" = "$want" ] ||
    die "kubectl context is '${got:-none}', expected '$want' (KUBECONFIG=$KUBECONFIG). Refusing to run against a cluster this slice did not create."
  # A context name is only a label in a file. Ask the API server itself: only
  # this k3d cluster has a node with this name.
  kubectl get node "k3d-${CLUSTER}-server-0" >/dev/null 2>&1 ||
    die "context '$want' does not answer as k3d cluster '$CLUSTER'. Stale or foreign kubeconfig at $KUBECONFIG."
  say "cluster OK: $want (KUBECONFIG=$KUBECONFIG)"
}

# helm is used only to render templates (no release state), so a pinned image
# works as well as a local binary. That keeps prerequisites to docker, k3d, kubectl.
# `type -P`, not `command -v`: inside this function, `command -v helm` finds the
# function itself and the fallback never runs.
helm() {
  if type -P helm >/dev/null; then
    command helm "$@"
  else
    docker run --rm -v "$SLICE_DIR:$SLICE_DIR:ro" -w "$SLICE_DIR" "$HELM_IMAGE" "$@"
  fi
}

# The single onboarding code path: tenant spec -> chart -> kubectl apply.
# values.schema.json rejects a malformed spec here, before the cluster sees it.
onboard() {
  local spec="$1" name
  name="$(basename "$spec" .yaml)"
  helm template "$name" "$SLICE_DIR/chart" -f "$spec" | kubectl apply -f -
}
