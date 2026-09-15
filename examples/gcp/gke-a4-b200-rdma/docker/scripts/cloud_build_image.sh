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
REGION=${REGION:-us-central1}
REPOSITORY=${REPOSITORY:-gcp-rdma-uccl}
IMAGE_NAME=${IMAGE_NAME:-gcp-rdma-uccl}
TAG=${TAG:-dev}
BASE_IMAGE=${BASE_IMAGE:-nvcr.io/nvidia/pytorch:25.04-py3}
IMAGE=${IMAGE:-${REGION}-docker.pkg.dev/${PROJECT}/${REPOSITORY}/${IMAGE_NAME}:${TAG}}

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

gcloud services enable cloudbuild.googleapis.com artifactregistry.googleapis.com \
  --project="$PROJECT"

if ! gcloud artifacts repositories describe "$REPOSITORY" \
  --project="$PROJECT" \
  --location="$REGION" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$REPOSITORY" \
    --project="$PROJECT" \
    --location="$REGION" \
    --repository-format=docker \
    --description="GKE B200 RDMA/UCCL images"
fi

gcloud builds submit "$ROOT" \
  --project="$PROJECT" \
  --config="$ROOT/cloudbuild.yaml" \
  --machine-type=e2-highcpu-32 \
  --disk-size=300 \
  --substitutions="_BASE_IMAGE=${BASE_IMAGE},_IMAGE=${IMAGE}"

echo "$IMAGE"
