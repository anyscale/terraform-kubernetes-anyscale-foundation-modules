#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env/gcp_rdma_uccl_env.sh"

PYTHON=${PYTHON:-python}

"$PYTHON" - <<'PY'
import importlib
import torch

print("torch", torch.__version__)
print("cuda available", torch.cuda.is_available())
print("cuda devices", torch.cuda.device_count())

for name in ("uccl", "uccl.ep", "deep_ep"):
    mod = importlib.import_module(name)
    print(name, getattr(mod, "__file__", "builtin"))
PY

echo "UCCL import validation passed"
