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

PROJECT=${PROJECT:?Set PROJECT to your Google Cloud project ID}
REGION=${REGION:?Set REGION to the GKE region}
CLUSTER=${CLUSTER:?Set CLUSTER to the GKE cluster name}
POOL=${POOL:-a4-spot}
WAIT_SECONDS=${WAIT_SECONDS:-1800}
SLEEP_SECONDS=${SLEEP_SECONDS:-30}
DELETE_A4_POOL=${DELETE_A4_POOL:-false}

target_fragment="clusters/${CLUSTER}/nodePools/${POOL}"
deadline=$((SECONDS + WAIT_SECONDS))

echo "Project: ${PROJECT}"
echo "Region:  ${REGION}"
echo "Cluster: ${CLUSTER}"
echo "Pool:    ${POOL}"
echo

while true; do
  running_ops=$(
    gcloud container operations list \
      --project="$PROJECT" \
      --location="$REGION" \
      --filter="status=RUNNING AND targetLink~${target_fragment}" \
      --format='value(name)' || true
  )

  if [ -z "$running_ops" ]; then
    break
  fi

  echo "Waiting for GKE operation(s) to unlock ${POOL}:"
  echo "$running_ops" | sed 's/^/  /'

  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "Timed out waiting after ${WAIT_SECONDS}s. Re-run this script later." >&2
    exit 124
  fi
  sleep "$SLEEP_SECONDS"
done

if ! gcloud container node-pools describe "$POOL" \
  --project="$PROJECT" \
  --cluster="$CLUSTER" \
  --location="$REGION" >/dev/null 2>&1; then
  echo "Node pool ${POOL} is already absent."
  exit 0
fi

if [ "$DELETE_A4_POOL" != "true" ]; then
  cat <<EOF
Node pool ${POOL} exists and is no longer locked by a running operation.

Deletion is intentionally opt-in. To delete this test GPU pool, run:

  DELETE_A4_POOL=true PROJECT=${PROJECT} REGION=${REGION} CLUSTER=${CLUSTER} POOL=${POOL} bash scripts/delete-a4-pool-when-unlocked.sh
EOF
  exit 2
fi

gcloud container node-pools delete "$POOL" \
  --project="$PROJECT" \
  --cluster="$CLUSTER" \
  --location="$REGION" \
  --quiet
