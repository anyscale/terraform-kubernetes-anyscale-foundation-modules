#!/usr/bin/env bash
# Module 1 — Build the persistent foundation and connect to the jump hosts.
#
# Wraps the infra/terraform root: VM-size selection, plan/apply, Bastion
# SSH tunnel to the Linux jump host, Bastion portal RDP guidance for the
# optional Windows browser host, and read-only verification of both paths.
#
# This module owns durable resources (shared VNet, Bastion, firewall, routing,
# DNS, jump hosts) that outlive workload rebuilds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
ADMIN_DIR="${ROOT_DIR}/infra/terraform"
ADMIN_CACHE="${ROOT_DIR}/.cache/aks-anyscale-sample-harness/admin"
ADMIN_TFVARS="${ADMIN_DIR}/terraform.auto.tfvars.json"
VM_SIZE_SELECTION_JSON="${ADMIN_CACHE}/vm-size-selection.json"

LOG_INFO_PREFIX="module1"
LOG_WARN_PREFIX="module1"
LOG_ERROR_PREFIX="module1"
# shellcheck source=../lib/log.sh
source "${SCRIPTS_DIR}/lib/log.sh"

FOUNDATION_TARGETS=(
  -target=azurerm_resource_group.this
  -target=module.network
  -target=module.dns
  -target=azurerm_private_dns_a_record.anyscale_userdata
  -target=module.dns_resolver
  -target=module.firewall
  -target=azurerm_virtual_network_dns_servers.workload
  -target=module.routing
  -target=module.bastion
  -target=module.jump_host
  -target=module.browser_jump_host
  -target=azurerm_role_assignment.jump_host_contributor
  -target=azurerm_role_assignment.jump_host_rbac_admin
)

# Conservative VM-size candidate lists (Key Decision #14 / Module 1 sizing).
LINUX_VM_CANDIDATES=(Standard_D4s_v5 Standard_D4as_v5 Standard_D2s_v5 Standard_D2as_v5)
WINDOWS_VM_CANDIDATES=(Standard_D4s_v5 Standard_D4as_v5 Standard_D2s_v5 Standard_D2as_v5)

load_env() {
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/.env"
    set +a
  fi
}

require_env_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Required environment variable ${name} is not set. Populate .env from .env-template."
}

admin_suffix() {
  printf '%s-%s-%s\n' "${TF_VAR_project:?}" "${TF_VAR_environment:?}" "${TF_VAR_region_short:?}"
}

admin_resource_group() {
  printf 'rg-%s\n' "$(admin_suffix)"
}

terraform_admin() {
  terraform -chdir="${ADMIN_DIR}" "$@"
}

require_az_ssh_extension() {
  command -v az >/dev/null 2>&1 || die "Azure CLI (az) is required to open the Bastion SSH session."
  if ! az extension show --name ssh --only-show-errors >/dev/null 2>&1; then
    die "Azure CLI extension 'ssh' is required for Bastion SSH. Install it with: az extension add -n ssh"
  fi
}

