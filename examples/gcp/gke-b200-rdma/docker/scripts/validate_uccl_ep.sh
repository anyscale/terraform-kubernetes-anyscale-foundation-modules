#!/usr/bin/env bash
set -euo pipefail

MODE=${1:-}
if [ "$MODE" != "ll" ] && [ "$MODE" != "ht" ]; then
  echo "Usage: $0 ll|ht" >&2
  exit 2
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env/gcp_rdma_uccl_env.sh"

PYTHON=${PYTHON:-python}
NNODES=${NNODES:-1}
NPROC_PER_NODE=${NPROC_PER_NODE:-8}
NODE_RANK=${NODE_RANK:-0}
MASTER_ADDR=${MASTER_ADDR:-127.0.0.1}

LL_PORT=${LL_PORT:-6123}
HT_PORT=${HT_PORT:-6124}
LL_TOKENS=${LL_TOKENS:-128}
HT_TOKENS=${HT_TOKENS:-4096}
HIDDEN=${HIDDEN:-7168}
TOPK=${TOPK:-8}
EXPERTS=${EXPERTS:-288}

UCCL_BENCH_DIR=${UCCL_BENCH_DIR:-/opt/uccl/ep/bench}
if [ ! -d "$UCCL_BENCH_DIR" ]; then
  echo "Cannot find UCCL bench dir. Set UCCL_BENCH_DIR=/path/to/uccl/ep/bench" >&2
  exit 1
fi

if [ "$MODE" = "ll" ]; then
  MASTER_PORT=${MASTER_PORT:-$LL_PORT}
  BENCH_SCRIPT=test_low_latency.py
  BENCH_ARGS=(--num-tokens="$LL_TOKENS" --hidden="$HIDDEN" --num-topk="$TOPK" --num-experts="$EXPERTS")
else
  MASTER_PORT=${MASTER_PORT:-$HT_PORT}
  BENCH_SCRIPT=test_internode.py
  BENCH_ARGS=(--num-tokens="$HT_TOKENS" --hidden="$HIDDEN" --num-topk="$TOPK" --num-experts="$EXPERTS" --test-ll-compatibility)
fi

echo "Running UCCL-EP ${MODE} validation"
echo "NNODES=$NNODES NPROC_PER_NODE=$NPROC_PER_NODE NODE_RANK=$NODE_RANK MASTER=$MASTER_ADDR:$MASTER_PORT"
echo "UCCL_BENCH_DIR=$UCCL_BENCH_DIR"

cd "$UCCL_BENCH_DIR"
"$PYTHON" -u -m torch.distributed.run \
  --nnodes="$NNODES" \
  --nproc_per_node="$NPROC_PER_NODE" \
  --node_rank="$NODE_RANK" \
  --master_addr="$MASTER_ADDR" \
  --master_port="$MASTER_PORT" \
  "$BENCH_SCRIPT" \
  "${BENCH_ARGS[@]}"
