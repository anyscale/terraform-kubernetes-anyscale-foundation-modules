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
ZONE=${ZONE:?Set ZONE to the A4/B200 worker zone}
CLUSTER=${CLUSTER:?Set CLUSTER to the GKE cluster name}
ALLOW_EXISTING_CLUSTER=${ALLOW_EXISTING_CLUSTER:-0}

echo "Project: ${PROJECT}"
echo "Region:  ${REGION}"
echo "Zone:    ${ZONE}"
echo "Cluster: ${CLUSTER}"

for tool in terraform kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: ${tool}" >&2
    exit 1
  fi
done
if ! command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
  echo "Missing required tool: gke-gcloud-auth-plugin" >&2
  echo "It is usually in the same Google Cloud SDK bin directory as gcloud." >&2
  exit 1
fi
echo "gcloud: ${GCLOUD}"

# Terraform authenticates with Application Default Credentials (ADC), which are
# separate from the gcloud user login. Without them, terraform fails at apply.
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]; then
  echo "ADC: GOOGLE_APPLICATION_CREDENTIALS=${GOOGLE_APPLICATION_CREDENTIALS}"
elif [ -f "${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json" ]; then
  echo "ADC: application_default_credentials.json present"
else
  echo "Missing Application Default Credentials (needed by Terraform)." >&2
  echo "Run: gcloud auth application-default login" >&2
  echo "Then: gcloud auth application-default set-quota-project ${PROJECT}" >&2
  exit 1
fi

echo
echo "Existing GKE clusters:"
gcloud container clusters list --project="$PROJECT" \
  --format='table(name,location,status,currentMasterVersion)'

echo
echo "Planned cluster collision check:"
if gcloud container clusters describe "$CLUSTER" --location="$REGION" --project="$PROJECT" >/dev/null 2>&1; then
  if [ "$ALLOW_EXISTING_CLUSTER" != "1" ]; then
    echo "Cluster ${CLUSTER} already exists in ${REGION}" >&2
    echo "Set ALLOW_EXISTING_CLUSTER=1 when intentionally rebuilding node pools on an existing control plane." >&2
    exit 1
  fi
  echo "Cluster ${CLUSTER} already exists in ${REGION}; ALLOW_EXISTING_CLUSTER=1 so this is treated as an intentional reuse."
  echo
  echo "Existing node pools for ${CLUSTER}:"
  gcloud container node-pools list \
    --cluster="$CLUSTER" \
    --region="$REGION" \
    --project="$PROJECT" \
    --format='table(name,status,version,config.machineType,autoscaling.enabled,initialNodeCount)' || true
else
  echo "No cluster named ${CLUSTER} exists in ${REGION}."
fi

echo
echo "VPC networks quota check (module creates 2 new VPCs: gVNIC + RDMA):"
NET_COUNT=$(gcloud compute networks list --project="$PROJECT" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')
NET_LIMIT=$(gcloud compute project-info describe --project="$PROJECT" \
  --format='value(quotas.filter("metric:NETWORKS").extract("limit").flatten())' 2>/dev/null | head -1)
NET_LIMIT=${NET_LIMIT:-30}
echo "  networks in use: ${NET_COUNT} / limit ${NET_LIMIT%.*}"
if [ "$NET_COUNT" -gt $(( ${NET_LIMIT%.*} - 2 )) ]; then
  echo "  WARNING: fewer than 2 free network slots; terraform apply will fail with 'Quota NETWORKS exceeded'." >&2
  echo "  Raise the NETWORKS quota (Cloud Quotas API / console) or free unused VPC networks before applying." >&2
fi

echo
echo "A4/B200 Spot usage by region (QUOTA HEURISTIC, assumes 64-GPU/8-node quota):"
echo "  NOTE: this is a quota estimate from running-node counts, NOT live spot"
echo "  capacity. A zone can show headroom here yet fail with GCE_STOCKOUT."
echo "  Run scripts/probe-b200-capacity.sh to find zones with real capacity now."
gcloud compute instances list --project="$PROJECT" \
  --filter='machineType:a4-highgpu-8g AND status=RUNNING' \
  --format='value(zone)' |
awk '{
  split($1, a, "-");
  region = a[1] "-" a[2];
  count[region]++;
}
END {
  for (r in count) {
    printf "%s %d running_nodes %d_used_B200_GPUs %d_remaining_nodes_by_64_gpu_quota\n", r, count[r], count[r] * 8, 8 - count[r];
  }
}' | sort

echo
echo "Safety: this workflow targets only the configured GKE cluster and node pools."
