#!/usr/bin/env bash
# Module 3 — Deploy and prove the lab workload.
#
# Thin wrapper that maps the learning-module commands onto the existing
# implementation in setup.sh / anyscale-aks.sh. Terraform runs from the
# workstation; jump-host steps run Kubernetes/bootstrap work inside the VNet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
DISPATCHER="${SCRIPTS_DIR}/anyscale-aks.sh"
MODULE_1_SCRIPT="${SCRIPT_DIR}/module-1-foundation.sh"

LOG_INFO_PREFIX="module3"
LOG_WARN_PREFIX="module3"
LOG_ERROR_PREFIX="module3"
# shellcheck source=../lib/log.sh
source "${SCRIPTS_DIR}/lib/log.sh"

dispatch() {
  ANYSCALE_VIA_MODULE=1 "${DISPATCHER}" "$@"
}

module_3_deploy() { dispatch deploy "$@"; }

module_3_verify() {
  # Default to --full to match the learning-module contract.
  if [[ $# -eq 0 ]]; then
    dispatch verify --full
  else
    dispatch verify "$@"
  fi
}

module_3_custom_image() {
  local action="${1:-}"
  shift || true
  case "${action}" in
    prove-failure|preflight|prepare|apply|proof)
      dispatch custom-image "${action}" "$@"
      ;;
    ""|--help|-h)
      cat <<'USAGE'
Usage: module 3 custom-image {prove-failure|preflight|prepare|apply|proof}
USAGE
      ;;
    *)
      die "Unknown 'module 3 custom-image' action: ${action}"
      ;;
  esac
}

module_3_proof() {
  local target="${1:-all}"
  dispatch proof "${target}"
}

module_3_teardown() { dispatch teardown "$@"; }

module_3_browser_validate() {
  log "Interactive browser validation of console-launched private URLs."
  log "This step is manual and is never part of the unattended e2e gate."
  log ""
  log "1. Apply the optional Windows browser host: module 1 apply --enable-browser-host"
  log "2. Open the Azure portal, connect to the Windows browser VM via Bastion RDP, sign in with Entra ID."
  log "3. Open https://console.azure.anyscale.com and launch a workspace or service."
  log "4. Confirm the workspace, Ray dashboard, VS Code, and service URLs resolve to"
  log "   *.azure.anyscaleuserdata.com privately with valid TLS (no localhost rewriting)."
  log ""
  log "See docs/modules/browser-access.md for the full lesson and alternative browser paths."
  # Surface non-interactive readiness so learners know the host is wired up.
  if [[ -x "${MODULE_1_SCRIPT}" ]]; then
    bash "${MODULE_1_SCRIPT}" browser verify || warn "Browser host readiness checks reported issues; review before manual validation."
  fi
}

usage() {
  cat <<'USAGE'
Module 3 — Deploy and prove the lab workload. (Custom-image steps: module 4.)

Usage:
  ./scripts/anyscale-aks.sh module 3 deploy
  ./scripts/anyscale-aks.sh module 3 verify --full
  ./scripts/anyscale-aks.sh module 3 proof all
  ./scripts/anyscale-aks.sh module 3 browser validate
  ./scripts/anyscale-aks.sh module 3 teardown

  # Backward-compat alias (prefer 'module 4'):
  ./scripts/anyscale-aks.sh module 3 custom-image {prove-failure|preflight|prepare|apply|proof}
USAGE
}

main() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    deploy) module_3_deploy "$@" ;;
    verify) module_3_verify "$@" ;;
    custom-image) module_3_custom_image "$@" ;;
    proof) module_3_proof "$@" ;;
    teardown) module_3_teardown "$@" ;;
    browser)
      local b="${1:-}"; shift || true
      case "${b}" in
        validate) module_3_browser_validate "$@" ;;
        *) die "Usage: module 3 browser validate" ;;
      esac
      ;;
    ""|--help|-h) usage ;;
    *) die "Unknown 'module 3' subcommand: ${sub}. Run 'module 3 --help'." ;;
  esac
}

main "$@"
