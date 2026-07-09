#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

DOCKER=${DOCKER:-docker}
BASE_IMAGE=${BASE_IMAGE:-}
IMAGE=${IMAGE:-aws-efa-uccl-middle:dev}
DOCKERFILE=${DOCKERFILE:-Dockerfile.aws-efa-uccl.fragment}
EFA_INSTALLER_VERSION=${EFA_INSTALLER_VERSION:-1.43.2}
AWS_OFI_NCCL_VERSION=${AWS_OFI_NCCL_VERSION:-1.19.2}
AWS_OFI_NCCL_SHA512=${AWS_OFI_NCCL_SHA512:-ec578da632166fd7f885dbc8cfa3f07be19a056276a2bd82a6868fe78160f2df07338068ef1bf5367fd3e81d9b06016fc546e3ea673566ed787e3be49438bf80}
UCCL_URL=${UCCL_URL:-https://github.com/uccl-project/uccl.git}
UCCL_REF=${UCCL_REF:-v0.1.1}
RAY_ALL_REDUCE_BENCH_URL=${RAY_ALL_REDUCE_BENCH_URL:-https://gist.githubusercontent.com/SumanthRH/d92ca3f690ece64d407423073a169fdf/raw/3b062b14ba597730855c0f14a306001cb2ed7a0e/all_reduce_bench.py}

if [ -z "$BASE_IMAGE" ]; then
  cat >&2 <<EOF
Set BASE_IMAGE before building.

Example:
  BASE_IMAGE=<anyscale-or-vllm-cuda-image> \\
  IMAGE=${IMAGE} \\
  DOCKER="sudo docker" \\
  $0
EOF
  exit 2
fi

cd "$ROOT_DIR"
echo "Building ${IMAGE}"
echo "BASE_IMAGE=${BASE_IMAGE}"
echo "AWS_OFI_NCCL_VERSION=${AWS_OFI_NCCL_VERSION}"
echo "UCCL_REF=${UCCL_REF}"

$DOCKER build \
  -f "$DOCKERFILE" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "EFA_INSTALLER_VERSION=${EFA_INSTALLER_VERSION}" \
  --build-arg "AWS_OFI_NCCL_VERSION=${AWS_OFI_NCCL_VERSION}" \
  --build-arg "AWS_OFI_NCCL_SHA512=${AWS_OFI_NCCL_SHA512}" \
  --build-arg "UCCL_URL=${UCCL_URL}" \
  --build-arg "UCCL_REF=${UCCL_REF}" \
  --build-arg "RAY_ALL_REDUCE_BENCH_URL=${RAY_ALL_REDUCE_BENCH_URL}" \
  -t "$IMAGE" \
  .
