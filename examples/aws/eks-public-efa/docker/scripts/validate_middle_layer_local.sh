#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/../env/aws_efa_uccl_env.sh"

echo "Running local middle-layer smoke checks"

"${SCRIPT_DIR}/validate_efa_devices.sh"
"${SCRIPT_DIR}/validate_uccl_imports.sh"

echo
echo "Local middle-layer smoke checks passed"
