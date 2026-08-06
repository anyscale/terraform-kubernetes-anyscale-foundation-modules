#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env/aws_efa_uccl_env.sh"

python - <<'PY'
import pathlib
import torch
import uccl
import uccl.ep
from uccl.ep import Config
from deep_ep import Buffer

print("torch", torch.__version__)
print("torch_cuda", torch.version.cuda)
print("cuda_available", torch.cuda.is_available())
print("cuda_device_count", torch.cuda.device_count())
if torch.cuda.is_available():
    print("gpu0", torch.cuda.get_device_name(0))
    print("gpu0_capability", torch.cuda.get_device_capability(0))
print("uccl", getattr(uccl, "__version__", "unknown"))
print("uccl_path", pathlib.Path(uccl.__file__).resolve())
print("uccl_ep", uccl.ep)
print("Config", Config)
print("Buffer", Buffer)
print("import_check ok")
PY
