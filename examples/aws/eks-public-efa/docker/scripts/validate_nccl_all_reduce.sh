#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env/aws_efa_uccl_env.sh"

PYTHON=${PYTHON:-python}
BENCH_SCRIPT=${BENCH_SCRIPT:-/opt/efa-middle/bench/all_reduce_bench.py}
NNODES=${NNODES:-1}
NPROC_PER_NODE=${NPROC_PER_NODE:-8}
WORLD_SIZE=${WORLD_SIZE:-$((NNODES * NPROC_PER_NODE))}
ALL_REDUCE_WARMUPS=${ALL_REDUCE_WARMUPS:-1}
ALL_REDUCE_TRIALS=${ALL_REDUCE_TRIALS:-3}
ALL_REDUCE_PAYLOAD_SIZE_GIB=${ALL_REDUCE_PAYLOAD_SIZE_GIB:-1}
ALL_REDUCE_PROFILE_STABILITY=${ALL_REDUCE_PROFILE_STABILITY:-0}
REQUIRE_NCCL_OFI=${REQUIRE_NCCL_OFI:-1}

export NCCL_NET_PLUGIN=${NCCL_NET_PLUGIN:-libnccl-net.so}
export NCCL_DEBUG=${NCCL_VALIDATION_DEBUG:-INFO}
export NCCL_DEBUG_SUBSYS=${NCCL_VALIDATION_DEBUG_SUBSYS:-INIT,NET,ENV}

if [ ! -f "$BENCH_SCRIPT" ]; then
  echo "Cannot find Ray all-reduce benchmark at ${BENCH_SCRIPT}." >&2
  echo "The image should bake it into /opt/efa-middle/bench/all_reduce_bench.py." >&2
  exit 1
fi

if [ "$WORLD_SIZE" -lt 1 ]; then
  echo "WORLD_SIZE must be at least 1; got ${WORLD_SIZE}." >&2
  exit 2
fi

echo "Running Ray NCCL all-reduce validation"
echo "WORLD_SIZE=${WORLD_SIZE} NNODES=${NNODES} NPROC_PER_NODE=${NPROC_PER_NODE}"
echo "BENCH_SCRIPT=${BENCH_SCRIPT}"
echo "ALL_REDUCE_WARMUPS=${ALL_REDUCE_WARMUPS} ALL_REDUCE_TRIALS=${ALL_REDUCE_TRIALS} PAYLOAD=${ALL_REDUCE_PAYLOAD_SIZE_GIB}GiB"
echo "NCCL_NET_PLUGIN=${NCCL_NET_PLUGIN}"
echo "NCCL_DEBUG=${NCCL_DEBUG} NCCL_DEBUG_SUBSYS=${NCCL_DEBUG_SUBSYS}"
echo "FI_PROVIDER=${FI_PROVIDER} FI_EFA_USE_DEVICE_RDMA=${FI_EFA_USE_DEVICE_RDMA}"
echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH}"
echo "aws-ofi-nccl plugin candidates:"
find "${OFI_NCCL_HOME}/lib" -maxdepth 1 -name "libnccl-net.so*" -print -exec ls -l {} \; 2>/dev/null || true
if [ "$REQUIRE_NCCL_OFI" = "1" ] && ! find "${OFI_NCCL_HOME}/lib" -maxdepth 1 -name "libnccl-net.so*" -print -quit 2>/dev/null | grep -q .; then
  echo "Missing aws-ofi-nccl libnccl-net.so under ${OFI_NCCL_HOME}/lib" >&2
  exit 1
fi

args=(
  "$BENCH_SCRIPT"
  --world_size "$WORLD_SIZE"
  --num_iterations "$ALL_REDUCE_TRIALS"
  --num_warmup_iterations "$ALL_REDUCE_WARMUPS"
  --payload_size_in_gib "$ALL_REDUCE_PAYLOAD_SIZE_GIB"
)
if [ "$ALL_REDUCE_PROFILE_STABILITY" = "1" ]; then
  args+=(--profile_stability)
fi

run_log=$(mktemp -t ray-nccl-allreduce.XXXXXX.log)
set +e
"$PYTHON" -u "${args[@]}" 2>&1 | tee "$run_log"
status=${PIPESTATUS[0]}
set -e

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

if [ "$REQUIRE_NCCL_OFI" = "1" ] && ! grep -E "Loaded net plugin AWS Libfabric|NET/OFI Initializing aws-ofi-nccl|Using network AWS Libfabric" "$run_log" >/dev/null; then
  echo "Ray all-reduce completed, but the log did not show aws-ofi-nccl/AWS Libfabric." >&2
  echo "If Ray worker logs are not forwarded to the driver, verify the worker logs manually or set REQUIRE_NCCL_OFI=0." >&2
  exit 2
fi

echo "Ray NCCL aws-ofi-nccl validation passed"
