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
RELEASE=${RELEASE:-gke-b200-rdma-addons}
NAMESPACE=${NAMESPACE:-default}
GVNIC_NETWORK=${GVNIC_NETWORK:?Set GVNIC_NETWORK to the extra gVNIC network name}
GVNIC_SUBNET=${GVNIC_SUBNET:?Set GVNIC_SUBNET to the extra gVNIC subnet name}
RDMA_NETWORK=${RDMA_NETWORK:?Set RDMA_NETWORK to the RDMA network name}
RDMA_SUBNET_PREFIX=${RDMA_SUBNET_PREFIX:?Set RDMA_SUBNET_PREFIX to the RDMA subnet name prefix}
RESET_LOCAL_ADDONS=${RESET_LOCAL_ADDONS:-0}
network_names=(gvnic-1 rdma-0 rdma-1 rdma-2 rdma-3 rdma-4 rdma-5 rdma-6 rdma-7)

if ! command -v helm >/dev/null 2>&1; then
  echo "helm not found; install Helm or use scripts/install-addons.sh" >&2
  exit 127
fi

gcloud container clusters get-credentials "$CLUSTER" --location="$REGION" --project="$PROJECT"

if [ "$RESET_LOCAL_ADDONS" = "1" ]; then
  echo "RESET_LOCAL_ADDONS=1: removing local manifest/Helm-owned add-ons before reinstall."
  helm uninstall "$RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1 || true
  kubectl delete pod/ray-head --namespace="$NAMESPACE" --ignore-not-found --force --grace-period=0 --wait=false
  kubectl delete pod -l app=ray,role=worker --namespace="$NAMESPACE" --ignore-not-found --force --grace-period=0 --wait=false
  kubectl delete service/ray-head --namespace="$NAMESPACE" --ignore-not-found
  kubectl delete daemonset/gdrdrv-loader -n kube-system --ignore-not-found
  for name in "${network_names[@]}"; do
    kubectl delete network "$name" --ignore-not-found
  done
  for name in "${network_names[@]}"; do
    kubectl delete gkenetworkparamset "$name" --ignore-not-found
  done
fi

kubectl apply -f \
  https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/refs/heads/master/gpudirect-rdma/nccl-rdma-installer.yaml
kubectl rollout status daemonset/nccl-rdma-installer -n kube-system --timeout=10m

echo "Applying GKE Network objects before creating worker pods."
helm template "$RELEASE" "$ROOT/helm/gke-b200-rdma-addons" \
  --namespace "$NAMESPACE" \
  --show-only templates/network-objects.yaml \
  --set "gvnic.network=${GVNIC_NETWORK}" \
  --set "gvnic.subnet=${GVNIC_SUBNET}" \
  --set "rdma.network=${RDMA_NETWORK}" \
  --set "rdma.subnetPrefix=${RDMA_SUBNET_PREFIX}" |
  kubectl apply -f -

for name in "${network_names[@]}"; do
  kubectl get network "$name" >/dev/null
  kubectl get gkenetworkparamset "$name" >/dev/null
done

echo "Waiting briefly for GKE networking admission to observe Network objects."
sleep 10

helm upgrade --install "$RELEASE" "$ROOT/helm/gke-b200-rdma-addons" \
  --namespace "$NAMESPACE" \
  --set "gvnic.network=${GVNIC_NETWORK}" \
  --set "gvnic.subnet=${GVNIC_SUBNET}" \
  --set "rdma.network=${RDMA_NETWORK}" \
  --set "rdma.subnetPrefix=${RDMA_SUBNET_PREFIX}"

kubectl rollout status daemonset/gdrdrv-loader -n kube-system --timeout=10m
kubectl wait --for=condition=Ready pod/ray-head --namespace="$NAMESPACE" --timeout=10m
kubectl wait --for=condition=Ready pod -l app=ray,role=worker --namespace="$NAMESPACE" --timeout=15m
kubectl get pods --namespace="$NAMESPACE" -o wide
