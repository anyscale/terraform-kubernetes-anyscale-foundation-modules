#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

ACTION=${1:-all}

NODE0=${NODE0:-}
NODE1=${NODE1:-}
SSH_PORT=${SSH_PORT:-2222}
IMAGE=${IMAGE:-}
DOCKER=${DOCKER:-docker}
LOG_DIR=${LOG_DIR:-/tmp/efa-middle-layer-validation}
HOST_EFA_DIR=${HOST_EFA_DIR:-/path/to/efa}
CONTAINER_EFA_DIR=${CONTAINER_EFA_DIR:-/workspace/efa}
EXTRA_DOCKER_ARGS=${EXTRA_DOCKER_ARGS:-}
MOUNT_HOST_EFA_STACK=${MOUNT_HOST_EFA_STACK:-1}

if [ -z "$IMAGE" ]; then
  echo "Set IMAGE=<container-image> before running this script" >&2
  exit 2
fi
if [ -z "$NODE0" ] || [ -z "$NODE1" ]; then
  echo "Set NODE0=<host-or-ip> and NODE1=<host-or-ip> before running this script" >&2
  exit 2
fi

mkdir -p "$LOG_DIR"

wait_for_pair() {
  local pid0=$1
  local pid1=$2
  local status=0
  wait "$pid0" || status=$?
  wait "$pid1" || status=$?
  return "$status"
}

container_prefix() {
  local node_rank=$1
  local efa_mounts=""
  if [ "$MOUNT_HOST_EFA_STACK" = "1" ]; then
    efa_mounts="\
  -v /opt/amazon/efa:/opt/amazon/efa:ro \
  -v /opt/amazon/ofi-nccl:/opt/amazon/ofi-nccl:ro"
  fi
  cat <<EOF
$DOCKER run --rm \
  --gpus all \
  --network host \
  --ipc host \
  --ulimit memlock=-1:-1 \
  --device /dev/infiniband \
  ${efa_mounts} \
  -v ${HOST_EFA_DIR}:${CONTAINER_EFA_DIR}:ro \
  ${EXTRA_DOCKER_ARGS} \
  -e NNODES=2 \
  -e NODE_RANK=${node_rank} \
  -e MASTER_ADDR=${NODE0} \
  -e NPROC_PER_NODE=8 \
  -e NCCL_SOCKET_IFNAME=eth0 \
  -e GLOO_SOCKET_IFNAME=eth0 \
  -e UCCL_SOCKET_IFNAME=eth0 \
  -e FI_PROVIDER=efa \
  -e FI_EFA_USE_DEVICE_RDMA=1 \
  "$IMAGE"
EOF
}

remote_cmd() {
  local node_rank=$1
  local action=$2
  local prefix
  prefix=$(container_prefix "$node_rank")

  case "$action" in
    devices)
      echo "$prefix bash /opt/efa-middle/scripts/validate_efa_devices.sh"
      ;;
    imports)
      echo "$prefix bash /opt/efa-middle/scripts/validate_uccl_imports.sh"
      ;;
    nccl)
      echo "Ray all-reduce must be run from the Ray head with validate_compute_nodes.py all-reduce" >&2
      exit 2
      ;;
    ll)
      echo "$prefix bash /opt/efa-middle/scripts/validate_uccl_ep.sh ll"
      ;;
    ht)
      echo "$prefix bash /opt/efa-middle/scripts/validate_uccl_ep.sh ht"
      ;;
    local)
      echo "$prefix bash /opt/efa-middle/scripts/validate_middle_layer_local.sh"
      ;;
    *)
      echo "unknown action $action" >&2
      exit 2
      ;;
  esac
}

run_pair() {
  local action=$1
  echo "Running container validation action=$action image=$IMAGE"
  ssh -p "$SSH_PORT" "$NODE0" "$(remote_cmd 0 "$action")" >"$LOG_DIR/${action}_node0.log" 2>&1 &
  local pid0=$!
  ssh -p "$SSH_PORT" "$NODE1" "$(remote_cmd 1 "$action")" >"$LOG_DIR/${action}_node1.log" 2>&1 &
  local pid1=$!
  wait_for_pair "$pid0" "$pid1"
  echo "Logs:"
  echo "  $LOG_DIR/${action}_node0.log"
  echo "  $LOG_DIR/${action}_node1.log"
}

case "$ACTION" in
  devices|imports|ll|ht|local)
    run_pair "$ACTION"
    ;;
  nccl)
    echo "Ray all-reduce must be run from the Ray head with validate_compute_nodes.py all-reduce" >&2
    exit 2
    ;;
  all)
    run_pair devices
    run_pair imports
    run_pair ll
    run_pair ht
    ;;
  *)
    echo "Usage: IMAGE=<image> NODE0=<host> NODE1=<host> $0 all|local|devices|imports|ll|ht" >&2
    exit 2
    ;;
esac
