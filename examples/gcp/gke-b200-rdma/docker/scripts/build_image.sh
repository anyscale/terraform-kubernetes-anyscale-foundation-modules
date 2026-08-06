#!/usr/bin/env bash
set -euo pipefail

DOCKER=${DOCKER:-docker}
BASE_IMAGE=${BASE_IMAGE:-nvcr.io/nvidia/pytorch:25.04-py3}
IMAGE=${IMAGE:-gcp-b200-rdma-uccl:dev}

cd "$(dirname "$0")/.."

"$DOCKER" build \
  -f Dockerfile.gcp-rdma-uccl.fragment \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  -t "$IMAGE" \
  .
