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
MODE=${1:-${MODE:-ll}}
POD0=${POD0:-ray-worker-0}
POD1=${POD1:-ray-worker-1}
PYTHON=${PYTHON:-/workspace/rayenv/.venv/bin/python}
NPROC_PER_NODE=${NPROC_PER_NODE:-8}
TIMEOUT=${TIMEOUT:-300s}

case "$MODE" in
  ll)
    MASTER_PORT=${MASTER_PORT:-6423}
    TOKEN_ENV="LL_TOKENS=${LL_TOKENS:-128}"
    SUMMARY_PATTERN="All correctness tests passed|Dispatch|Combine|Destination ctx missing"
    ;;
  ht)
    MASTER_PORT=${MASTER_PORT:-6424}
    TOKEN_ENV="HT_TOKENS=${HT_TOKENS:-4096}"
    SUMMARY_PATTERN="All correctness tests passed|Best dispatch|Best combine|Destination ctx missing"
    ;;
  *)
    echo "Usage: $0 [ll|ht]" >&2
    exit 2
    ;;
esac

gcloud container clusters get-credentials "$CLUSTER" --location="$REGION" --project="$PROJECT"

MASTER_ADDR=$(kubectl get pod "$POD0" -o jsonpath='{.status.podIP}')
LOG0=${LOG0:-/tmp/uccl-${MODE}-r0.log}
LOG1=${LOG1:-/tmp/uccl-${MODE}-r1.log}
rm -f "$LOG0" "$LOG1"

run_rank() {
  local pod=$1
  local rank=$2
  local log=$3

  kubectl exec "$pod" -- bash -lc \
    "PATH=$(dirname "$PYTHON"):\$PATH \
     PYTHON=$PYTHON \
     NNODES=2 NPROC_PER_NODE=$NPROC_PER_NODE NODE_RANK=$rank \
     MASTER_ADDR=$MASTER_ADDR MASTER_PORT=$MASTER_PORT $TOKEN_ENV \
     timeout $TIMEOUT /opt/gcp-middle/scripts/validate_uccl_ep.sh $MODE" \
    >"$log" 2>&1 &
}

run_rank "$POD0" 0 "$LOG0"
pid0=$!
sleep 5
run_rank "$POD1" 1 "$LOG1"
pid1=$!

wait "$pid0"; s0=$?
wait "$pid1"; s1=$?
echo "rank0_status=$s0 rank1_status=$s1"
echo "rank0_log=$LOG0"
echo "rank1_log=$LOG1"

echo
echo "== rank0 summary =="
grep -E "$SUMMARY_PATTERN" "$LOG0" || true
tail -80 "$LOG0"

echo
echo "== rank1 summary =="
grep -E "$SUMMARY_PATTERN" "$LOG1" || true
tail -80 "$LOG1"

if [ "$s0" != "0" ] || [ "$s1" != "0" ]; then
  exit 1
fi
