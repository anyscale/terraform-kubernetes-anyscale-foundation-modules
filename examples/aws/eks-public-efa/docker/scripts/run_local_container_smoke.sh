#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

IMAGE=${IMAGE:-}
DOCKER=${DOCKER:-docker}
HOST_EFA_DIR=${HOST_EFA_DIR:-/path/to/efa}
CONTAINER_EFA_DIR=${CONTAINER_EFA_DIR:-/workspace/efa}
MOUNT_HOST_EFA_STACK=${MOUNT_HOST_EFA_STACK:-1}
EXTRA_DOCKER_ARGS=${EXTRA_DOCKER_ARGS:-}

if [ -z "$IMAGE" ]; then
  echo "Set IMAGE=<container-image> before running this script" >&2
  exit 2
fi

efa_mounts=()
if [ "$MOUNT_HOST_EFA_STACK" = "1" ]; then
  efa_mounts+=(-v /opt/amazon/efa:/opt/amazon/efa:ro)
  efa_mounts+=(-v /opt/amazon/ofi-nccl:/opt/amazon/ofi-nccl:ro)
fi

# EXTRA_DOCKER_ARGS is intentionally split by the shell for operator-provided
# flags such as: EXTRA_DOCKER_ARGS="--privileged --name efa-smoke"
# shellcheck disable=SC2206
extra_args=($EXTRA_DOCKER_ARGS)

$DOCKER run --rm \
  --gpus all \
  --network host \
  --ipc host \
  --ulimit memlock=-1:-1 \
  --device /dev/infiniband \
  "${efa_mounts[@]}" \
  -v "${HOST_EFA_DIR}:${CONTAINER_EFA_DIR}:ro" \
  "${extra_args[@]}" \
  -e NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-eth0}" \
  -e GLOO_SOCKET_IFNAME="${GLOO_SOCKET_IFNAME:-eth0}" \
  -e UCCL_SOCKET_IFNAME="${UCCL_SOCKET_IFNAME:-eth0}" \
  -e FI_PROVIDER="${FI_PROVIDER:-efa}" \
  -e FI_EFA_USE_DEVICE_RDMA="${FI_EFA_USE_DEVICE_RDMA:-1}" \
  "$IMAGE" \
  bash /opt/efa-middle/scripts/validate_middle_layer_local.sh
