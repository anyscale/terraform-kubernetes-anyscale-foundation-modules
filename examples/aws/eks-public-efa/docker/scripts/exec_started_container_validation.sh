#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

CONTAINER=${CONTAINER:-${1:-}}
DOCKER=${DOCKER:-docker}

if [ -z "$CONTAINER" ]; then
  cat >&2 <<EOF
Usage:
  CONTAINER=<container-name-or-id> $0
  $0 <container-name-or-id>

Optional:
  DOCKER="sudo docker"
EOF
  exit 2
fi

$DOCKER exec \
  "$CONTAINER" \
  bash /opt/efa-middle/scripts/validate_middle_layer_local.sh
