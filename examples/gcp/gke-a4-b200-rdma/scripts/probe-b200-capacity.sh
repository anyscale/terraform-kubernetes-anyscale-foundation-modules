#!/usr/bin/env bash
# Probe live A4/B200 spot capacity across RoCE-capable zones.
#
# GKE node-pool creation retries a stocked-out zone for ~35 minutes before it
# fails, so blindly picking a zone can cost 30+ minutes per miss. This helper
# fires short-lived spot VM create attempts that fail in seconds on STOCKOUT or
# QUOTA and are deleted immediately on success, so you can pick a zone with real
# capacity BEFORE running terraform.
#
# It changes no long-lived resources: any probe VM that provisions is deleted.
#
# Output ends with a "ZONES WITH CAPACITY" list. Present that list to the user
# and let them choose the target zone; do not silently pick one.
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
MACHINE_TYPE=${MACHINE_TYPE:-a4-highgpu-8g}
PROVISIONING_MODEL=${PROVISIONING_MODEL:-SPOT}
PROBE_NETWORK=${PROBE_NETWORK:-default}
PROBE_IMAGE_FAMILY=${PROBE_IMAGE_FAMILY:-debian-12}
PROBE_IMAGE_PROJECT=${PROBE_IMAGE_PROJECT:-debian-cloud}

# ZONES: space-separated override. Default: every zone that has a matching
# "<zone>-vpc-roce" network profile (i.e. supports B200 GPUDirect RDMA).
ZONES=${ZONES:-}
if [ -z "$ZONES" ]; then
  echo "Deriving RoCE-capable zones from network profiles..."
  ZONES=$(gcloud compute network-profiles list --project="$PROJECT" \
    --format='value(name)' 2>/dev/null \
    | grep -- '-vpc-roce$' | sed 's/-vpc-roce$//' | sort -u | tr '\n' ' ')
fi

if [ -z "${ZONES// /}" ]; then
  echo "No candidate zones. Set ZONES=\"us-west3-c us-east1-b ...\"" >&2
  exit 1
fi

echo "Project:            ${PROJECT}"
echo "Machine type:       ${MACHINE_TYPE}"
echo "Provisioning model: ${PROVISIONING_MODEL}"
echo "Candidate zones:    ${ZONES}"
echo
echo "NOTE: this reflects capacity at this instant; spot capacity can change."
echo

AVAILABLE=()
for Z in $ZONES; do
  NAME="probe-b200-${Z}-$$"
  OUT=$(gcloud compute instances create "$NAME" \
    --project="$PROJECT" --zone="$Z" \
    --machine-type="$MACHINE_TYPE" \
    --provisioning-model="$PROVISIONING_MODEL" --instance-termination-action=DELETE \
    --maintenance-policy=TERMINATE --no-address --network="$PROBE_NETWORK" \
    --image-family="$PROBE_IMAGE_FAMILY" --image-project="$PROBE_IMAGE_PROJECT" \
    --boot-disk-size=50GB 2>&1 || true)

  if echo "$OUT" | grep -qiE 'STOCKOUT|does not have enough resources'; then
    printf '  %-20s STOCKOUT\n' "$Z"
  elif echo "$OUT" | grep -qiE 'Quota .*exceeded|quota'; then
    printf '  %-20s QUOTA_EXCEEDED\n' "$Z"
  elif echo "$OUT" | grep -qiE "does not have machine type|Invalid value for field 'resource.machineType'"; then
    printf '  %-20s NO_%s\n' "$Z" "$MACHINE_TYPE"
  elif echo "$OUT" | grep -qiE "Created|instances/${NAME}"; then
    printf '  %-20s *** CAPACITY AVAILABLE ***\n' "$Z"
    AVAILABLE+=("$Z")
    gcloud compute instances delete "$NAME" --project="$PROJECT" --zone="$Z" --quiet >/dev/null 2>&1 \
      && printf '  %-20s (probe deleted)\n' "$Z" \
      || printf '  %-20s WARNING: could not delete probe %s\n' "$Z" "$NAME" >&2
  else
    printf '  %-20s OTHER: %s\n' "$Z" "$(echo "$OUT" | tail -1)"
  fi
done

echo
echo "ZONES WITH CAPACITY: ${AVAILABLE[*]:-none}"
if [ "${#AVAILABLE[@]}" -eq 0 ]; then
  echo "No zone had live ${PROVISIONING_MODEL} ${MACHINE_TYPE} capacity. Retry later or ask the user."
  exit 2
fi
echo "Present these to the user and let them choose the target zone before terraform apply."
