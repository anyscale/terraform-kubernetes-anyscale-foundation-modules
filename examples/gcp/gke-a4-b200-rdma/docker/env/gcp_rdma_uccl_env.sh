#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
export GIB_HOME="${GIB_HOME:-/usr/local/gib}"
export NVIDIA_HOST_HOME="${NVIDIA_HOST_HOME:-/usr/local/nvidia}"

if [ -x "${GIB_HOME}/scripts/set_nccl_env.sh" ]; then
  # shellcheck disable=SC1091
  source "${GIB_HOME}/scripts/set_nccl_env.sh"
fi

export PATH="${CUDA_HOME}/bin:${PATH}"
export LD_LIBRARY_PATH="${NVIDIA_HOST_HOME}/lib64:${GIB_HOME}/lib64:${LD_LIBRARY_PATH:-}"

export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1,2,3,4,5,6,7}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-8}"
export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"

export GLOO_SOCKET_IFNAME="${GLOO_SOCKET_IFNAME:-eth0}"
export UCCL_SOCKET_IFNAME="${UCCL_SOCKET_IFNAME:-eth0}"
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
export NCCL_DEBUG_SUBSYS="${NCCL_DEBUG_SUBSYS:-INIT,NET}"

export USE_DMABUF="${USE_DMABUF:-1}"
export UCCL_FORCE_DMABUF="${UCCL_FORCE_DMABUF:-1}"
export PER_EXPERT_BATCHING="${PER_EXPERT_BATCHING:-1}"