# ---------------------------------------------------------------------------
# VM size selection (runs before terraform plan/apply).
# ---------------------------------------------------------------------------
sku_available_in_region() {
  local size="$1" region="$2"
  local restrictions
  restrictions="$(az vm list-skus \
    --location "${region}" \
    --resource-type virtualMachines \
    --all \
    --query "[?name=='${size}'] | [0].restrictions" \
    --output json 2>/dev/null || printf 'null')"
  # No entry => not offered in region.
  [[ "${restrictions}" == "null" || -z "${restrictions}" ]] && return 1
  # Any restriction reason means unavailable for this subscription/region.
  if printf '%s' "${restrictions}" | jq -e 'length > 0' >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

select_vm_size() {
  local label="$1" region="$2" override="$3"
  shift 3
  local candidates=("$@")

  if [[ -n "${override}" ]]; then
    if sku_available_in_region "${override}" "${region}"; then
      printf '%s' "${override}"
      return 0
    fi
    die "${label} VM size override '${override}' is not available in ${region} for this subscription. Inspect with: az vm list-skus --location ${region} --resource-type virtualMachines --all --query \"[?name=='${override}']\""
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if sku_available_in_region "${candidate}" "${region}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done

  die "No ${label} VM size candidate is available in ${region} for this subscription. Checked: ${candidates[*]}. Review SKU availability/quota: az vm list-skus --location ${region} --resource-type virtualMachines --all ; az vm list-usage --location ${region}"
}

module_1_sizes() {
  load_env
  require_env_var TF_VAR_azure_location
  command -v az >/dev/null 2>&1 || die "Azure CLI (az) is required for VM size selection."
  command -v jq >/dev/null 2>&1 || die "jq is required for VM size selection."

  local region="${TF_VAR_azure_location}"
  local enable_browser="${TF_VAR_enable_browser_host:-false}"
  local linux_override="${TF_VAR_linux_jump_host_vm_size:-}"
  local windows_override="${TF_VAR_windows_browser_jump_host_vm_size:-}"

  log "Selecting Linux automation jump-host VM size in ${region}..."
  local linux_size
  linux_size="$(select_vm_size "Linux jump host" "${region}" "${linux_override}" "${LINUX_VM_CANDIDATES[@]}")"
  log "Selected Linux jump-host VM size: ${linux_size}"

  local windows_size=""
  if [[ "${enable_browser}" == "true" ]]; then
    log "Selecting Windows browser jump-host VM size in ${region}..."
    windows_size="$(select_vm_size "Windows browser jump host" "${region}" "${windows_override}" "${WINDOWS_VM_CANDIDATES[@]}")"
    log "Selected Windows browser jump-host VM size: ${windows_size}"
  fi

  mkdir -p "${ADMIN_CACHE}"
  jq -n \
    --arg region "${region}" \
    --arg linux "${linux_size}" \
    --arg windows "${windows_size}" \
    --argjson browser_enabled "${enable_browser}" \
    '{
      region: $region,
      linux_jump_host_vm_size: $linux,
      windows_browser_jump_host_vm_size: (if $windows == "" then null else $windows end),
      browser_host_enabled: $browser_enabled
    }' >"${VM_SIZE_SELECTION_JSON}"
  log "Wrote ${VM_SIZE_SELECTION_JSON}"

  # Export for the same shell when sourced; also echo for eval-based capture.
  export TF_VAR_linux_jump_host_vm_size="${linux_size}"
  printf 'TF_VAR_linux_jump_host_vm_size=%s\n' "${linux_size}"
  if [[ -n "${windows_size}" ]]; then
    export TF_VAR_windows_browser_jump_host_vm_size="${windows_size}"
    printf 'TF_VAR_windows_browser_jump_host_vm_size=%s\n' "${windows_size}"
  fi
}

selected_linux_vm_size() {
  if [[ -n "${TF_VAR_linux_jump_host_vm_size:-}" ]]; then
    printf '%s' "${TF_VAR_linux_jump_host_vm_size}"
    return 0
  fi
  if [[ -f "${VM_SIZE_SELECTION_JSON}" ]]; then
    jq -r '.linux_jump_host_vm_size // empty' "${VM_SIZE_SELECTION_JSON}"
    return 0
  fi
  printf ''
}

selected_windows_vm_size() {
  if [[ -n "${TF_VAR_windows_browser_jump_host_vm_size:-}" ]]; then
    printf '%s' "${TF_VAR_windows_browser_jump_host_vm_size}"
    return 0
  fi
  if [[ -f "${VM_SIZE_SELECTION_JSON}" ]]; then
    jq -r '.windows_browser_jump_host_vm_size // empty' "${VM_SIZE_SELECTION_JSON}"
    return 0
  fi
  printf ''
}

# ---------------------------------------------------------------------------
# Admin tfvars rendering.
# ---------------------------------------------------------------------------
render_admin_tfvars() {
  local enable_browser="$1"
  load_env

  local required=(
    TF_VAR_azure_subscription_id
    TF_VAR_azure_tenant_id
    TF_VAR_project
    TF_VAR_environment
    TF_VAR_region_short
    TF_VAR_azure_location
    TF_VAR_anyscale_fqdns
    TF_VAR_azure_identity_fqdns
    TF_VAR_azure_monitor_fqdns
    TF_VAR_container_registry_fqdns
    TF_VAR_linux_jump_host_admin_ssh_public_key
  )
  local name
  for name in "${required[@]}"; do
    require_env_var "${name}"
  done

  local linux_size
  linux_size="$(selected_linux_vm_size)"
  [[ -n "${linux_size}" ]] || die "Linux jump-host VM size is not selected. Run: ./scripts/anyscale-aks.sh module 1 sizes"

  local windows_size
  windows_size="$(selected_windows_vm_size)"
  if [[ "${enable_browser}" == "true" && -z "${windows_size}" ]]; then
    windows_size="Standard_D4s_v5"
  fi

  export TF_VAR_linux_jump_host_vm_size="${linux_size}"
  export TF_VAR_linux_jump_host_admin_username="${TF_VAR_linux_jump_host_admin_username:-azureoperator}"
  export TF_VAR_enable_browser_host="${enable_browser}"
  export TF_VAR_windows_browser_jump_host_vm_size="${windows_size:-Standard_D4s_v5}"
  export TF_VAR_windows_browser_jump_host_admin_username="${TF_VAR_windows_browser_jump_host_admin_username:-azureadmin}"
  export TF_VAR_windows_browser_jump_host_admin_password="${TF_VAR_windows_browser_jump_host_admin_password:-}"
  export TF_VAR_browser_host_vm_user_login_principal_ids="${TF_VAR_browser_host_vm_user_login_principal_ids:-{}}"
  export TF_VAR_browser_host_vm_admin_login_principal_ids="${TF_VAR_browser_host_vm_admin_login_principal_ids:-{}}"
  "${SCRIPTS_DIR}/setup.sh" render
}

