#!/usr/bin/env bash
# One command down. Deletes only this slice's cluster and its pinned kubeconfig.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

k3d cluster delete "$CLUSTER"
rm -f "$KUBECONFIG"
say "down. removed cluster $CLUSTER and $KUBECONFIG"
