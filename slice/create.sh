#!/usr/bin/env bash
# One command up: cluster, fake GPUs, platform objects, then every tenants/*.yaml.
# Re-runnable: each step converges on the desired state instead of assuming a
# fresh machine, so running it against an existing cluster changes nothing.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# The k3d default (k3s v1.31) is four minors behind current kubectl, outside the
# supported skew. Pin it here, not in a README caveat.
K3S_IMAGE="rancher/k3s:v1.35.8-k3s1"
GPUS_PER_NODE=4
POOL_LABEL="platform.example.com/compute-pool"

create_cluster() {
  if k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
    say "cluster $CLUSTER exists; converging it"
    k3d cluster start "$CLUSTER" >/dev/null
  else
    # traefik and servicelb are disabled: nothing here needs ingress or a
    # LoadBalancer, and servicelb would bind host ports on every reviewer's machine.
    k3d cluster create "$CLUSTER" --image "$K3S_IMAGE" --agents 2 \
      --k3s-node-label "${POOL_LABEL}=datacenter@agent:0" \
      --k3s-node-label "${POOL_LABEL}=cloud@agent:1" \
      --k3s-arg "--disable=traefik@server:*" \
      --k3s-arg "--disable=servicelb@server:*" \
      --kubeconfig-update-default=false --kubeconfig-switch-context=false \
      --wait
  fi
  mkdir -p "$(dirname "$KUBECONFIG")"
  (umask 077 && k3d kubeconfig get "$CLUSTER" > "$KUBECONFIG")
}

# Gate on readiness before anything depends on the cluster. A DNS lookup failing
# on a young cluster looks exactly like a NetworkPolicy block.
gate_ready() {
  local i
  for i in $(seq 1 60); do
    [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge 3 ] && break
    sleep 1
  done
  kubectl wait --for=condition=Ready node --all --timeout=120s
  kubectl -n kube-system rollout status deploy/coredns --timeout=120s
  for i in $(seq 1 60); do
    [ -n "$(kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns \
      -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null)" ] && return 0
    sleep 1
  done
  die "kube-dns has no endpoints after 60s"
}

# Fake GPUs: an extended resource on each pool node's status. It lives on the
# Node object, so it survives a kubelet or container restart but is lost when the
# Node object is recreated. Replacements are why this runs on every create.
advertise_fake_gpus() {
  local node i
  for node in $(kubectl get nodes -l "$POOL_LABEL" -o name); do
    kubectl patch "$node" --subresource=status --type=json \
      -p "[{\"op\":\"add\",\"path\":\"/status/capacity/nvidia.com~1gpu\",\"value\":\"${GPUS_PER_NODE}\"}]" >/dev/null
  done
  # The patch sets capacity; the kubelet copies it into allocatable, which is
  # what the scheduler reads, on its next status sync. Wait for that.
  for i in $(seq 1 60); do
    [ "$(kubectl get nodes -l "$POOL_LABEL" -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}')" = \
      "$GPUS_PER_NODE $GPUS_PER_NODE" ] && break
    [ "$i" = 60 ] && die "nvidia.com/gpu never became allocatable"
    sleep 1
  done
  kubectl get nodes -L "$POOL_LABEL" \
    -o custom-columns='NODE:.metadata.name,POOL:.metadata.labels.platform\.example\.com/compute-pool,GPU:.status.allocatable.nvidia\.com/gpu'
}

onboard_all() {
  local spec
  for spec in "$SLICE_DIR"/tenants/*.yaml; do
    onboard "$spec"
  done
}

say "cluster";          create_cluster
assert_context
say "readiness gate";   gate_ready
say "fake GPUs";        advertise_fake_gpus
say "platform objects"; kubectl apply -f "$SLICE_DIR/platform/"
say "tenants";          onboard_all
say "up. next: make verify"
