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

gcloud container clusters get-credentials "$CLUSTER" --location="$REGION" --project="$PROJECT"

echo "== Nodes =="
kubectl get nodes \
  -L cloud.google.com/gke-nodepool,cloud.google.com/gke-spot,cloud.google.com/gke-accelerator \
  -o custom-columns=NAME:.metadata.name,POOL:.metadata.labels.cloud\\.google\\.com/gke-nodepool,SPOT:.metadata.labels.cloud\\.google\\.com/gke-spot,ACCEL:.metadata.labels.cloud\\.google\\.com/gke-accelerator,GPUS:.status.allocatable.nvidia\\.com/gpu

echo
echo "== Pods =="
kubectl get pods -o wide

for pod in ray-worker-0 ray-worker-1; do
  echo
  echo "== ${pod} device check =="
  kubectl exec "$pod" -- bash -lc '
    set -euo pipefail
    echo "hostname=$(hostname)"
    echo "gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l | tr -d " ")"
    for iface in eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9; do
      test -d "/sys/class/net/${iface}"
      printf "%s mtu=%s state=%s\n" \
        "$iface" \
        "$(cat "/sys/class/net/${iface}/mtu")" \
        "$(cat "/sys/class/net/${iface}/operstate")"
    done
    test -x /usr/local/gib/scripts/set_nccl_env.sh
    source /usr/local/gib/scripts/set_nccl_env.sh
    env | grep -E "^(NCCL_|LD_LIBRARY_PATH)" | sort
    grep -q "^gdrdrv " /proc/modules
    grep -q "[[:space:]]gdrdrv$" /proc/devices
    test -c /dev/gdrdrv
    ls -l /dev/gdrdrv
    ls /sys/class/infiniband | sort
  '
done

echo
echo "Cluster readiness validation passed."
