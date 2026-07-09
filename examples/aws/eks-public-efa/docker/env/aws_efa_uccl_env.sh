#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

# Source this file inside the container before NCCL/UCCL/vLLM validation.

export EFA_HOME="${EFA_HOME:-/opt/amazon/efa}"
export OFI_NCCL_HOME="${OFI_NCCL_HOME:-/opt/amazon/ofi-nccl}"
export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"

if ! command -v python >/dev/null 2>&1 && [ -x /home/ray/anaconda3/bin/python ]; then
  export PATH="/home/ray/anaconda3/bin:${PATH}"
fi

export PATH="${CUDA_HOME}/bin:${EFA_HOME}/bin:${PATH}"

_torch_lib=""
if command -v python >/dev/null 2>&1; then
  _torch_lib="$(python - <<'PY' 2>/dev/null || true
import pathlib
import torch
print(pathlib.Path(torch.__file__).resolve().parent / "lib")
PY
)"
fi

if [ -n "$_torch_lib" ]; then
  export LD_LIBRARY_PATH="${EFA_HOME}/lib:${OFI_NCCL_HOME}/lib:${_torch_lib}:${LD_LIBRARY_PATH:-}"
else
  export LD_LIBRARY_PATH="${EFA_HOME}/lib:${OFI_NCCL_HOME}/lib:${LD_LIBRARY_PATH:-}"
fi

export FI_PROVIDER="${FI_PROVIDER:-efa}"
export FI_EFA_USE_DEVICE_RDMA="${FI_EFA_USE_DEVICE_RDMA:-1}"
export NCCL_NET_PLUGIN="${NCCL_NET_PLUGIN:-libnccl-net.so}"

# These pick the TCP/IP interface for rendezvous, bootstrap, and metadata.
# They do not force payload traffic through eth0 when EFA/OFI is selected.
export NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-eth0}"
export GLOO_SOCKET_IFNAME="${GLOO_SOCKET_IFNAME:-eth0}"
export UCCL_SOCKET_IFNAME="${UCCL_SOCKET_IFNAME:-eth0}"

export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1,2,3,4,5,6,7}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-8}"
export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"

export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
export NCCL_DEBUG_SUBSYS="${NCCL_DEBUG_SUBSYS:-INIT,NET}"