terraform_admin_init() {
  if [[ ! -d "${ADMIN_DIR}/.terraform" ]]; then
    log "Initializing Terraform..."
    terraform_admin init -input=false
  fi
}

module_1_plan() {
  local enable_browser="false"
  [[ "${1:-}" == "--enable-browser-host" ]] && enable_browser="true"
  render_admin_tfvars "${enable_browser}"
  terraform_admin_init
  terraform_admin validate
  terraform_admin plan -input=false "${FOUNDATION_TARGETS[@]}"
}

module_1_apply() {
  local enable_browser="false"
  local yes="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --enable-browser-host) enable_browser="true"; shift ;;
      --yes|-y) yes="true"; shift ;;
      *) die "Unknown 'module 1 apply' option: $1" ;;
    esac
  done
  render_admin_tfvars "${enable_browser}"
  terraform_admin_init
  terraform_admin validate
  if [[ "${yes}" == "true" ]]; then
    terraform_admin apply -input=false -auto-approve "${FOUNDATION_TARGETS[@]}"
  else
    terraform_admin apply -input=false "${FOUNDATION_TARGETS[@]}"
  fi
  log "Foundation resources applied. Outputs available via: terraform -chdir=infra/terraform output"
}

admin_output() {
  terraform_admin output -raw "$1" 2>/dev/null || printf ''
}

module_1_connect() {
  load_env
  local vm_id vm_name bastion_name rg
  vm_id="$(admin_output linux_jump_host_vm_id)"
  vm_name="$(admin_output linux_jump_host_vm_name)"
  bastion_name="$(admin_output bastion_name)"
  rg="$(admin_resource_group)"
  [[ -n "${vm_id}" ]] || die "Linux jump-host VM ID not found. Run 'module 1 apply' first."
  [[ -n "${bastion_name}" ]] || die "Bastion name not found in admin outputs."

  local admin_user
  admin_user="$(admin_output linux_jump_host_admin_username)"
  [[ -n "${admin_user}" ]] || admin_user="azureoperator"

  log "Opening a Bastion SSH tunnel to ${vm_name} (${admin_user}@...) — close with Ctrl-C."
  log "Command:"
  printf '  az network bastion ssh --name %q --resource-group %q --target-resource-id %q --auth-type ssh-key --username %q --ssh-key %q\n' \
    "${bastion_name}" "${rg}" "${vm_id}" "${admin_user}" "${SSH_PRIVATE_KEY_PATH:-${HOME}/.ssh/id_ed25519}"

  require_az_ssh_extension
  log "After the Ubuntu welcome banner, confirm the prompt is on ${vm_name}, then run: cd ${ANYSCALE_AKS_REPO_PATH:-/opt/anyscale-aks-sample}"
  az network bastion ssh \
    --name "${bastion_name}" \
    --resource-group "${rg}" \
    --target-resource-id "${vm_id}" \
    --auth-type ssh-key \
    --username "${admin_user}" \
    --ssh-key "${SSH_PRIVATE_KEY_PATH:-${HOME}/.ssh/id_ed25519}"
}

module_1_browser_connect() {
  load_env
  local vm_id vm_name bastion_name rg enabled
  enabled="$(admin_output browser_jump_host_enabled)"
  if [[ "${enabled}" != "true" ]]; then
    die "Browser jump host is not enabled. Re-run: ./scripts/anyscale-aks.sh module 1 apply --enable-browser-host"
  fi
  vm_id="$(admin_output browser_jump_host_vm_id)"
  vm_name="$(admin_output browser_jump_host_vm_name)"
  bastion_name="$(admin_output bastion_name)"
  rg="$(admin_resource_group)"

  log "Windows browser jump host RDP is interactive and runs through the Azure portal Bastion blade."
  log "1. Open the Azure portal and go to the VM: ${vm_name} (resource group ${rg})."
  log "2. Select Connect > Bastion, choose RDP, and sign in with your Entra ID account (no local password needed when you have VM login RBAC)."
  log "3. Inside the desktop, open https://console.azure.anyscale.com to validate private workspace/service URLs."
  log "VM resource ID: ${vm_id}"
  log "Bastion: ${bastion_name}"
  if command -v az >/dev/null 2>&1; then
    local sub
    sub="$(az account show --query id -o tsv 2>/dev/null || printf '')"
    [[ -n "${sub}" ]] && log "Portal link: https://portal.azure.com/#@/resource${vm_id}/bastionHost"
  fi
}

