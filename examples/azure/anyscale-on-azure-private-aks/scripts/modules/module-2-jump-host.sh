#!/usr/bin/env bash
# Module 2 — Prepare the jump hosts.
#
# Turns the Linux VM into a repeatable in-VNet operator workstation and verifies
# the optional Windows browser VM. Installs tools (bootstrap), syncs the repo and
# .env to the canonical path, runs doctor, and proves the Linux VM can run
# private deployment commands from inside the VNet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
DISPATCHER="${SCRIPTS_DIR}/anyscale-aks.sh"
BOOTSTRAP_SCRIPT="${SCRIPTS_DIR}/bootstrap-jump-host.sh"
MODULE_1_SCRIPT="${SCRIPT_DIR}/module-1-foundation.sh"
ADMIN_DIR="${ROOT_DIR}/infra/terraform"
CANONICAL_REPO_PATH="${ANYSCALE_AKS_REPO_PATH:-/opt/anyscale-aks-sample}"

LOG_INFO_PREFIX="module2"
LOG_WARN_PREFIX="module2"
LOG_ERROR_PREFIX="module2"
# shellcheck source=../lib/log.sh
source "${SCRIPTS_DIR}/lib/log.sh"
# shellcheck source=../lib/vm-position.sh
source "${SCRIPTS_DIR}/lib/vm-position.sh"

load_env() {
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/.env"
    set +a
  fi
}

on_jump_host() {
  running_on_azure_vm
}

admin_output() {
  terraform -chdir="${ADMIN_DIR}" output -raw "$1" 2>/dev/null || printf ''
}

admin_resource_group() {
  load_env
  printf 'rg-%s-%s-%s\n' "${TF_VAR_project:?}" "${TF_VAR_environment:?}" "${TF_VAR_region_short:?}"
}

# ---------------------------------------------------------------------------
# bootstrap — install tools and configure the canonical path on the VM.
# ---------------------------------------------------------------------------
module_2_bootstrap() {
  load_env
  if on_jump_host; then
    log "Running VM-local bootstrap (${BOOTSTRAP_SCRIPT})..."
    bash "${BOOTSTRAP_SCRIPT}" "$@"
    return $?
  fi
  warn "This machine is not an Azure VM (Azure IMDS did not answer)."
  warn "Bootstrap installs tools ON the Linux jump host. Run it inside the VM:"
  warn "  1. ./scripts/anyscale-aks.sh module 2 sync       # copy repo + .env to the VM"
  warn "  2. ./scripts/anyscale-aks.sh module 1 connect    # open a Bastion SSH session"
  warn "  3. On the VM: cd ${CANONICAL_REPO_PATH} && ./scripts/anyscale-aks.sh module 2 bootstrap"
  die "Refusing to install jump-host tooling on the workstation."
}

# ---------------------------------------------------------------------------
# sync — copy repo content and .env to the canonical VM path over Bastion.
# ---------------------------------------------------------------------------
open_bastion_tunnel() {
  # Opens an `az network bastion tunnel` to the Linux jump host port 22 on a
  # local port and echoes "PID PORT". Caller must kill the PID when done.
  local vm_id bastion_name rg local_port
  vm_id="$(admin_output linux_jump_host_vm_id)"
  bastion_name="$(admin_output bastion_name)"
  rg="$(admin_resource_group)"
  [[ -n "${vm_id}" ]] || die "Linux jump-host VM ID not found. Apply Module 1 first."
  local_port="${BASTION_SSH_LOCAL_PORT:-50022}"

  az network bastion tunnel \
    --name "${bastion_name}" \
    --resource-group "${rg}" \
    --target-resource-id "${vm_id}" \
    --resource-port 22 \
    --port "${local_port}" >/dev/null 2>&1 &
  local pid=$!
  # Give the tunnel a moment to bind.
  local waited=0
  while ! { command -v lsof >/dev/null 2>&1 && lsof -i :"${local_port}" >/dev/null 2>&1; }; do
    sleep 1
    waited=$((waited + 1))
    if [[ ${waited} -ge 20 ]]; then
      kill "${pid}" 2>/dev/null || true
      die "Bastion tunnel did not open local port ${local_port} in time."
    fi
  done
  printf '%s %s\n' "${pid}" "${local_port}"
}

