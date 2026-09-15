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

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROJECT=${PROJECT:?Set PROJECT to your Google Cloud project ID}
REGION=${REGION:?Set REGION to the GKE region}
CLUSTER=${CLUSTER:?Set CLUSTER to the GKE cluster name}
PODS=${PODS:-ray-worker-0 ray-worker-1}
UCCL_URL=${UCCL_URL:-https://github.com/uccl-project/uccl.git}
UCCL_REF=${UCCL_REF:-v0.1.1}
PYTHON=${PYTHON:-/workspace/rayenv/.venv/bin/python}
UV=${UV:-/root/.local/bin/uv}
UCCL_TORCH_CUDA_ARCH_LIST=${UCCL_TORCH_CUDA_ARCH_LIST:-10.0}
EFA_HOME=${EFA_HOME:-/opt/gcp-no-efa}
UCCL_FORCE_DMABUF=${UCCL_FORCE_DMABUF:-1}
SKIP_READY_INSTALLS=${SKIP_READY_INSTALLS:-1}
INSTALL_RETRIES=${INSTALL_RETRIES:-2}

gcloud container clusters get-credentials "$CLUSTER" --location="$REGION" --project="$PROJECT"

for pod in $PODS; do
  echo "Copying GCP middle-layer helpers to ${pod}"
  kubectl exec "$pod" -- bash -lc 'mkdir -p /opt/gcp-middle/env /opt/gcp-middle/scripts'
  kubectl cp "$ROOT/docker/env/." "${pod}:/opt/gcp-middle/env"
  kubectl cp "$ROOT/docker/scripts/." "${pod}:/opt/gcp-middle/scripts"
  kubectl exec "$pod" -- bash -lc 'chmod +x /opt/gcp-middle/env/*.sh /opt/gcp-middle/scripts/*.sh'

  if [ "$SKIP_READY_INSTALLS" = "1" ] && kubectl exec "$pod" -- env PYTHON="$PYTHON" bash -lc '
    test -f /opt/uccl/ep/include/common.hpp
    grep -q GCP_FORCE_DMABUF /opt/uccl/ep/include/common.hpp
    "$PYTHON" - <<"PY"
import uccl
import uccl.ep
import deep_ep
print("uccl ready")
PY
  '; then
    echo "UCCL/UCCL-EP/DeepEP already installed in ${pod}; skipping install."
    continue
  fi

  echo "Installing UCCL/UCCL-EP/DeepEP wrapper in ${pod}"
  installed=0
  for attempt in $(seq 1 "$INSTALL_RETRIES"); do
    if kubectl exec "$pod" -- env UCCL_URL="$UCCL_URL" UCCL_REF="$UCCL_REF" PYTHON="$PYTHON" UV="$UV" UCCL_TORCH_CUDA_ARCH_LIST="$UCCL_TORCH_CUDA_ARCH_LIST" EFA_HOME="$EFA_HOME" UCCL_FORCE_DMABUF="$UCCL_FORCE_DMABUF" bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export CUDA_HOME=${CUDA_HOME:-/usr/local/cuda}
    export TORCH_CUDA_ARCH_LIST=${UCCL_TORCH_CUDA_ARCH_LIST}
    export EFA_HOME=${EFA_HOME}
    export PER_EXPERT_BATCHING=${PER_EXPERT_BATCHING:-1}
    export USE_DMABUF=${USE_DMABUF:-1}
    export UCCL_FORCE_DMABUF=${UCCL_FORCE_DMABUF:-1}
    export MAX_JOBS=${MAX_JOBS:-16}

    apt-get update
    apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      build-essential \
      ca-certificates \
      curl \
      git \
      ibverbs-providers \
      iproute2 \
      libhwloc-dev \
      libibverbs-dev \
      libnl-3-dev \
      libnl-route-3-dev \
      libnuma-dev \
      librdmacm-dev \
      libtool \
      perl \
      pciutils \
      pkg-config \
      rdma-core \
      wget
    rm -rf /var/lib/apt/lists/*

    test -x "$UV"
    "$UV" pip install --python "$PYTHON" --no-cache --upgrade pip setuptools wheel
    "$UV" pip install --python "$PYTHON" --no-cache nanobind intervaltree sortedcontainers

    if [ ! -d /opt/uccl/.git ]; then
      rm -rf /opt/uccl
      git clone "$UCCL_URL" /opt/uccl
    fi
    cd /opt/uccl
    git fetch --tags
    git checkout "$UCCL_REF"
    if [ "$UCCL_FORCE_DMABUF" = "1" ]; then
      if ! grep -q "GCP_FORCE_DMABUF" ep/include/common.hpp; then
        perl -0pi -e "s{// Intel RDMA NIC support}{#ifndef USE_DMABUF\\n#define USE_DMABUF  // GCP_FORCE_DMABUF: force DMA-BUF for GKE A4 RoCE\\n#endif\\n\\n// Intel RDMA NIC support}" ep/include/common.hpp
      fi
    fi

    "$UV" pip install --python "$PYTHON" --no-cache /opt/uccl
    rm -rf /tmp/uccl_ep_build
    cp -a /opt/uccl /tmp/uccl_ep_build
    cd /tmp/uccl_ep_build/ep
    "$PYTHON" setup.py install
    cd /tmp/uccl_ep_build/ep/deep_ep_wrapper
    for name in buffer.py test_internode.py utils.py; do
      rm -f "deep_ep/${name}"
      cp "../bench/${name}" "deep_ep/${name}"
    done
    "$UV" pip install --python "$PYTHON" --no-cache --no-build-isolation .
    rm -rf /tmp/uccl_ep_build
  '; then
      installed=1
      break
    fi
    echo "Install attempt ${attempt}/${INSTALL_RETRIES} failed in ${pod}." >&2
    sleep 10
  done
  if [ "$installed" != "1" ]; then
    echo "Failed to install UCCL/UCCL-EP/DeepEP in ${pod} after ${INSTALL_RETRIES} attempts." >&2
    exit 1
  fi
done