module_1_verify() {
  load_env
  command -v az >/dev/null 2>&1 || die "Azure CLI (az) is required for verification."
  local vm_id pip bastion_name
  vm_id="$(admin_output linux_jump_host_vm_id)"
  [[ -n "${vm_id}" ]] || die "Admin outputs missing. Run 'module 1 apply' first."
  bastion_name="$(admin_output bastion_name)"

  log "Verifying Linux jump host has no public IP..."
  local nic_ids public_ip
  public_ip="$(az vm list-ip-addresses --ids "${vm_id}" \
    --query '[0].virtualMachine.network.publicIpAddresses[].ipAddress' -o tsv 2>/dev/null || printf '')"
  if [[ -n "${public_ip}" ]]; then
    die "Linux jump host unexpectedly has a public IP: ${public_ip}"
  fi
  log "PASS: Linux jump host has no public IP."

  [[ -n "${bastion_name}" ]] && log "PASS: Bastion '${bastion_name}' present for jump-host access."
  log "Note: private DNS resolver targets only resolve from the VM after Module 3 deploys the lab workload."
}

module_1_browser_verify() {
  load_env
  command -v az >/dev/null 2>&1 || die "Azure CLI (az) is required for verification."
  local enabled vm_id
  enabled="$(admin_output browser_jump_host_enabled)"
  if [[ "${enabled}" != "true" ]]; then
    log "Browser jump host is not enabled; nothing to verify. Enable with 'module 1 apply --enable-browser-host'."
    return 0
  fi
  vm_id="$(admin_output browser_jump_host_vm_id)"
  [[ -n "${vm_id}" ]] || die "Browser jump-host VM ID not found in admin outputs."

  log "Verifying Windows browser jump host has no public IP..."
  local public_ip
  public_ip="$(az vm list-ip-addresses --ids "${vm_id}" \
    --query '[0].virtualMachine.network.publicIpAddresses[].ipAddress' -o tsv 2>/dev/null || printf '')"
  [[ -z "${public_ip}" ]] || die "Windows browser jump host unexpectedly has a public IP: ${public_ip}"
  log "PASS: Windows browser jump host has no public IP."

  log "Verifying AADLoginForWindows extension is provisioned..."
  local ext_state
  ext_state="$(az vm extension list --ids "${vm_id}" \
    --query "[?name=='AADLoginForWindows'] | [0].provisioningState" -o tsv 2>/dev/null || printf '')"
  [[ "${ext_state}" == "Succeeded" ]] || die "AADLoginForWindows extension state is '${ext_state:-missing}', expected 'Succeeded'."
  log "PASS: AADLoginForWindows extension Succeeded."

  log "Verifying VM login RBAC assignments..."
  local login_count
  login_count="$(az role assignment list --scope "${vm_id}" \
    --query "[?roleDefinitionName=='Virtual Machine User Login' || roleDefinitionName=='Virtual Machine Administrator Login'] | length(@)" -o tsv 2>/dev/null || printf '0')"
  if [[ "${login_count}" -ge 1 ]]; then
    log "PASS: ${login_count} VM login role assignment(s) present."
  else
    warn "No 'Virtual Machine User Login' / 'Virtual Machine Administrator Login' assignments found on the browser host. Configure browser_host_vm_user_login_principal_ids."
  fi
}

usage() {
  cat <<'USAGE'
Module 1 — Build the foundation and connect to the jump hosts.

Usage:
  ./scripts/anyscale-aks.sh module 1 sizes
  ./scripts/anyscale-aks.sh module 1 plan [--enable-browser-host]
  ./scripts/anyscale-aks.sh module 1 apply [--enable-browser-host] [--yes]
  ./scripts/anyscale-aks.sh module 1 connect
  ./scripts/anyscale-aks.sh module 1 browser connect
  ./scripts/anyscale-aks.sh module 1 verify
  ./scripts/anyscale-aks.sh module 1 browser verify
USAGE
}

main() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    sizes) module_1_sizes "$@" ;;
    plan) module_1_plan "$@" ;;
    apply) module_1_apply "$@" ;;
    connect) module_1_connect "$@" ;;
    verify) module_1_verify "$@" ;;
    browser)
      local b="${1:-}"; shift || true
      case "${b}" in
        connect) module_1_browser_connect "$@" ;;
        verify) module_1_browser_verify "$@" ;;
        *) die "Usage: module 1 browser {connect|verify}" ;;
      esac
      ;;
    ""|--help|-h) usage ;;
    *) die "Unknown 'module 1' subcommand: ${sub}. Run 'module 1 --help'." ;;
  esac
}

main "$@"
