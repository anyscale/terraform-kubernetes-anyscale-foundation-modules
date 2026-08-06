#!/usr/bin/env bash
set -euo pipefail

GCLOUD=${GCLOUD:-}
if [ -z "$GCLOUD" ]; then
  if command -v gcloud >/dev/null 2>&1; then
    GCLOUD=$(command -v gcloud)
  else
    echo "gcloud not found; set GCLOUD=/path/to/gcloud" >&2
    exit 127
  fi
fi
gcloud() { "$GCLOUD" "$@"; }
export PATH="$(dirname "$GCLOUD"):$PATH"

PROJECT=${PROJECT:?Set PROJECT to your Google Cloud project ID}
REGION=${REGION:?Set REGION to the GKE region}
CLUSTER=${CLUSTER:?Set CLUSTER to the GKE cluster name}
SKIP_INSTALL=${SKIP_INSTALL:-0}

# Ray/UCCL run inside a Python venv on each pod. By default this creates a
# minimal, generic environment (Ray + a CUDA build of PyTorch) that is all the
# NCCL/UCCL validation needs. To install your own project into the venv instead
# (e.g. a training framework), set RAY_ENV_SETUP_CMD to a shell command that
# creates/populates the venv at $RAY_VENV.
RAY_WORKDIR=${RAY_WORKDIR:-/workspace/rayenv}
RAY_VENV=${RAY_VENV:-$RAY_WORKDIR/.venv}
RAY_PYTHON_VERSION=${RAY_PYTHON_VERSION:-3.12}
RAY_SPEC=${RAY_SPEC:-ray[default]}
TORCH_SPEC=${TORCH_SPEC:-torch}
TORCH_INDEX_URL=${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}
RAY_ENV_SETUP_CMD=${RAY_ENV_SETUP_CMD:-}
SKIP_READY_INSTALLS=${SKIP_READY_INSTALLS:-1}
INSTALL_RETRIES=${INSTALL_RETRIES:-2}

gcloud container clusters get-credentials "$CLUSTER" --location="$REGION" --project="$PROJECT"

install_cmd=$(cat <<'EOS'
set -euo pipefail
mkdir -p "$RAY_WORKDIR"
cd "$RAY_WORKDIR"
curl -LsSf https://astral.sh/uv/install.sh | sh
source "$HOME/.local/bin/env"
export UV_LINK_MODE=${UV_LINK_MODE:-copy}
if [ ! -d "$RAY_VENV" ]; then
  uv venv --python "$RAY_PYTHON_VERSION" "$RAY_VENV"
fi
source "$RAY_VENV/bin/activate"
if [ -n "$RAY_ENV_SETUP_CMD" ]; then
  # Caller-provided environment setup (installs into the active venv).
  bash -lc "$RAY_ENV_SETUP_CMD"
else
  uv pip install "$RAY_SPEC"
  uv pip install "$TORCH_SPEC" --index-url "$TORCH_INDEX_URL"
fi
EOS
)

pod_env="RAY_WORKDIR=$RAY_WORKDIR RAY_VENV=$RAY_VENV RAY_PYTHON_VERSION=$RAY_PYTHON_VERSION RAY_SPEC=$RAY_SPEC TORCH_SPEC=$TORCH_SPEC TORCH_INDEX_URL=$TORCH_INDEX_URL RAY_ENV_SETUP_CMD=$RAY_ENV_SETUP_CMD"

if [ "$SKIP_INSTALL" != "1" ]; then
  for pod in ray-head ray-worker-0 ray-worker-1; do
    if [ "$SKIP_READY_INSTALLS" = "1" ] && kubectl exec "$pod" -- env RAY_VENV="$RAY_VENV" bash -lc '
      test -x "$RAY_VENV/bin/ray"
      "$RAY_VENV/bin/python" - <<"PY"
import ray
print("ready", ray.__version__)
PY
    '; then
      echo "Ray env already present in ${pod}; skipping install."
      continue
    fi

    echo "Setting up Ray env in ${pod}"
    installed=0
    for attempt in $(seq 1 "$INSTALL_RETRIES"); do
      if kubectl exec "$pod" -- env $pod_env bash -lc "$install_cmd"; then
        installed=1
        break
      fi
      echo "Setup attempt ${attempt}/${INSTALL_RETRIES} failed in ${pod}." >&2
      sleep 10
    done
    if [ "$installed" != "1" ]; then
      echo "Failed to set up Ray env in ${pod} after ${INSTALL_RETRIES} attempts." >&2
      exit 1
    fi
  done
fi

echo "Starting Ray head"
kubectl exec ray-head -- env RAY_WORKDIR="$RAY_WORKDIR" RAY_VENV="$RAY_VENV" bash -lc '
  set -euo pipefail
  cd "$RAY_WORKDIR"
  source "$RAY_VENV/bin/activate"
  ray stop --force >/tmp/ray-stop.log 2>&1 || true
  export RAY_worker_register_timeout_seconds=1000
  ray start --head \
    --node-ip-address=$(hostname -i) \
    --port=6379 \
    --dashboard-host=0.0.0.0 \
    --dashboard-port=8265 \
    --num-gpus=0 \
    --disable-usage-stats
'

for pod in ray-worker-0 ray-worker-1; do
  echo "Starting Ray worker in ${pod}"
  kubectl exec "$pod" -- env RAY_WORKDIR="$RAY_WORKDIR" RAY_VENV="$RAY_VENV" bash -lc '
    set -euo pipefail
    cd "$RAY_WORKDIR"
    source "$RAY_VENV/bin/activate"
    source /usr/local/gib/scripts/set_nccl_env.sh
    ray stop --force >/tmp/ray-stop.log 2>&1 || true
    export RAY_worker_register_timeout_seconds=1000
    setsid nohup ray start --address=ray-head:6379 --num-gpus=8 --block \
      > /workspace/ray-worker.log 2>&1 < /dev/null &
  '
done

sleep 10
kubectl exec ray-head -- env RAY_WORKDIR="$RAY_WORKDIR" RAY_VENV="$RAY_VENV" bash -lc 'cd "$RAY_WORKDIR" && source "$RAY_VENV/bin/activate" && ray status'
