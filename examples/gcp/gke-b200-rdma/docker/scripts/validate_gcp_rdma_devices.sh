#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env/gcp_rdma_uccl_env.sh"

EXPECTED_GPUS=${EXPECTED_GPUS:-8}
EXPECTED_RDMA_DEVICES=${EXPECTED_RDMA_DEVICES:-8}
EXPECT_GDRDRV=${EXPECT_GDRDRV:-1}

section() {
  printf '\n== %s ==\n' "$1"
}

section "Host"
hostname

section "GPU Devices"
nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv,noheader |
  awk -F', *' '{printf "GPU%-2s  %-24s  pci=%s\n", $1, $2, tolower($3)}'
gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l | tr -d ' ')
echo "GPU count: ${gpu_count}"
if [ "$gpu_count" -lt "$EXPECTED_GPUS" ]; then
  echo "Expected at least ${EXPECTED_GPUS} GPUs, found ${gpu_count}" >&2
  exit 1
fi

section "RDMA Interfaces"
for iface in eth2 eth3 eth4 eth5 eth6 eth7 eth8 eth9; do
  ip -br addr show "$iface"
done

section "Infiniband Devices"
if [ ! -d /sys/class/infiniband ]; then
  echo "/sys/class/infiniband not found" >&2
  exit 1
fi
for dev in /sys/class/infiniband/*; do
  [ -e "$dev" ] || continue
  basename "$dev"
done | sort
rdma_count=$(find /sys/class/infiniband -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
echo "RDMA device count: ${rdma_count}"
if [ "$rdma_count" -lt "$EXPECTED_RDMA_DEVICES" ]; then
  echo "Expected at least ${EXPECTED_RDMA_DEVICES} RDMA devices, found ${rdma_count}" >&2
  exit 1
fi

section "gIB"
test -x /usr/local/gib/scripts/set_nccl_env.sh
env | grep -E '^(LD_LIBRARY_PATH|NCCL_|GLOO_SOCKET_IFNAME|UCCL_SOCKET_IFNAME|CUDA_VISIBLE_DEVICES|USE_DMABUF|PER_EXPERT_BATCHING)=' | sort

section "gdrdrv"
if [ "$EXPECT_GDRDRV" = "1" ]; then
  grep -q '^gdrdrv ' /proc/modules
  grep -q '[[:space:]]gdrdrv$' /proc/devices
  test -c /dev/gdrdrv
  ls -l /dev/gdrdrv
else
  ls -l /dev/gdrdrv 2>/dev/null || true
fi

section "ibv_devices"
if command -v ibv_devices >/dev/null 2>&1; then
  ibv_devices | sed -n '1,80p'
else
  echo "ibv_devices not found" >&2
  exit 1
fi

echo
echo "GCP RDMA device validation passed"
