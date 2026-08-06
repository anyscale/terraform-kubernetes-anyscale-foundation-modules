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

PROJECT=${PROJECT:?Set PROJECT to your Google Cloud project ID}
REGION=${REGION:?Set REGION to the GKE region}
CLUSTER=${CLUSTER:?Set CLUSTER to the GKE cluster name}
TEST_URL=${TEST_URL:-https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/refs/heads/master/gpudirect-rdma/nccl-test-a4.yaml}
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-default}
SUSPEND_RAY_WORKERS=${SUSPEND_RAY_WORKERS:-0}
RESTORE_RAY_WORKERS=${RESTORE_RAY_WORKERS:-$SUSPEND_RAY_WORKERS}
GVNIC_NETWORK=${GVNIC_NETWORK:?Set GVNIC_NETWORK to the extra gVNIC network name}
GVNIC_SUBNET=${GVNIC_SUBNET:?Set GVNIC_SUBNET to the extra gVNIC subnet name}
RDMA_NETWORK=${RDMA_NETWORK:?Set RDMA_NETWORK to the RDMA network name}
RDMA_SUBNET_PREFIX=${RDMA_SUBNET_PREFIX:?Set RDMA_SUBNET_PREFIX to the RDMA subnet name prefix}

gcloud container clusters get-credentials "$CLUSTER" --location="$REGION" --project="$PROJECT"

wait_for_no_ray_workers() {
  for _ in $(seq 1 120); do
    if ! kubectl get pod -l app=ray,role=worker --namespace="$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for Ray worker pods to disappear." >&2
  return 1
}

cleanup_nccl_test() {
  if [ "${DELETE_NCCL_TEST:-0}" = "1" ] || [ "$RESTORE_RAY_WORKERS" = "1" ]; then
    kubectl delete -f "$TEST_URL" --ignore-not-found >/dev/null 2>&1 || true
  fi
}

restore_ray_workers() {
  if [ "$RESTORE_RAY_WORKERS" = "1" ]; then
    echo "Restoring Ray workers with Helm add-on installer."
    PROJECT="$PROJECT" \
    REGION="$REGION" \
    CLUSTER="$CLUSTER" \
    NAMESPACE="$NAMESPACE" \
    GVNIC_NETWORK="$GVNIC_NETWORK" \
    GVNIC_SUBNET="$GVNIC_SUBNET" \
    RDMA_NETWORK="$RDMA_NETWORK" \
    RDMA_SUBNET_PREFIX="$RDMA_SUBNET_PREFIX" \
    bash "$ROOT/scripts/install-addons-helm.sh"
  fi
}

finish() {
  status=$?
  cleanup_nccl_test
  restore_ray_workers
  exit "$status"
}
trap finish EXIT

if [ "$SUSPEND_RAY_WORKERS" = "1" ]; then
  echo "Suspending Ray worker pods so NCCL test pods can reserve all A4 GPUs."
  kubectl delete pod -l app=ray,role=worker \
    --namespace="$NAMESPACE" \
    --ignore-not-found \
    --force \
    --grace-period=0 \
    --wait=false
  wait_for_no_ray_workers
fi

kubectl apply -f "$TEST_URL"
kubectl wait --for=condition=Ready pod/nccl-test-host-1 pod/nccl-test-host-2 --timeout=15m

echo "== all_gather =="
kubectl exec nccl-test-host-1 -- \
  /usr/local/gib/scripts/run_nccl_tests.sh \
    -t all_gather -b 1K -e 8G nccl-host-1 nccl-host-2

echo
echo "== all_reduce =="
kubectl exec nccl-test-host-1 -- \
  /usr/local/gib/scripts/run_nccl_tests.sh \
    -t all_reduce -b 1K -e 8G nccl-host-1 nccl-host-2