module_2_sync() {
  load_env
  if on_jump_host; then
    die "module 2 sync runs on the workstation to push to the VM, not on the jump host itself."
  fi
  command -v az >/dev/null 2>&1 || die "Azure CLI (az) is required for sync."
  command -v rsync >/dev/null 2>&1 || die "rsync is required for sync."

  local admin_user
  admin_user="$(admin_output linux_jump_host_admin_username)"
  [[ -n "${admin_user}" ]] || admin_user="azureoperator"
  local ssh_key="${SSH_PRIVATE_KEY_PATH:-${HOME}/.ssh/id_ed25519}"
  [[ -f "${ssh_key}" ]] || die "SSH private key not found at ${ssh_key}. Set SSH_PRIVATE_KEY_PATH."

  log "Opening Bastion tunnel to the Linux jump host..."
  local tunnel pid port known_hosts_file
  tunnel="$(open_bastion_tunnel)"
  pid="${tunnel%% *}"
  port="${tunnel##* }"
  known_hosts_file="$(mktemp "${TMPDIR:-/tmp}/anyscale-module2-known-hosts.XXXXXX")"
  trap 'rm -f "${known_hosts_file}"; kill "${pid}" 2>/dev/null || true' EXIT

  log "Syncing repo to ${admin_user}@127.0.0.1:${CANONICAL_REPO_PATH} (port ${port})..."
  # Ensure destination exists and is writable by the admin user.
  ssh -p "${port}" -i "${ssh_key}" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${known_hosts_file}" \
    "${admin_user}@127.0.0.1" \
    "sudo mkdir -p '${CANONICAL_REPO_PATH}' && sudo chown -R ${admin_user} '${CANONICAL_REPO_PATH}'"

  rsync -az --delete \
    -e "ssh -p ${port} -i ${ssh_key} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${known_hosts_file}" \
    --exclude '.git/' \
    --exclude '.terraform/' \
    --exclude '.cache/' \
    --exclude '.venv/' \
    --exclude '*.tfstate*' \
    "${ROOT_DIR}/" \
    "${admin_user}@127.0.0.1:${CANONICAL_REPO_PATH}/"

  if [[ -f "${ROOT_DIR}/.env" ]]; then
    log "Copying .env to the VM..."
    rsync -az \
      -e "ssh -p ${port} -i ${ssh_key} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${known_hosts_file}" \
      "${ROOT_DIR}/.env" \
      "${admin_user}@127.0.0.1:${CANONICAL_REPO_PATH}/.env"
  else
    warn ".env not found on the workstation; skipping .env sync. Create it from .env-template."
  fi

  kill "${pid}" 2>/dev/null || true
  rm -f "${known_hosts_file}"
  trap - EXIT
  log "Sync complete. Connect with: ./scripts/anyscale-aks.sh module 1 connect"
}

# ---------------------------------------------------------------------------
# doctor — local readiness, delegated to the dispatcher.
# ---------------------------------------------------------------------------
module_2_doctor() {
  load_env
  "${DISPATCHER}" doctor "$@"
}

# ---------------------------------------------------------------------------
# verify — prove the Linux VM can run private deployment commands.
# ---------------------------------------------------------------------------
module_2_verify() {
  load_env
  if ! on_jump_host; then
    die "module 2 verify must run from the synced repo on the Linux jump host. From the workstation run 'module 2 sync' and 'module 1 connect', then on the VM run: cd ${CANONICAL_REPO_PATH} && ./scripts/anyscale-aks.sh module 2 verify"
  fi

  local failures=0
  check_tool() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
      log "PASS: ${name}"
    else
      warn "FAIL: ${name}"
      failures=$((failures + 1))
    fi
  }

  check_tool "az account show (managed identity)" az account show
  check_tool "kubectl version --client" kubectl version --client
  check_tool "kubelogin version" kubelogin --version
  check_tool "helm version" helm version
  check_tool "podman version" podman version
  if [[ -x "${CANONICAL_REPO_PATH}/.venv/bin/anyscale" ]]; then
    check_tool "anyscale --help" "${CANONICAL_REPO_PATH}/.venv/bin/anyscale" --help
  elif [[ -x "${ROOT_DIR}/.venv/bin/anyscale" ]]; then
    check_tool "anyscale --help" "${ROOT_DIR}/.venv/bin/anyscale" --help
  else
    warn "FAIL: anyscale CLI not found in repo .venv"
    failures=$((failures + 1))
  fi

  if [[ -d "${CANONICAL_REPO_PATH}" ]]; then
    log "PASS: repo present at ${CANONICAL_REPO_PATH}"
  else
    warn "FAIL: repo not found at ${CANONICAL_REPO_PATH}"
    failures=$((failures + 1))
  fi

  if [[ -f "${ROOT_DIR}/.env" ]]; then
    log "PASS: .env present on the VM"
  else
    warn "FAIL: .env not found on the VM. Run 'module 2 sync' from the workstation."
    failures=$((failures + 1))
  fi

  [[ ${failures} -eq 0 ]] || die "${failures} readiness check(s) failed."
  log "Module 2 verify passed. The jump host reaches private endpoints directly from inside the VNet."
}

module_2_browser_verify() {
  bash "${MODULE_1_SCRIPT}" browser verify "$@"
}

usage() {
  cat <<'USAGE'
Module 2 — Prepare the jump hosts.

Usage:
  ./scripts/anyscale-aks.sh module 2 bootstrap     # run ON the Linux jump host
  ./scripts/anyscale-aks.sh module 2 sync          # run on the workstation
  ./scripts/anyscale-aks.sh module 2 doctor
  ./scripts/anyscale-aks.sh module 2 verify
  ./scripts/anyscale-aks.sh module 2 browser verify
USAGE
}

main() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    bootstrap) module_2_bootstrap "$@" ;;
    sync) module_2_sync "$@" ;;
    doctor) module_2_doctor "$@" ;;
    verify) module_2_verify "$@" ;;
    browser)
      local b="${1:-}"; shift || true
      case "${b}" in
        verify) module_2_browser_verify "$@" ;;
        *) die "Usage: module 2 browser verify" ;;
      esac
      ;;
    ""|--help|-h) usage ;;
    *) die "Unknown 'module 2' subcommand: ${sub}. Run 'module 2 --help'." ;;
  esac
}

main "$@"
