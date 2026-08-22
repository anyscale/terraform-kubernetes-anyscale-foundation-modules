#!/usr/bin/env bash

ensure_azure_cli_environment() {
  local resolved_home=""

  if [[ -n "${HOME:-}" && -d "${HOME}" ]]; then
    export HOME="${HOME}"
  else
    if command -v getent >/dev/null 2>&1; then
      resolved_home="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || true)"
    fi
    if [[ -z "${resolved_home}" ]]; then
      resolved_home="$(eval echo "~$(id -un)")"
    fi
    if [[ -z "${resolved_home}" ]]; then
      resolved_home="${ROOT_DIR}/.cache/azure-home"
    fi
    mkdir -p "${resolved_home}"
    export HOME="${resolved_home}"
  fi

  export AZURE_CONFIG_DIR="${AZURE_CONFIG_DIR:-${HOME}/.azure}"
  mkdir -p "${AZURE_CONFIG_DIR}"
}
