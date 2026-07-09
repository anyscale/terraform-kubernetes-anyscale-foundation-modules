#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env/aws_efa_uccl_env.sh"

EXPECTED_GPUS=${EXPECTED_GPUS:-8}
EXPECTED_EFA_DEVICES=${EXPECTED_EFA_DEVICES:-}

section() {
  printf '\n== %s ==\n' "$1"
}

section "Host"
hostname

section "GPU Devices"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi not found. If this is the CPU head node, run validate_compute_nodes.sh from the head to validate all compute nodes." >&2
  exit 127
fi
nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv,noheader |
  awk -F', *' '{printf "GPU%-2s  %-24s  pci=%s\n", $1, $2, tolower($3)}'
gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l | tr -d ' ')
echo "GPU count: ${gpu_count}"
if [ "$gpu_count" -lt "$EXPECTED_GPUS" ]; then
  echo "Expected at least ${EXPECTED_GPUS} GPUs, found ${gpu_count}" >&2
  exit 1
fi

section "GPU Topology"
nvidia-smi topo -m | sed -r 's/\x1B\[[0-9;]*[[:alpha:]]//g' | sed -n '1,14p'

section "EFA / RDMA Devices"
if [ ! -d /sys/class/infiniband ]; then
  echo "/sys/class/infiniband not found" >&2
  exit 1
fi

tmp_nics=$(mktemp)
trap 'rm -f "$tmp_nics" /tmp/fi_info_efa.out' EXIT
printf '%-14s %-14s %-6s %s\n' "rdma_dev" "pci" "numa" "netdev"
for d in /sys/class/infiniband/*; do
  [ -e "$d" ] || continue
  dev=$(basename "$d")
  pci=$(basename "$(readlink -f "$d/device")")
  numa=$(cat "$d/device/numa_node" 2>/dev/null || echo NA)
  netdevs="none"
  if [ -d "$d/device/net" ]; then
    netdevs=$(ls "$d/device/net" 2>/dev/null | paste -sd, -)
    [ -n "$netdevs" ] || netdevs="none"
  fi
  printf '%-14s %-14s %-6s %s\n' "$dev" "$pci" "$numa" "$netdevs" >>"$tmp_nics"
done
sort -k2,2 "$tmp_nics"

efa_count=$(awk '$1 ~ /^(rdmap|efa)/ {count++} END {print count+0}' "$tmp_nics")
echo "EFA-like RDMA device count: ${efa_count}"
if [ "$efa_count" -lt 1 ]; then
  echo "Expected at least one EFA-like RDMA device, found ${efa_count}" >&2
  exit 1
fi
if [ -n "$EXPECTED_EFA_DEVICES" ] && [ "$efa_count" -lt "$EXPECTED_EFA_DEVICES" ]; then
  echo "Expected at least ${EXPECTED_EFA_DEVICES} EFA-like RDMA devices, found ${efa_count}" >&2
  exit 1
fi
if [ -z "$EXPECTED_EFA_DEVICES" ]; then
  echo "EXPECTED_EFA_DEVICES is not set; skipping minimum EFA count check."
fi

section "libfabric EFA Provider"
if command -v fi_info >/dev/null 2>&1; then
  fi_info -p efa >/tmp/fi_info_efa.out
  sed -n '1,40p' /tmp/fi_info_efa.out
else
  echo "fi_info not found" >&2
  exit 1
fi

section "ibv_devices"
if command -v ibv_devices >/dev/null 2>&1; then
  ibv_devices | sed -n '1,80p'
else
  echo "ibv_devices not found" >&2
  exit 1
fi

section "Environment"
env | grep -E '^(LD_LIBRARY_PATH|FI_|NCCL_|GLOO_SOCKET_IFNAME|UCCL_SOCKET_IFNAME|CUDA_VISIBLE_DEVICES|OMP_NUM_THREADS)=' | sort

echo
echo "EFA device validation passed"
