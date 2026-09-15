#!/usr/bin/env bash
set -euo pipefail

GCLOUD=${GCLOUD:-}
if [ -z "$GCLOUD" ]; then
  if command -v gcloud >/dev/null 2>&1; then
    GCLOUD=$(command -v gcloud)
  else
    echo "gcloud not found; set GCLOUD=/path/to/gcloud" >&2
    exit 127
  fi
fi
gcloud() { "$GCLOUD" "$@"; }
export PATH="$(dirname "$GCLOUD"):$PATH"

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROJECT=${PROJECT:?Set PROJECT to your Google Cloud project ID}
REGION=${REGION:?Set REGION to the GKE region}
CLUSTER=${CLUSTER:?Set CLUSTER to the GKE cluster name}

gcloud container clusters get-credentials "$CLUSTER" --location="$REGION" --project="$PROJECT"

bash "$ROOT/scripts/render-network-objects.sh" | kubectl apply -f -

kubectl apply -f \
  https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/refs/heads/master/gpudirect-rdma/nccl-rdma-installer.yaml
kubectl rollout status daemonset/nccl-rdma-installer -n kube-system --timeout=10m

kubectl apply -f "$ROOT/manifests/gdrdrv-loader-daemonset.yaml"
kubectl rollout status daemonset/gdrdrv-loader -n kube-system --timeout=10m

kubectl apply -f "$ROOT/manifests/ray-head.yaml"
kubectl apply -f "$ROOT/manifests/ray-workers-2.yaml"
kubectl wait --for=condition=Ready pod/ray-head --timeout=10m
kubectl wait --for=condition=Ready pod -l app=ray,role=worker --timeout=15m

kubectl get pods -o wide
