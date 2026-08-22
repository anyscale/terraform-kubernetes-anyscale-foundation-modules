#!/usr/bin/env bash
# Compatibility implementation for deploy, verify, proof, and teardown workflows.
# New workflows should use scripts/anyscale-aks.sh, which delegates here while
# the larger implementation is split into smaller focused modules.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"
GENERATED_TFVARS="${TERRAFORM_DIR}/terraform.auto.tfvars.json"
CACHE_DIR="${ROOT_DIR}/.cache"

LOG_INFO_PREFIX="setup"
# shellcheck source=./lib/log.sh
source "${ROOT_DIR}/scripts/lib/log.sh"
# shellcheck source=./lib/timeout.sh
source "${ROOT_DIR}/scripts/lib/timeout.sh"
# shellcheck source=./lib/azure-cli-env.sh
source "${ROOT_DIR}/scripts/lib/azure-cli-env.sh"
# shellcheck source=./lib/anyscale-job-submit.sh
source "${ROOT_DIR}/scripts/lib/anyscale-job-submit.sh"

cd "${TERRAFORM_DIR}"

ensure_azure_cli_environment

HARNESS_DIR="${CACHE_DIR}/aks-anyscale-sample-harness"
VALIDATION_REPORT_ROOT="${CACHE_DIR}/focused-validation"
DEFAULT_BASTION_TUNNEL_PORT="64430"
DEFAULT_ANYSCALE_HOST="https://console.azure.anyscale.com"
DEFAULT_ANYSCALE_BROWSER_AUTH_HOST="https://console.anyscale.com"
ANYSCALE_CLOUD_TEARDOWN_SCRIPT="${ROOT_DIR}/scripts/lib/anyscale-cloud-teardown.sh"

SETUP_TIMEOUT_TERRAFORM_INIT_SECONDS="${SETUP_TIMEOUT_TERRAFORM_INIT_SECONDS:-900}"
SETUP_TIMEOUT_TERRAFORM_VALIDATE_SECONDS="${SETUP_TIMEOUT_TERRAFORM_VALIDATE_SECONDS:-600}"
SETUP_TIMEOUT_TERRAFORM_TEST_SECONDS="${SETUP_TIMEOUT_TERRAFORM_TEST_SECONDS:-1200}"
SETUP_TIMEOUT_TERRAFORM_PLAN_SECONDS="${SETUP_TIMEOUT_TERRAFORM_PLAN_SECONDS:-1800}"
SETUP_TIMEOUT_TERRAFORM_APPLY_SECONDS="${SETUP_TIMEOUT_TERRAFORM_APPLY_SECONDS:-7200}"
SETUP_TIMEOUT_TERRAFORM_DESTROY_SECONDS="${SETUP_TIMEOUT_TERRAFORM_DESTROY_SECONDS:-7200}"
SETUP_TERRAFORM_RETRY_ATTEMPTS="${SETUP_TERRAFORM_RETRY_ATTEMPTS:-6}"
SETUP_TERRAFORM_RETRY_DELAY_SECONDS="${SETUP_TERRAFORM_RETRY_DELAY_SECONDS:-20}"
SETUP_TIMEOUT_HELM_SECONDS="${SETUP_TIMEOUT_HELM_SECONDS:-900}"
SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS="${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS:-180}"
SETUP_TIMEOUT_ANYSCALE_WORKSPACE_INSPECT_SECONDS="${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_INSPECT_SECONDS:-60}"
SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS="${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS:-1800}"
SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS="${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS:-900}"
SETUP_TIMEOUT_AZURE_EXTENSION_SECONDS="${SETUP_TIMEOUT_AZURE_EXTENSION_SECONDS:-300}"
SETUP_TIMEOUT_AZURE_COMMAND_SECONDS="${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS:-180}"
SETUP_TIMEOUT_AKS_PREVIEW_FEATURE_SECONDS="${SETUP_TIMEOUT_AKS_PREVIEW_FEATURE_SECONDS:-3600}"
SETUP_TIMEOUT_KUBECTL_READY_SECONDS="${SETUP_TIMEOUT_KUBECTL_READY_SECONDS:-20}"

FOCUSED_VALIDATION_RUN_ID=""
FOCUSED_VALIDATION_RESULTS=()
FOCUSED_VALIDATION_PASS_COUNT=0
FOCUSED_VALIDATION_FAIL_COUNT=0
FOCUSED_VALIDATION_SKIP_COUNT=0
ANYSCALE_WORKSPACE_WAIT_RESULT=""
DEPLOY_E2E_STARTED_TUNNEL=0
SETUP_RUN_DIR=""
SETUP_STAGE_LOG_DIR=""
SETUP_STAGE_INDEX=0
SETUP_STAGE_TOTAL=0
SETUP_STAGE_RESULTS=()
WORKLOAD_LAST_HEAD_POD=""

escape_env_single_quoted() {
  # Escape single quotes for inclusion in a single-quoted shell string.
  # ' becomes '\'' (close quote, escaped quote, reopen quote).
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

shell_join() {
  local joined=""
  local arg

  for arg in "$@"; do
    printf -v joined '%s%q ' "${joined}" "${arg}"
  done

  printf '%s\n' "${joined% }"
}

write_export_env_script() {
  local output_file="$1"
  shift

  : > "${output_file}"

  local env_spec env_name env_value
  for env_spec in "$@"; do
    [[ "${env_spec}" == *=* ]] || die "Expected environment assignment in KEY=VALUE form, got '${env_spec}'."
    env_name="${env_spec%%=*}"
    env_value="${env_spec#*=}"
    [[ "${env_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "Invalid environment variable name '${env_name}'."
    printf 'export %s=%q\n' "${env_name}" "${env_value}" >> "${output_file}"
  done
}

set_env_file_var() {
  local name="$1"
  local value="$2"
  local escaped_value tmp_file

  # Persist values as single-quoted shell strings. JSON values never contain
  # a literal single quote, so this round-trips cleanly through `source`.
  # Pass name/line through ENVIRON to avoid awk's -v backslash processing,
  # which previously stripped escaping from JSON values containing " characters.
  escaped_value="$(escape_env_single_quoted "${value}")"
  mkdir -p "${CACHE_DIR}"
  tmp_file="${CACHE_DIR}/.env.sync.$$"

  ENV_LINE_NAME="${name}" ENV_LINE_TEXT="${name}='${escaped_value}'" \
  awk '
    BEGIN { name = ENVIRON["ENV_LINE_NAME"]; line = ENVIRON["ENV_LINE_TEXT"] }
    index($0, name "=") == 1 { print line; updated = 1; next }
    { print }
    END {
      if (!updated) {
        print line
      }
    }
  ' "${ENV_FILE}" > "${tmp_file}"

  mv "${tmp_file}" "${ENV_FILE}"
}

export_kubeconfig_env() {
  local kubeconfig_path="$1"

  export KUBECONFIG="${kubeconfig_path}"
  export KUBE_CONFIG_PATH="${kubeconfig_path}"
}

resource_group_name() {
  printf 'rg-%s-%s-%s\n' \
    "${TF_VAR_project}" \
    "${TF_VAR_environment}" \
    "${TF_VAR_region_short}"
}

target_aks_cluster_name() {
  printf 'aks-%s-%s-%s\n' \
    "${TF_VAR_project}" \
    "${TF_VAR_environment}" \
    "${TF_VAR_region_short}"
}

current_azure_principal_object_id() {
  # Managed-identity-safe identity detection. Works for user, service principal,
  # and managed identity Azure CLI logins (the jump host runs as a managed identity).
  local account_type principal_id client_id

  account_type="$(az account show --query user.type -o tsv --only-show-errors 2>/dev/null || true)"

  case "${account_type}" in
    user)
      principal_id="$(az ad signed-in-user show --query id -o tsv --only-show-errors 2>/dev/null || true)"
      ;;
    servicePrincipal)
      # user.name holds the SP / managed-identity client id; resolve to the object id.
      client_id="$(az account show --query user.name -o tsv --only-show-errors 2>/dev/null || true)"
      if [[ -n "${client_id}" ]]; then
        principal_id="$(az ad sp show --id "${client_id}" --query id -o tsv --only-show-errors 2>/dev/null || true)"
      fi
      ;;
  esac

  # Last resort: try the signed-in user lookup.
  if [[ -z "${principal_id:-}" ]]; then
    principal_id="$(az ad signed-in-user show --query id -o tsv --only-show-errors 2>/dev/null || true)"
  fi

  # Graph-free fallback: read the oid claim from an ARM access token. The
  # jump-host managed identity cannot read Microsoft Graph (az ad sp show /
  # signed-in-user need Directory read permission), but every ARM access token
  # carries the caller's object id in its oid claim.
  if [[ -z "${principal_id:-}" ]]; then
    local token payload rem decoded
    token="$(az account get-access-token --query accessToken -o tsv --only-show-errors 2>/dev/null || true)"
    if [[ -n "${token}" && "${token}" == *.*.* ]]; then
      payload="${token#*.}"
      payload="${payload%%.*}"
      payload="${payload//-/+}"
      payload="${payload//_//}"
      rem=$(( ${#payload} % 4 ))
      if [[ ${rem} -eq 2 ]]; then payload="${payload}=="
      elif [[ ${rem} -eq 3 ]]; then payload="${payload}="; fi
      decoded="$(printf '%s' "${payload}" | base64 -d 2>/dev/null || true)"
      if [[ -n "${decoded}" ]]; then
        principal_id="$(jq -r '.oid // empty' <<<"${decoded}" 2>/dev/null || true)"
      fi
    fi
  fi

  printf '%s' "${principal_id:-}"
}

aks_cluster_exists_for_target() {
  local resource_group cluster_name

  resource_group="$(resource_group_name)"
  cluster_name="$(target_aks_cluster_name)"

  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az aks show \
      --resource-group "${resource_group}" \
      --name "${cluster_name}" \
      --query name \
      --output tsv \
      --only-show-errors >/dev/null 2>&1
}

default_anyscale_host() {
  printf '%s\n' "${DEFAULT_ANYSCALE_HOST}"
}

default_anyscale_browser_auth_host() {
  printf '%s\n' "${DEFAULT_ANYSCALE_BROWSER_AUTH_HOST}"
}

# Anyscale uses three related identifiers for the same cloud:
# - cloud resource name: the short leaf name under the resource group
# - cloud name: the canonical path expected by the Anyscale CLI env var
# - cloud ARM id: the Azure resource ID used by az/terraform import flows
default_anyscale_cloud_name() {
  printf '/subscriptions/%s/resourcegroups/%s/providers/anyscale.platform/clouds/%s\n' \
    "${TF_VAR_azure_subscription_id}" \
    "$(resource_group_name)" \
    "$(default_anyscale_cloud_resource_name)"
}

default_anyscale_cloud_resource_name() {
  printf '%s-%s-%s\n' \
    "${TF_VAR_project}" \
    "${TF_VAR_environment}" \
    "${TF_VAR_region_short}"
}

default_anyscale_cloud_arm_id() {
  printf '/subscriptions/%s/resourceGroups/%s/providers/Anyscale.Platform/clouds/%s\n' \
    "${TF_VAR_azure_subscription_id}" \
    "$(resource_group_name)" \
    "$(default_anyscale_cloud_resource_name)"
}

anyscale_cloud_resource_azure_id() {
  local resource_group cloud_name
  resource_group="$(resource_group_name)"
  cloud_name="$(default_anyscale_cloud_resource_name)"

  printf '/subscriptions/%s/resourceGroups/%s/providers/Anyscale.Platform/clouds/%s/cloudResources/default\n' \
    "${TF_VAR_azure_subscription_id}" \
    "${resource_group}" \
    "${cloud_name}"
}

sync_anyscale_cli_env() {
  local derived_cloud_name derived_cloud_resource_name derived_cloud_arm_id
  local cloud_resource_azure_id live_cloud_deployment_id

  [[ -n "${TF_VAR_project:-}" ]] || return 0
  [[ -n "${TF_VAR_environment:-}" ]] || return 0
  [[ -n "${TF_VAR_region_short:-}" ]] || return 0
  [[ -n "${TF_VAR_azure_subscription_id:-}" ]] || return 0

  if [[ -z "${ANYSCALE_HOST:-}" || "${ANYSCALE_HOST}" == "https://console.anyscale.com" ]]; then
    ANYSCALE_HOST="$(default_anyscale_host)"
    export ANYSCALE_HOST
    set_env_file_var "ANYSCALE_HOST" "${ANYSCALE_HOST}"
    log "Auto-populated ANYSCALE_HOST=${ANYSCALE_HOST}"
  fi

  derived_cloud_name="$(default_anyscale_cloud_name)"
  derived_cloud_resource_name="$(default_anyscale_cloud_resource_name)"
  derived_cloud_arm_id="$(default_anyscale_cloud_arm_id)"
  if [[ -z "${ANYSCALE_CLOUD_NAME:-}" || "${ANYSCALE_CLOUD_NAME}" == "my-aks-cloud" || "${ANYSCALE_CLOUD_NAME}" == "${derived_cloud_resource_name}" || "${ANYSCALE_CLOUD_NAME}" == "${derived_cloud_arm_id}" ]]; then
    ANYSCALE_CLOUD_NAME="${derived_cloud_name}"
    export ANYSCALE_CLOUD_NAME
    set_env_file_var "ANYSCALE_CLOUD_NAME" "${ANYSCALE_CLOUD_NAME}"
    log "Auto-populated ANYSCALE_CLOUD_NAME=${ANYSCALE_CLOUD_NAME}"
  fi

  command -v az >/dev/null 2>&1 || return 0

  cloud_resource_azure_id="$(anyscale_cloud_resource_azure_id)"
  live_cloud_deployment_id="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az resource show \
    --ids "${cloud_resource_azure_id}" \
    --query 'properties.cloudResourceId' \
    --output tsv \
    --only-show-errors 2>/dev/null || true)"

  if [[ -n "${live_cloud_deployment_id}" && "${live_cloud_deployment_id}" != "${ANYSCALE_CLOUD_DEPLOYMENT_ID:-}" ]]; then
    ANYSCALE_CLOUD_DEPLOYMENT_ID="${live_cloud_deployment_id}"
    export ANYSCALE_CLOUD_DEPLOYMENT_ID
    set_env_file_var "ANYSCALE_CLOUD_DEPLOYMENT_ID" "${ANYSCALE_CLOUD_DEPLOYMENT_ID}"
    log "Auto-populated ANYSCALE_CLOUD_DEPLOYMENT_ID from Azure resource ${ANYSCALE_CLOUD_NAME}"
  fi
}

clear_anyscale_cloud_deployment_id() {
  [[ -f "${ENV_FILE}" ]] || return 0
  [[ -n "${ANYSCALE_CLOUD_DEPLOYMENT_ID:-}" ]] || return 0

  ANYSCALE_CLOUD_DEPLOYMENT_ID=""
  export ANYSCALE_CLOUD_DEPLOYMENT_ID
  set_env_file_var "ANYSCALE_CLOUD_DEPLOYMENT_ID" ""
  log "Cleared ANYSCALE_CLOUD_DEPLOYMENT_ID after Anyscale cloud removal"
}

canonicalize_gpu_pool_configs_json() {
  local raw_value="$1"
  local candidate_json

  if candidate_json="$(jq -c . <<<"${raw_value}" 2>/dev/null)"; then
    printf '%s\n' "${candidate_json}"
    return 0
  fi

  candidate_json="$(printf '%s' "${raw_value}" \
    | sed -E 's/([{,])([A-Za-z0-9_]+):/\1"\2":/g' \
    | sed -E 's/"(name|vm_size|product_name|gpu_count)":([A-Za-z0-9_.-]+)/"\1":"\2"/g')"

  jq -c . <<<"${candidate_json}" 2>/dev/null || return 1
}

# A CPU-only deploy is a supported shape, not a degraded one: an empty
# gpu_pool_configs map means no GPU node pools, no device plugin, no GPU
# workspace, and no GPU proofs. Everything else in the sample — private AKS,
# firewall egress, private storage/ACR, Gateway, TLS, the CPU proof and the
# build job — is unaffected, so an operator without T4 quota can still run the
# reference end to end.
#
# Keyed on the Terraform input itself rather than a second enable flag, so the
# two can never disagree about what was actually deployed.
gpu_pools_enabled() {
  local canonical_gpu_pool_configs
  [[ -n "${TF_VAR_gpu_pool_configs:-}" ]] || return 1
  canonical_gpu_pool_configs="$(canonicalize_gpu_pool_configs_json "${TF_VAR_gpu_pool_configs}")" || return 1
  [[ "$(jq -r 'length' <<<"${canonical_gpu_pool_configs}")" != "0" ]]
}

# One place to explain the skip, so every surface says the same thing.
gpu_disabled_notice() {
  printf 'no GPU node pool is configured (TF_VAR_gpu_pool_configs is empty). Set it in .env to a pool your quota supports and re-run deploy to enable the GPU path.'
}

normalize_gpu_pool_configs_min_count() {
  [[ -n "${TF_VAR_gpu_pool_configs:-}" ]] || return 0
  gpu_pools_enabled || return 0

  local canonical_gpu_pool_configs normalized_gpu_pool_configs
  canonical_gpu_pool_configs="$(canonicalize_gpu_pool_configs_json "${TF_VAR_gpu_pool_configs}")" \
    || die "TF_VAR_gpu_pool_configs must be valid JSON or Terraform-style object syntax."
  normalized_gpu_pool_configs="$(jq -c 'with_entries(.value.min_count |= (if . < 1 then 1 else . end))' <<<"${canonical_gpu_pool_configs}")"

  if [[ "${normalized_gpu_pool_configs}" != "${TF_VAR_gpu_pool_configs}" ]]; then
    TF_VAR_gpu_pool_configs="${normalized_gpu_pool_configs}"
    export TF_VAR_gpu_pool_configs
    set_env_file_var "TF_VAR_gpu_pool_configs" "${TF_VAR_gpu_pool_configs}"
    log "Normalized TF_VAR_gpu_pool_configs so every GPU pool min_count is at least 1"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found on PATH."
}

load_env() {
  local preserve_anyscale_platform=false
  local anyscale_platform_override=""
  local preserve_anyscale_cli_token="${ANYSCALE_CLI_TOKEN:-}"
  local preserve_tf_var_anyscale_cli_token="${TF_VAR_anyscale_cli_token:-}"
  local preserve_anyscale_host="${ANYSCALE_HOST:-}"
  local preserve_anyscale_cloud_name="${ANYSCALE_CLOUD_NAME:-}"
  local preserve_anyscale_cloud_deployment_id="${ANYSCALE_CLOUD_DEPLOYMENT_ID:-}"
  local preserved_custom_image_names=()
  local preserved_custom_image_values=()
  local custom_image_name preserved_index

  if [[ ${TF_VAR_anyscale_platform+x} ]]; then
    preserve_anyscale_platform=true
    anyscale_platform_override="${TF_VAR_anyscale_platform}"
  fi
  for custom_image_name in \
    ANYSCALE_CUSTOM_IMAGE_ENABLED \
    ANYSCALE_CUSTOM_IMAGE_REPOSITORY \
    ANYSCALE_CUSTOM_IMAGE_TAG \
    ANYSCALE_CUSTOM_IMAGE_RAY_VERSION \
    ANYSCALE_CUSTOM_IMAGE_REQUIREMENT \
    ANYSCALE_CUSTOM_IMAGE_BUILD_MODE \
    ANYSCALE_CUSTOM_IMAGE_URI; do
    if [[ ${!custom_image_name+x} ]]; then
      preserved_custom_image_names+=("${custom_image_name}")
      preserved_custom_image_values+=("${!custom_image_name}")
    fi
  done

  [[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}. Copy .env-template to .env and fill in the required values."
  # shellcheck disable=SC1090
  set +u
  set -a
  source "${ENV_FILE}"
  set +a
  set -u

  # Preserve the phase-scoped platform override after sourcing .env so callers
  # can temporarily disable or enable the Anyscale platform layer per deploy phase.
  if [[ "${preserve_anyscale_platform}" == true ]]; then
    TF_VAR_anyscale_platform="${anyscale_platform_override}"
    export TF_VAR_anyscale_platform
  fi
  for preserved_index in "${!preserved_custom_image_names[@]}"; do
    printf -v "${preserved_custom_image_names[${preserved_index}]}" '%s' "${preserved_custom_image_values[${preserved_index}]}"
    export "${preserved_custom_image_names[${preserved_index}]}"
  done

  if [[ -z "${ANYSCALE_HOST:-}" || "${ANYSCALE_HOST}" == "https://console.anyscale.com" ]]; then
    ANYSCALE_HOST="$(default_anyscale_host)"
    export ANYSCALE_HOST
  fi

  if [[ -n "${preserve_anyscale_cli_token}" ]]; then
    ANYSCALE_CLI_TOKEN="${preserve_anyscale_cli_token}"
    export ANYSCALE_CLI_TOKEN
  elif [[ -z "${ANYSCALE_CLI_TOKEN:-}" ]]; then
    unset ANYSCALE_CLI_TOKEN
  fi
  if [[ -n "${preserve_tf_var_anyscale_cli_token}" ]]; then
    TF_VAR_anyscale_cli_token="${preserve_tf_var_anyscale_cli_token}"
    export TF_VAR_anyscale_cli_token
  elif [[ -z "${TF_VAR_anyscale_cli_token:-}" ]]; then
    unset TF_VAR_anyscale_cli_token
  fi
  if [[ -n "${preserve_anyscale_host}" ]]; then
    ANYSCALE_HOST="${preserve_anyscale_host}"
    export ANYSCALE_HOST
  fi
  if [[ -n "${preserve_anyscale_cloud_name}" ]]; then
    ANYSCALE_CLOUD_NAME="${preserve_anyscale_cloud_name}"
    export ANYSCALE_CLOUD_NAME
  fi
  if [[ -n "${preserve_anyscale_cloud_deployment_id}" ]]; then
    ANYSCALE_CLOUD_DEPLOYMENT_ID="${preserve_anyscale_cloud_deployment_id}"
    export ANYSCALE_CLOUD_DEPLOYMENT_ID
  fi

  ANYSCALE_CUSTOM_IMAGE_ENABLED="${ANYSCALE_CUSTOM_IMAGE_ENABLED:-false}"
  ANYSCALE_CUSTOM_IMAGE_REPOSITORY="${ANYSCALE_CUSTOM_IMAGE_REPOSITORY:-anyscale/proof-custom}"
  ANYSCALE_CUSTOM_IMAGE_TAG="${ANYSCALE_CUSTOM_IMAGE_TAG:-onnxruntime-1.22.0-ray-2.55.1-py312-cu129}"
  ANYSCALE_CUSTOM_IMAGE_RAY_VERSION="${ANYSCALE_CUSTOM_IMAGE_RAY_VERSION:-2.55.1}"
  ANYSCALE_CUSTOM_IMAGE_REQUIREMENT="${ANYSCALE_CUSTOM_IMAGE_REQUIREMENT:-onnxruntime==1.22.0}"
  ANYSCALE_CUSTOM_IMAGE_BUILD_MODE="${ANYSCALE_CUSTOM_IMAGE_BUILD_MODE:-podman}"
  ANYSCALE_CUSTOM_IMAGE_URI="${ANYSCALE_CUSTOM_IMAGE_URI:-}"
  export ANYSCALE_CUSTOM_IMAGE_ENABLED ANYSCALE_CUSTOM_IMAGE_REPOSITORY ANYSCALE_CUSTOM_IMAGE_TAG
  export ANYSCALE_CUSTOM_IMAGE_RAY_VERSION ANYSCALE_CUSTOM_IMAGE_REQUIREMENT ANYSCALE_CUSTOM_IMAGE_BUILD_MODE
  export ANYSCALE_CUSTOM_IMAGE_URI

  # Image signing (Notation + Key Vault) / AKS Image Integrity defaults. These
  # mirror the Terraform variables image_signing_cert_name / _subject.
  ANYSCALE_SIGNING_CERT_NAME="${ANYSCALE_SIGNING_CERT_NAME:-notation-signing-cert-v2}"
  ANYSCALE_SIGNING_CERT_STORE_NAME="${ANYSCALE_SIGNING_CERT_STORE_NAME:-anyscale-aks}"
  ANYSCALE_SIGNING_CERT_SUBJECT="${ANYSCALE_SIGNING_CERT_SUBJECT:-CN=anyscale-private-aks-signing,O=AnyscaleAKSSample,ST=WA,C=US}"
  ANYSCALE_SIGNING_CERT_VALIDITY_MONTHS="${ANYSCALE_SIGNING_CERT_VALIDITY_MONTHS:-12}"
  export ANYSCALE_SIGNING_CERT_NAME ANYSCALE_SIGNING_CERT_STORE_NAME ANYSCALE_SIGNING_CERT_SUBJECT
  export ANYSCALE_SIGNING_CERT_VALIDITY_MONTHS

  # The shell reads these two directly (workspace registration, kubectl calls),
  # so they need a value even when .env omits them and Terraform supplies its own
  # default. Must stay in sync with anyscale_operator_namespace /
  # anyscale_operator_serviceaccount in infra/terraform/variables.tf.
  TF_VAR_anyscale_operator_namespace="${TF_VAR_anyscale_operator_namespace:-anyscale-operator}"
  TF_VAR_anyscale_operator_serviceaccount="${TF_VAR_anyscale_operator_serviceaccount:-anyscale-operator}"
  export TF_VAR_anyscale_operator_namespace TF_VAR_anyscale_operator_serviceaccount

  # Catch an unedited .env here rather than at the first Azure call: ARM_* drives
  # authentication for every stage, not just the Terraform render.
  reject_placeholder_guid ARM_SUBSCRIPTION_ID
  reject_placeholder_guid ARM_TENANT_ID
  reject_placeholder_guid TF_VAR_azure_subscription_id
  reject_placeholder_guid TF_VAR_azure_tenant_id
}

# The all-zero GUID .env-template ships for the Azure ids. Left in place it fails
# deep inside Terraform or the Azure CLI, long after a deploy has started, so
# every path that reads these values rejects it up front instead.
PLACEHOLDER_GUID="00000000-0000-0000-0000-000000000000"

reject_placeholder_guid() {
  local name="$1"
  [[ "${!name:-}" == "${PLACEHOLDER_GUID}" ]] || return 0
  die "${name} in ${ENV_FILE} is still the all-zero placeholder from .env-template. Run './scripts/anyscale-aks.sh init' to fill it from your signed-in Azure context, or set it by hand."
}

require_env_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Missing required environment variable ${name} in ${ENV_FILE}."
  reject_placeholder_guid "${name}"
}

# Only inputs the harness must derive locally belong here. Plain constants live
# in infra/terraform/variables.tf; render_tfvars omits unset keys so those
# defaults apply.
apply_lab_tfvar_defaults() {
  if [[ -z "${TF_VAR_linux_jump_host_admin_ssh_public_key:-}" ]]; then
    local ssh_public_key_path="${SSH_PRIVATE_KEY_PATH:-${HOME}/.ssh/id_ed25519}.pub"
    [[ -f "${ssh_public_key_path}" ]] || die "Missing TF_VAR_linux_jump_host_admin_ssh_public_key and SSH public key ${ssh_public_key_path}."
    TF_VAR_linux_jump_host_admin_ssh_public_key="$(<"${ssh_public_key_path}")"
    export TF_VAR_linux_jump_host_admin_ssh_public_key
  fi

  # Backfill the jump-host subnet CIDRs for older .env files created before the
  # single-root merge added them to subnet_cidrs. Only fills keys that are absent;
  # values match the .env-template defaults.
  if [[ -n "${TF_VAR_subnet_cidrs:-}" ]]; then
    TF_VAR_subnet_cidrs="$(jq -c \
      '(.jump_host //= "10.50.3.0/27") | (.browser_jump_host //= "10.50.3.32/27")' \
      <<<"${TF_VAR_subnet_cidrs}")"
    export TF_VAR_subnet_cidrs
  fi
}

TFVARS_JSON="{}"

# tfvars_put_* emit a key only when its TF_VAR_* env var is set and non-empty.
# Unset keys are omitted from the rendered file so the default in
# infra/terraform/variables.tf applies. Terraform is the single source of truth
# for defaults: do not re-declare a Terraform default here or in .env-template.
tfvars_put_string() {
  local key="$1" var="TF_VAR_$1" value
  value="${!var:-}"
  [[ -n "${value}" ]] || return 0
  TFVARS_JSON="$(jq --arg k "${key}" --arg v "${value}" '.[$k] = $v' <<<"${TFVARS_JSON}")"
}

tfvars_put_json() {
  local key="$1" var="TF_VAR_$1" value
  value="${!var:-}"
  [[ -n "${value}" ]] || return 0
  TFVARS_JSON="$(jq --arg k "${key}" --argjson v "${value}" '.[$k] = $v' <<<"${TFVARS_JSON}" 2>/dev/null)" \
    || die "TF_VAR_${key} in ${ENV_FILE} is not valid JSON: ${value}"
}

render_tfvars() {
  load_env

  # Only inputs with no sensible default live here. Everything else is optional
  # and falls through to infra/terraform/variables.tf when absent from .env.
  # This list must stay in sync with the variables in variables.tf that declare
  # no default (linux_jump_host_admin_ssh_public_key is derived below instead).
  local required_env_vars=(
    TF_VAR_azure_subscription_id
    TF_VAR_azure_tenant_id
    TF_VAR_project
    TF_VAR_environment
    TF_VAR_azure_location
    TF_VAR_region_short
    TF_VAR_vnet_address_space
    TF_VAR_subnet_cidrs
    TF_VAR_system_vm_size
    TF_VAR_cpu_vm_size
    TF_VAR_gpu_pool_configs
  )

  # tool_bootstrap_fqdns is intentionally not in the rendered set. Like the
  # composite anyscale_platform/bootstrap_k8s overrides, it is applied through an
  # exported TF_VAR_ env var when set; its default lives in
  # infra/terraform/variables.tf and matches scripts/bootstrap-jump-host.sh.
  local env_name
  for env_name in "${required_env_vars[@]}"; do
    require_env_var "${env_name}"
  done

  # anyscale_platform_default_admin_assignment, anyscale_platform_role_assignments,
  # and anyscale_platform_admin_role_assignments intentionally have no shell-side
  # default: when unset they are omitted below and variables.tf supplies the
  # default (subscription-scoped Platform Administrator, and empty maps).

  normalize_gpu_pool_configs_min_count
  sync_anyscale_cli_env
  apply_lab_tfvar_defaults

  if [[ -z "${TF_VAR_anyscale_cli_token:-}" && -n "${ANYSCALE_CLI_TOKEN:-}" ]]; then
    TF_VAR_anyscale_cli_token="${ANYSCALE_CLI_TOKEN}"
    export TF_VAR_anyscale_cli_token
  fi

  TFVARS_JSON="{}"

  # Required inputs (validated above).
  tfvars_put_string azure_subscription_id
  tfvars_put_string azure_tenant_id
  tfvars_put_string project
  tfvars_put_string environment
  tfvars_put_string azure_location
  tfvars_put_string region_short
  tfvars_put_string system_vm_size
  tfvars_put_string cpu_vm_size
  tfvars_put_json vnet_address_space
  tfvars_put_json subnet_cidrs
  tfvars_put_json gpu_pool_configs

  # Optional inputs. Omitted when unset so variables.tf supplies the default.
  tfvars_put_string aks_sku_tier
  tfvars_put_string service_cidr
  tfvars_put_string dns_service_ip
  tfvars_put_string anyscale_operator_namespace
  tfvars_put_string anyscale_operator_serviceaccount
  tfvars_put_string storage_replication_type
  tfvars_put_string ampls_ingestion_access_mode
  tfvars_put_string ampls_query_access_mode
  tfvars_put_string container_insights_data_collection_interval
  tfvars_put_string container_insights_namespace_filtering_mode
  tfvars_put_string linux_jump_host_vm_size
  tfvars_put_string linux_jump_host_admin_username
  tfvars_put_string linux_jump_host_admin_ssh_public_key
  tfvars_put_string linux_jump_host_custom_data
  tfvars_put_string windows_browser_jump_host_vm_size
  tfvars_put_string windows_browser_jump_host_admin_username
  tfvars_put_string windows_browser_jump_host_admin_password
  tfvars_put_string jump_host_rbac_scope
  tfvars_put_string anyscale_cli_token

  tfvars_put_json anyscale_operator_identity
  tfvars_put_json dns_forwarding_rules
  tfvars_put_json anyscale_fqdns
  tfvars_put_json azure_identity_fqdns
  tfvars_put_json azure_monitor_fqdns
  tfvars_put_json container_registry_fqdns
  tfvars_put_json availability_zones
  tfvars_put_json system_node_pool_min_count
  tfvars_put_json system_node_pool_max_count
  tfvars_put_json kubernetes_version
  tfvars_put_json storage_cors_rule
  tfvars_put_json acr_zone_redundancy_enabled
  tfvars_put_json log_analytics_retention_days
  tfvars_put_json log_analytics_internet_ingestion_enabled
  tfvars_put_json log_analytics_internet_query_enabled
  tfvars_put_json ampls_enabled
  tfvars_put_json container_insights_v2_enabled
  tfvars_put_json container_insights_streams
  tfvars_put_json container_insights_namespaces
  tfvars_put_json terraform_managed_diagnostic_settings_enabled
  tfvars_put_json enable_browser_host
  tfvars_put_json browser_host_vm_user_login_principal_ids
  tfvars_put_json browser_host_vm_admin_login_principal_ids
  tfvars_put_json assign_jump_host_subscription_contributor
  tfvars_put_json assign_jump_host_rbac_admin
  tfvars_put_json anyscale_platform_default_admin_assignment
  tfvars_put_json anyscale_platform_role_assignments
  tfvars_put_json anyscale_platform_admin_role_assignments
  tfvars_put_json tags
  tfvars_put_json assign_current_principal_cluster_access
  tfvars_put_json aks_cluster_admin_principal_ids
  tfvars_put_json aks_cluster_user_principal_ids
  tfvars_put_json acr_cache_rules

  tfvars_put_json enable_anyscale_privatelink
  tfvars_put_string anyscale_privatelink_service_alias
  tfvars_put_string anyscale_privatelink_dns_zone_name
  tfvars_put_json anyscale_privatelink_record_names

  printf '%s\n' "${TFVARS_JSON}" > "${GENERATED_TFVARS}"

  log "Rendered ${GENERATED_TFVARS}"
}

terraform_output_raw() {
  terraform output -raw "$1"
}

terraform_output_json() {
  terraform output -json "$1"
}

anyscale_platform_deployment_name() {
  printf 'dep-anyscale-%s-%s-%s\n' \
    "${TF_VAR_project}" \
    "${TF_VAR_environment}" \
    "${TF_VAR_region_short}"
}

anyscale_platform_deployment_resource_id() {
  local resource_group deployment_name
  resource_group="$(resource_group_name)"
  deployment_name="$(anyscale_platform_deployment_name)"

  printf '/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Resources/deployments/%s\n' \
    "${TF_VAR_azure_subscription_id}" \
    "${resource_group}" \
    "${deployment_name}"
}

anyscale_platform_enabled() {
  if [[ -z "${TF_VAR_anyscale_platform:-}" ]]; then
    return 0
  fi

  jq -e 'if type == "object" and has("enabled") then .enabled else true end' <<<"${TF_VAR_anyscale_platform}" >/dev/null 2>&1
}

ensure_anyscale_marketplace_agreement_accepted() {
  # Marketplace agreements are subscription-scoped and survive resource-group
  # teardowns, so they live outside Terraform state. Check current acceptance,
  # skip silently if already accepted, otherwise prompt the user (or auto-accept
  # when --yes was supplied) and call az to record acceptance.
  local publisher="anyscale1750870039553"
  local offer="anyscale-operator-aks"
  local plan="anyscale-operator"
  local terms_json accepted license_link privacy_link prompt_response

  anyscale_platform_enabled || return 0

  terms_json="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az vm image terms show \
    --subscription "${TF_VAR_azure_subscription_id}" \
    --publisher "${publisher}" \
    --offer "${offer}" \
    --plan "${plan}" \
    --only-show-errors 2>/dev/null || true)"

  if [[ -n "${terms_json}" ]]; then
    accepted="$(jq -r '.accepted // false' <<<"${terms_json}" 2>/dev/null || echo "false")"
    if [[ "${accepted}" == "true" ]]; then
      return 0
    fi
    license_link="$(jq -r '.licenseTextLink // ""' <<<"${terms_json}" 2>/dev/null || echo "")"
    privacy_link="$(jq -r '.privacyPolicyLink // ""' <<<"${terms_json}" 2>/dev/null || echo "")"
  fi

  log "Anyscale operator marketplace agreement has not been accepted on subscription ${TF_VAR_azure_subscription_id}"
  log "  Publisher: ${publisher}"
  log "  Offer:     ${offer}"
  log "  Plan:      ${plan}"
  [[ -n "${license_link}" ]] && log "  Terms:     ${license_link}"
  [[ -n "${privacy_link}" ]] && log "  Privacy:   ${privacy_link}"

  if [[ "${DEPLOY_FORCE_YES:-false}" == true ]]; then
    log "Auto-accepting marketplace agreement (--yes supplied)"
  else
    printf 'Accept the Anyscale marketplace agreement? [y/N]: '
    IFS= read -r prompt_response || die "Marketplace agreement is required for the Anyscale operator AKS extension."
    case "${prompt_response}" in
      y|Y|yes|YES|Yes) ;;
      *) die "Marketplace agreement not accepted; cannot install the Anyscale operator AKS extension. Re-run when ready to accept." ;;
    esac
  fi

  log "Recording marketplace agreement acceptance on subscription ${TF_VAR_azure_subscription_id}"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az vm image terms accept \
    --subscription "${TF_VAR_azure_subscription_id}" \
    --publisher "${publisher}" \
    --offer "${offer}" \
    --plan "${plan}" \
    --only-show-errors >/dev/null
}

anyscale_platform_extension_resource_name() {
  local platform_config="${TF_VAR_anyscale_platform:-}"
  local inferred_name="anyscaleoperator"

  if [[ -n "${platform_config}" ]]; then
    inferred_name="$(jq -r '.extension_resource_name // empty' <<<"${platform_config}" 2>/dev/null || true)"
  fi

  if [[ -n "${inferred_name}" && "${inferred_name}" != "null" ]]; then
    printf '%s\n' "${inferred_name}"
  else
    printf '%s\n' "anyscaleoperator"
  fi
}

ensure_anyscale_platform_role_assignment_state() {
  local resource_address='azurerm_role_assignment.anyscale_platform["current_principal_admin"]'
  local scope assignment_id current_principal_id admin_assignment_json assignment_scope

  anyscale_platform_enabled || return 0
  terraform state show "${resource_address}" >/dev/null 2>&1 && return 0

  current_principal_id="$(current_azure_principal_object_id)"
  [[ -n "${current_principal_id}" ]] || return 0

  admin_assignment_json="${TF_VAR_anyscale_platform_default_admin_assignment:-}"
  assignment_scope="subscription"
  if [[ -n "${admin_assignment_json}" ]]; then
    assignment_scope="$(jq -r '.scope // "subscription"' <<<"${admin_assignment_json}" 2>/dev/null || true)"
  fi

  case "${assignment_scope}" in
    subscription)
      scope="/subscriptions/${TF_VAR_azure_subscription_id}"
      ;;
    resource_group)
      scope="/subscriptions/${TF_VAR_azure_subscription_id}/resourceGroups/$(resource_group_name)"
      ;;
    cloud)
      scope="$(default_anyscale_cloud_arm_id)"
      ;;
    custom)
      scope="$(jq -r '.custom_scope // empty' <<<"${admin_assignment_json}" 2>/dev/null || true)"
      ;;
    *)
      scope="/subscriptions/${TF_VAR_azure_subscription_id}"
      ;;
  esac

  [[ -n "${scope}" ]] || return 0

  assignment_id="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az role assignment list \
    --assignee-object-id "${current_principal_id}" \
    --scope "${scope}" \
    --include-inherited false \
    --query "[?roleDefinitionName=='Anyscale Platform Administrator Role' || roleDefinitionName=='Anyscale Platform Administrator'].id | [0]" \
    -o tsv 2>/dev/null || true)"

  if [[ -n "${assignment_id}" ]]; then
    log "Importing existing Anyscale platform role assignment into Terraform state"
    terraform import "${resource_address}" "${assignment_id}" >/dev/null
  fi
}

ensure_anyscale_platform_deployment_state() {
  local resource_address="azapi_resource.anyscale_platform[0]"
  local extension_resource_address="azurerm_kubernetes_cluster_extension.anyscale_operator[0]"
  local resource_group deployment_name deployment_id extension_resource_id extension_resource_name

  anyscale_platform_enabled || return 0

  resource_group="$(resource_group_name)"
  deployment_name="$(anyscale_platform_deployment_name)"
  deployment_id="$(anyscale_platform_deployment_resource_id)"
  extension_resource_name="$(anyscale_platform_extension_resource_name)"
  extension_resource_id="/subscriptions/${TF_VAR_azure_subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.ContainerService/managedClusters/$(target_aks_cluster_name)/providers/Microsoft.KubernetesConfiguration/extensions/${extension_resource_name}"

  if terraform state show "${resource_address}" >/dev/null 2>&1; then
    :
  elif run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az deployment group show \
    --resource-group "${resource_group}" \
    --name "${deployment_name}" \
    --only-show-errors >/dev/null 2>&1; then
    log "Importing existing Anyscale ARM deployment into Terraform state"
    terraform import "${resource_address}" "${deployment_id}" >/dev/null
  fi

  ensure_anyscale_platform_role_assignment_state

  if terraform state show "${extension_resource_address}" >/dev/null 2>&1; then
    return 0
  fi

  if run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az resource show \
    --ids "${extension_resource_id}" \
    --api-version 2024-11-01 \
    --only-show-errors >/dev/null 2>&1; then
    log "Importing existing Anyscale AKS extension into Terraform state"
    terraform import "${extension_resource_address}" "${extension_resource_id}" >/dev/null
  fi
}

ensure_harness_dir() {
  mkdir -p "${HARNESS_DIR}"
}

harness_state_file() {
  ensure_harness_dir
  printf '%s/%s\n' "${HARNESS_DIR}" "$1"
}

bastion_tunnel_pidfile() {
  harness_state_file "bastion-tunnel.pid"
}

bastion_tunnel_portfile() {
  harness_state_file "bastion-tunnel.port"
}

bastion_tunnel_logfile() {
  harness_state_file "bastion-tunnel.log"
}

workspace_browser_tunnel_pidfile() {
  harness_state_file "workspace-browser-tunnel.pid"
}

workspace_browser_tunnel_http_portfile() {
  harness_state_file "workspace-browser-tunnel.http-port"
}

workspace_browser_tunnel_https_portfile() {
  harness_state_file "workspace-browser-tunnel.https-port"
}

workspace_browser_tunnel_hostfile() {
  harness_state_file "workspace-browser-tunnel.host"
}

workspace_browser_tunnel_logfile() {
  harness_state_file "workspace-browser-tunnel.log"
}

workspace_head_forward_pidfile() {
  harness_state_file "workspace-head-forward.pid"
}

workspace_head_forward_dashboard_portfile() {
  harness_state_file "workspace-head-forward.dashboard-port"
}

workspace_head_forward_http_portfile() {
  harness_state_file "workspace-head-forward.http-port"
}

workspace_head_forward_sessionfile() {
  harness_state_file "workspace-head-forward.session"
}

workspace_head_forward_logfile() {
  harness_state_file "workspace-head-forward.log"
}

workspace_browser_app_pidfile() {
  harness_state_file "workspace-browser-app.pid"
}

workspace_browser_app_browserfile() {
  harness_state_file "workspace-browser-app.browser"
}

workspace_browser_app_urlfile() {
  harness_state_file "workspace-browser-app.url"
}

workspace_browser_app_hostfile() {
  harness_state_file "workspace-browser-app.host"
}

workspace_browser_app_logfile() {
  harness_state_file "workspace-browser-app.log"
}

workspace_browser_proxy_pidfile() {
  harness_state_file "workspace-browser-proxy.pid"
}

workspace_browser_proxy_portfile() {
  harness_state_file "workspace-browser-proxy.port"
}

workspace_browser_proxy_logfile() {
  harness_state_file "workspace-browser-proxy.log"
}

workspace_browser_proxy_pacfile() {
  harness_state_file "workspace-browser-proxy.pac"
}

workspace_browser_proxy_script_path() {
  harness_state_file "workspace-browser-proxy.py"
}

workspace_browser_profile_dir() {
  ensure_harness_dir
  printf '%s/workspace-browser-profile\n' "${HARNESS_DIR}"
}

bastion_kubeconfig_path() {
  harness_state_file "kubeconfig.bastion"
}

bastion_admin_kubeconfig_path() {
  harness_state_file "kubeconfig.bastion.admin"
}

terraform_state_backup_path() {
  local label="$1"
  local timestamp

  timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
  harness_state_file "terraform.tfstate.${label}.${timestamp}.backup"
}

pid_from_file() {
  local pid_file="$1"
  [[ -f "${pid_file}" ]] || return 0
  tr -d '[:space:]' < "${pid_file}"
}

pid_is_running() {
  local pid="${1:-}"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

listener_is_ready() {
  local port="$1"
  lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
}

wait_for_local_listener() {
  local port="$1"
  local attempts="${2:-30}"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if listener_is_ready "${port}"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

listener_pids() {
  local port="$1"
  lsof -t -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
}

first_listener_pid() {
  local port="$1"
  local listener_pid

  for listener_pid in $(listener_pids "${port}"); do
    [[ -n "${listener_pid}" ]] || continue
    printf '%s\n' "${listener_pid}"
    return 0
  done

  return 1
}

pid_command_line() {
  local pid="$1"
  ps -p "${pid}" -o command= 2>/dev/null || true
}

pid_is_bastion_tunnel() {
  local pid="$1"
  local command_line

  command_line="$(pid_command_line "${pid}")"
  [[ "${command_line}" == *"azure.cli network bastion tunnel"* ]]
}

port_listeners_are_bastion_tunnels() {
  local port="$1"
  local listener_pid found=false

  for listener_pid in $(listener_pids "${port}"); do
    [[ -n "${listener_pid}" ]] || continue
    found=true
    if ! pid_is_bastion_tunnel "${listener_pid}"; then
      return 1
    fi
  done

  [[ "${found}" == true ]]
}

pid_is_workspace_browser_tunnel() {
  local pid="$1"
  local command_line

  command_line="$(pid_command_line "${pid}")"
  [[ "${command_line}" == *"kubectl"* ]] \
    && [[ "${command_line}" == *"port-forward"* ]] \
    && [[ "${command_line}" == *"anyscale-gateway"* ]]
}

port_listeners_are_workspace_browser_tunnels() {
  local port="$1"
  local listener_pid found=false

  for listener_pid in $(listener_pids "${port}"); do
    [[ -n "${listener_pid}" ]] || continue
    found=true
    if ! pid_is_workspace_browser_tunnel "${listener_pid}"; then
      return 1
    fi
  done

  [[ "${found}" == true ]]
}

wait_for_listener_shutdown() {
  local port="$1"
  local attempts="${2:-10}"
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if ! listener_is_ready "${port}"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

stop_bastion_listeners_on_port() {
  local port="$1"
  local listener_pid stopped=false

  for listener_pid in $(listener_pids "${port}"); do
    [[ -n "${listener_pid}" ]] || continue
    if ! pid_is_bastion_tunnel "${listener_pid}"; then
      continue
    fi
    kill "${listener_pid}" 2>/dev/null || true
    stopped=true
  done

  if [[ "${stopped}" == true ]]; then
    wait_for_listener_shutdown "${port}" 10 || true
    return 0
  fi

  return 1
}

stop_workspace_browser_tunnel_listeners_on_port() {
  local port="$1"
  local listener_pid stopped=false

  for listener_pid in $(listener_pids "${port}"); do
    [[ -n "${listener_pid}" ]] || continue
    if ! pid_is_workspace_browser_tunnel "${listener_pid}"; then
      continue
    fi
    kill "${listener_pid}" 2>/dev/null || true
    stopped=true
  done

  if [[ "${stopped}" == true ]]; then
    wait_for_listener_shutdown "${port}" 10 || true
    return 0
  fi

  return 1
}

workspace_browser_app_pids() {
  local profile_dir browser_pid command_line

  profile_dir="$(workspace_browser_profile_dir)"
  for browser_pid in $(pgrep -f firefox 2>/dev/null || true); do
    [[ -n "${browser_pid}" ]] || continue
    command_line="$(pid_command_line "${browser_pid}")"
    [[ "${command_line}" == *"${profile_dir}"* ]] || continue
    printf '%s\n' "${browser_pid}"
  done
}

workspace_browser_app_is_running() {
  local browser_pid

  for browser_pid in $(workspace_browser_app_pids); do
    [[ -n "${browser_pid}" ]] || continue
    return 0
  done

  return 1
}

stop_workspace_browser_app_processes() {
  local browser_pid stopped=false

  for browser_pid in $(workspace_browser_app_pids); do
    [[ -n "${browser_pid}" ]] || continue
    kill "${browser_pid}" 2>/dev/null || true
    stopped=true
  done

  if [[ "${stopped}" == true ]]; then
    sleep 1
    for browser_pid in $(workspace_browser_app_pids); do
      [[ -n "${browser_pid}" ]] || continue
      kill -9 "${browser_pid}" 2>/dev/null || true
    done
    return 0
  fi

  return 1
}

workspace_browser_proxy_pids() {
  local proxy_pid script_path command_line

  script_path="$(workspace_browser_proxy_script_path)"
  for proxy_pid in $(pgrep -f -- "${script_path}" 2>/dev/null || true); do
    [[ -n "${proxy_pid}" ]] || continue
    command_line="$(pid_command_line "${proxy_pid}")"
    [[ "${command_line}" == *"${script_path}"* ]] || continue
    printf '%s\n' "${proxy_pid}"
  done
}

workspace_browser_proxy_is_running() {
  local proxy_pid

  for proxy_pid in $(workspace_browser_proxy_pids); do
    [[ -n "${proxy_pid}" ]] || continue
    return 0
  done

  return 1
}

stop_workspace_browser_proxy_processes() {
  local proxy_pid stopped=false

  for proxy_pid in $(workspace_browser_proxy_pids); do
    [[ -n "${proxy_pid}" ]] || continue
    kill "${proxy_pid}" 2>/dev/null || true
    stopped=true
  done

  if [[ "${stopped}" == true ]]; then
    sleep 1
    for proxy_pid in $(workspace_browser_proxy_pids); do
      [[ -n "${proxy_pid}" ]] || continue
      kill -9 "${proxy_pid}" 2>/dev/null || true
    done
    return 0
  fi

  return 1
}

kubectl_readyz() {
  local kubeconfig_file="${1:-}"

  if [[ -n "${kubeconfig_file}" ]]; then
    KUBECONFIG="${kubeconfig_file}" kubectl --request-timeout="${SETUP_TIMEOUT_KUBECTL_READY_SECONDS}s" get --raw=/readyz >/dev/null
    return $?
  fi

  kubectl --request-timeout="${SETUP_TIMEOUT_KUBECTL_READY_SECONDS}s" get --raw=/readyz >/dev/null
}

clear_runtime_files() {
  rm -f "$@"
}

focused_validation_report_dir() {
  printf '%s/%s\n' "${VALIDATION_REPORT_ROOT}" "${FOCUSED_VALIDATION_RUN_ID}"
}

focused_validation_display_path() {
  local path="$1"
  if [[ "${path}" == "${ROOT_DIR}"/* ]]; then
    printf '%s\n' "${path#${ROOT_DIR}/}"
    return 0
  fi
  printf '%s\n' "${path}"
}

reset_focused_validation_run() {
  FOCUSED_VALIDATION_RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
  FOCUSED_VALIDATION_RESULTS=()
  FOCUSED_VALIDATION_PASS_COUNT=0
  FOCUSED_VALIDATION_FAIL_COUNT=0
  FOCUSED_VALIDATION_SKIP_COUNT=0
  mkdir -p "$(focused_validation_report_dir)"
}

record_focused_validation_result() {
  local status="$1"
  local check_id="$2"
  local label="$3"
  local logfile="$4"

  FOCUSED_VALIDATION_RESULTS+=("${status}|${check_id}|${label}|${logfile}")
  case "${status}" in
    PASS) ((FOCUSED_VALIDATION_PASS_COUNT+=1)) ;;
    FAIL) ((FOCUSED_VALIDATION_FAIL_COUNT+=1)) ;;
    SKIP) ((FOCUSED_VALIDATION_SKIP_COUNT+=1)) ;;
  esac
}

run_focused_validation_check() {
  local check_id="$1"
  local label="$2"
  shift 2

  local logfile display_logfile
  logfile="$(focused_validation_report_dir)/${check_id}.log"
  display_logfile="$(focused_validation_display_path "${logfile}")"

  printf '\n==> %s\n' "${label}"
  local exit_code
  set +e
  ( set -e; "$@" ) 2>&1 | tee "${logfile}"
  exit_code=${PIPESTATUS[0]}
  set -e

  if [[ "${exit_code}" -eq 0 ]]; then
    record_focused_validation_result "PASS" "${check_id}" "${label}" "${display_logfile}"
    printf '[PASS] %s\n' "${label}"
    return 0
  fi

  record_focused_validation_result "FAIL" "${check_id}" "${label}" "${display_logfile}"
  printf '[FAIL] %s\n' "${label}"
  printf '       log: %s\n' "${display_logfile}"
  return 1
}

skip_focused_validation_check() {
  local check_id="$1"
  local label="$2"
  local reason="$3"
  local logfile display_logfile

  logfile="$(focused_validation_report_dir)/${check_id}.log"
  display_logfile="$(focused_validation_display_path "${logfile}")"
  printf '%s\n' "${reason}" > "${logfile}"
  record_focused_validation_result "SKIP" "${check_id}" "${label}" "${display_logfile}"
  printf '[SKIP] %s\n' "${label}"
  printf '       reason: %s\n' "${reason}"
}

write_focused_validation_summary() {
  local summary_file display_summary_file result status check_id label logfile
  summary_file="$(focused_validation_report_dir)/summary.txt"
  display_summary_file="$(focused_validation_display_path "${summary_file}")"

  {
    printf 'Focused validation run: %s\n' "${FOCUSED_VALIDATION_RUN_ID}"
    printf '%-6s %-36s %s\n' "STATUS" "CHECK" "LOG"
    printf '%-6s %-36s %s\n' "------" "------------------------------------" "---"
    for result in "${FOCUSED_VALIDATION_RESULTS[@]}"; do
      IFS='|' read -r status check_id label logfile <<<"${result}"
      printf '%-6s %-36s %s\n' "${status}" "${label}" "${logfile}"
    done
    printf '\npass=%s fail=%s skip=%s\n' \
      "${FOCUSED_VALIDATION_PASS_COUNT}" \
      "${FOCUSED_VALIDATION_FAIL_COUNT}" \
      "${FOCUSED_VALIDATION_SKIP_COUNT}"
  } | tee "${summary_file}"

  log "Focused validation summary written to ${display_summary_file}"
}

ensure_bastion_extensions() {
  log "Ensuring az aks-preview + bastion extensions"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_EXTENSION_SECONDS}" az extension add --name aks-preview --upgrade --yes --only-show-errors >/dev/null 2>&1 || true
  run_with_timeout "${SETUP_TIMEOUT_AZURE_EXTENSION_SECONDS}" az extension add --name bastion --upgrade --yes --only-show-errors >/dev/null 2>&1 || true
}

ensure_helm_test_repositories() {
  command -v helm >/dev/null 2>&1 || return 0

  log "Ensuring Helm repositories required by Terraform tests"
  helm repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null 2>&1 || true
  run_with_timeout "${SETUP_TIMEOUT_HELM_SECONDS}" helm repo update nvdp >/dev/null
}

ensure_aks_app_routing_gateway_api() {
  require_cmd az
  require_cmd python3

  local az_version
  az_version="$(az version --query '"azure-cli"' -o tsv --only-show-errors)"
  python3 - "${az_version}" <<'PY' || die "Azure CLI ${az_version} is too old for AKS application routing Gateway API. Install Azure CLI 2.86.0 or newer."
import re
import sys

def parts(value):
    match = re.match(r"^(\d+)\.(\d+)\.(\d+)", value)
    if not match:
        raise SystemExit(1)
    return tuple(int(part) for part in match.groups())

raise SystemExit(0 if parts(sys.argv[1]) >= (2, 86, 0) else 1)
PY

  log "AKS application routing Gateway API prerequisites satisfied with Azure CLI ${az_version}; using managed Gateway API CRDs and gatewayClassName approuting-istio"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az provider register \
    --namespace Microsoft.ContainerService \
    --only-show-errors >/dev/null
}

bootstrap_contract_json() {
  terraform_output_json bootstrap_script_contract 2>/dev/null || printf '{}'
}

bootstrap_gateway_field() {
  local field="$1"
  local fallback="$2"

  bootstrap_contract_json | jq -r --arg field "${field}" --arg fallback "${fallback}" '.helm_releases.anyscale_gateway[$field] // $fallback'
}

anyscale_gateway_namespace() {
  bootstrap_gateway_field namespace "${TF_VAR_anyscale_operator_namespace:-anyscale-operator}"
}

anyscale_gateway_name() {
  bootstrap_gateway_field gateway_name "anyscale-gateway"
}

anyscale_gateway_class_name() {
  bootstrap_gateway_field gateway_class_name "approuting-istio"
}

anyscale_gateway_service_name() {
  bootstrap_gateway_field service_name "anyscale-gateway"
}

resolve_anyscale_gateway_service_name() {
  local namespace gateway_name gateway_class service_name candidate label_service
  namespace="$(anyscale_gateway_namespace)"
  gateway_name="$(anyscale_gateway_name)"
  gateway_class="$(anyscale_gateway_class_name)"
  service_name="$(anyscale_gateway_service_name)"

  for candidate in "${service_name}" "${gateway_name}-${gateway_class}"; do
    if [[ -n "${candidate}" ]] && kubectl -n "${namespace}" get service "${candidate}" >/dev/null 2>&1; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  label_service="$(kubectl -n "${namespace}" get service \
    -l "gateway.networking.k8s.io/gateway-name=${gateway_name}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${label_service}" ]]; then
    printf '%s\n' "${label_service}"
    return 0
  fi

  die "No app-routing Istio service was found for Gateway ${namespace}/${gateway_name}. Check Gateway status and app-routing Istio pods in aks-istio-system."
}

is_private_ip() {
  require_cmd python3

  python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit(1)

sys.exit(0 if ip.is_private else 1)
PY
}

# Capability probe: does this machine resolve ${host} to a private address?
#
# This is the harness's single test for "am I inside the VNet for this endpoint".
# Position is probed, never declared: network position is what
# actually determines whether a private endpoint is reachable, and a workstation
# on a VPN or a CI runner peered into the VNet is just as adjacent as the jump
# host. Returns non-zero on resolution failure or a public answer.
host_resolves_privately() {
  local host="$1" resolved_ip
  require_cmd python3

  [[ -n "${host}" ]] || return 1

  resolved_ip="$(python3 - "${host}" <<'PY'
import socket
import sys

try:
    infos = socket.getaddrinfo(sys.argv[1], 443, type=socket.SOCK_STREAM)
except OSError:
    raise SystemExit(1)
print(infos[0][4][0])
PY
)"
  [[ -n "${resolved_ip}" ]] || return 1
  is_private_ip "${resolved_ip}"
}

resolve_aks_context() {
  local field="$1"
  terraform_output_raw "${field}"
}

resolve_aks_cluster_id() {
  local rg cluster
  rg="$(resolve_aks_context resource_group_name)"
  cluster="$(resolve_aks_context aks_cluster_name)"
  [[ -n "${rg}" && -n "${cluster}" ]] || die "Terraform outputs are missing. Run ./scripts/setup.sh deploy first."
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az aks show --resource-group "${rg}" --name "${cluster}" --query id -o tsv --only-show-errors
}

use_bastion_kubeconfig_if_present() {
  local kubeconfig_file pidfile portfile pid port current_server
  kubeconfig_file="$(bastion_kubeconfig_path)"

  pidfile="$(bastion_tunnel_pidfile)"
  portfile="$(bastion_tunnel_portfile)"
  pid="$(pid_from_file "${pidfile}")"
  port="$(cat "${portfile}" 2>/dev/null || true)"

  if [[ -f "${kubeconfig_file}" && -n "${port}" ]] \
    && pid_is_running "${pid}" \
    && listener_is_ready "${port}"; then
    current_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
    if [[ ! "${current_server}" =~ ^https://(127\.0\.0\.1|localhost):[0-9]+/?$ ]]; then
      export_kubeconfig_env "${kubeconfig_file}"
    fi
  elif [[ -z "${KUBECONFIG:-}" && -f "${kubeconfig_file}" ]]; then
    export_kubeconfig_env "${kubeconfig_file}"
  fi
}

require_cluster_kubectl_access() {
  require_cmd kubectl
  if [[ "${ANYSCALE_FORCE_BASTION:-false}" != "true" ]] && private_aks_api_dns_ready; then
    ensure_direct_private_cluster_access
    return 0
  fi
  use_bastion_kubeconfig_if_present
  ensure_kubelogin_kubeconfig
  kubectl_readyz >/dev/null 2>&1 || die "kubectl cannot reach the cluster. Re-run ./scripts/setup.sh deploy or ./scripts/setup.sh verify --live so the orchestrator can refresh Bastion access."
}

workspace_browser_session_suffix() {
  local value="${1:-}"

  [[ -n "${value}" ]] || die "A session id or session host is required."

  value="${value#https://}"
  value="${value#http://}"
  value="${value%%/*}"

  case "${value}" in
    session-*.i.azure.anyscaleuserdata.com)
      value="${value#session-}"
      value="${value%%.i.azure.anyscaleuserdata.com}"
      ;;
    vscode-session-*.i.azure.anyscaleuserdata.com)
      value="${value#vscode-session-}"
      value="${value%%.i.azure.anyscaleuserdata.com}"
      ;;
    serve-session-*.i.azure.anyscaleuserdata.com)
      value="${value#serve-session-}"
      value="${value%%.i.azure.anyscaleuserdata.com}"
      ;;
  esac

  case "${value}" in
    ses_*) value="${value#ses_}" ;;
    ses-*) value="${value#ses-}" ;;
  esac

  value="${value//_/-}"
  [[ -n "${value}" ]] || die "Could not derive a session suffix from '${1}'."
  printf '%s\n' "${value}"
}

workspace_browser_primary_host() {
  local session_suffix="$1"
  printf 'session-%s.i.azure.anyscaleuserdata.com\n' "${session_suffix}"
}

workspace_browser_session_id() {
  local value="${1:-}"
  local session_suffix

  [[ -n "${value}" ]] || die "A session id or session host is required."

  case "${value}" in
    ses_*)
      printf '%s\n' "${value}"
      return 0
      ;;
    ses-*)
      printf 'ses_%s\n' "${value#ses-}"
      return 0
      ;;
  esac

  session_suffix="$(workspace_browser_session_suffix "${value}")"
  printf 'ses_%s\n' "${session_suffix//-/_}"
}

workspace_browser_hosts_entry() {
  local session_suffix="$1"
  printf '127.0.0.1 session-%s.i.azure.anyscaleuserdata.com vscode-session-%s.i.azure.anyscaleuserdata.com serve-session-%s.i.azure.anyscaleuserdata.com\n' \
    "${session_suffix}" \
    "${session_suffix}" \
    "${session_suffix}"
}

print_workspace_browser_tunnel_details() {
  local host="$1"
  local http_port="$2"
  local https_port="$3"
  local session_suffix

  session_suffix="$(workspace_browser_session_suffix "${host}")"

  printf 'session_host=%s\n' "${host}"
  printf 'http_port=%s\n' "${http_port}"
  printf 'https_port=%s\n' "${https_port}"
  printf 'hosts_entry=%s\n' "$(workspace_browser_hosts_entry "${session_suffix}")"
  printf 'browser_url=https://%s:%s/\n' "${host}" "${https_port}"
  printf 'http_probe=curl -I -H "Host: %s" http://127.0.0.1:%s/\n' "${host}" "${http_port}"
  printf 'https_probe=curl -k -I --resolve "%s:%s:127.0.0.1" "https://%s:%s/"\n' "${host}" "${https_port}" "${host}" "${https_port}"
}

print_workspace_head_forward_details() {
  local session_id="$1"
  local dashboard_port="$2"
  local http_port="$3"

  printf 'session_id=%s\n' "${session_id}"
  printf 'dashboard_port=%s\n' "${dashboard_port}"
  printf 'session_http_port=%s\n' "${http_port}"
  printf 'dashboard_url=http://127.0.0.1:%s/\n' "${dashboard_port}"
  printf 'session_http_url=http://127.0.0.1:%s/\n' "${http_port}"
  printf 'dashboard_probe=curl -I http://127.0.0.1:%s/\n' "${dashboard_port}"
  printf 'session_http_probe=curl -I http://127.0.0.1:%s/\n' "${http_port}"
}

path_as_file_uri() {
  local target_path="$1"

  python3 - "$target_path" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).resolve().as_uri())
PY
}

workspace_browser_auth_url() {
  require_cmd python3

  local session_id="$1"
  local host="$2"
  local console_origin

  console_origin="${ANYSCALE_BROWSER_AUTH_HOST:-$(default_anyscale_browser_auth_host)}"

  python3 - "$session_id" "$host" "$console_origin" <<'PY'
import base64
import json
import secrets
import sys

session_id = sys.argv[1]
host = sys.argv[2]
console_origin = sys.argv[3].rstrip("/")
relay_state = base64.b64encode(
  json.dumps(
    {
      "original_href": f"https://{host}/",
      "nonce": secrets.token_hex(32),
      "via_edge": "",
    },
    separators=(",", ":"),
  ).encode()
).decode().rstrip("=")

print(
  f"{console_origin}/cluster_auth/{session_id}?relay_state={relay_state}&theme=light"
)
PY
}

write_workspace_browser_proxy_script() {
  local script_path

  script_path="$(workspace_browser_proxy_script_path)"
  cat > "${script_path}" <<'PY'
#!/usr/bin/env python3
import argparse
import selectors
import socket
import socketserver
import sys
import urllib.parse


def build_allowed_hosts(session_suffix):
    return {
        f"session-{session_suffix}.i.azure.anyscaleuserdata.com",
        f"vscode-session-{session_suffix}.i.azure.anyscaleuserdata.com",
        f"serve-session-{session_suffix}.i.azure.anyscaleuserdata.com",
    }


class ProxyHandler(socketserver.StreamRequestHandler):
    allowed_hosts = set()
    local_http_port = 18081
    local_https_port = 18443

    def handle(self):
        request_line = self.rfile.readline().decode("iso-8859-1").strip()
        if not request_line:
            return

        parts = request_line.split()
        if len(parts) != 3:
            self.send_error(400, b"Bad Request")
            return

        method, target, version = parts
        headers = self.read_headers()

        try:
            if method.upper() == "CONNECT":
                self.handle_connect(target)
            else:
                self.handle_http(method, target, version, headers)
        except Exception:
            self.send_error(502, b"Bad Gateway")

    def read_headers(self):
        headers = []
        while True:
            line = self.rfile.readline()
            if line in (b"\r\n", b"\n", b""):
                break
            headers.append(line)
        return headers

    def resolve_target(self, host, port):
        if host not in self.allowed_hosts:
            return None
        if port in (80, self.local_http_port):
            return ("127.0.0.1", self.local_http_port)
        if port in (443, self.local_https_port):
            return ("127.0.0.1", self.local_https_port)
        return None

    def handle_connect(self, target):
        if ":" not in target:
            self.send_error(400, b"CONNECT target missing port")
            return

        host, port_str = target.rsplit(":", 1)
        upstream_target = self.resolve_target(host, int(port_str))
        if upstream_target is None:
            self.send_error(403, b"Forbidden")
            return

        upstream = socket.create_connection(upstream_target, timeout=10)
        self.connection.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        self.tunnel(self.connection, upstream)

    def handle_http(self, method, target, version, headers):
        parsed = urllib.parse.urlsplit(target)
        host = parsed.hostname
        port = parsed.port or 80
        upstream_target = self.resolve_target(host, port)
        if upstream_target is None:
            self.send_error(403, b"Forbidden")
            return

        path = urllib.parse.urlunsplit(("", "", parsed.path or "/", parsed.query, parsed.fragment))
        request_head = f"{method} {path} {version}\r\n".encode("iso-8859-1")
        upstream = socket.create_connection(upstream_target, timeout=10)
        upstream.sendall(request_head)
        for header in headers:
            upstream.sendall(header)
        upstream.sendall(b"\r\n")
        self.tunnel(self.connection, upstream)

    def tunnel(self, client, upstream):
        selector = selectors.DefaultSelector()
        selector.register(client, selectors.EVENT_READ, upstream)
        selector.register(upstream, selectors.EVENT_READ, client)
        sockets = [client, upstream]
        try:
            while True:
                events = selector.select(timeout=30)
                if not events:
                    break
                for key, _ in events:
                    source = key.fileobj
                    dest = key.data
                    data = source.recv(65536)
                    if not data:
                        return
                    dest.sendall(data)
        finally:
            for sock in sockets:
                try:
                    sock.close()
                except OSError:
                    pass

    def send_error(self, code, message):
        response = (
            f"HTTP/1.1 {code} Error\r\n"
            f"Content-Length: {len(message)}\r\n"
            "Connection: close\r\n\r\n"
        ).encode("iso-8859-1") + message
        self.connection.sendall(response)


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--session-suffix", required=True)
    parser.add_argument("--local-http-port", type=int, required=True)
    parser.add_argument("--local-https-port", type=int, required=True)
    args = parser.parse_args()

    ProxyHandler.allowed_hosts = build_allowed_hosts(args.session_suffix)
    ProxyHandler.local_http_port = args.local_http_port
    ProxyHandler.local_https_port = args.local_https_port

    with ThreadingTCPServer(("127.0.0.1", args.listen_port), ProxyHandler) as server:
        server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
PY
  chmod +x "${script_path}"
}

write_workspace_browser_proxy_pac() {
  local session_suffix="$1"
  local proxy_port="$2"
  local pac_path

  pac_path="$(workspace_browser_proxy_pacfile)"
  cat > "${pac_path}" <<EOF
function FindProxyForURL(url, host) {
  if (host == "session-${session_suffix}.i.azure.anyscaleuserdata.com" ||
      host == "vscode-session-${session_suffix}.i.azure.anyscaleuserdata.com" ||
      host == "serve-session-${session_suffix}.i.azure.anyscaleuserdata.com") {
    return "PROXY 127.0.0.1:${proxy_port}";
  }
  return "DIRECT";
}
EOF
}

start_workspace_browser_proxy() {
  require_cmd python3

  local session_suffix="$1"
  local http_port="$2"
  local https_port="$3"
  local proxy_port="18777"
  local requested_proxy_port candidate_proxy_port proxy_pid logfile script_path

  requested_proxy_port="${proxy_port}"
  if listener_is_ready "${proxy_port}"; then
    for ((candidate_proxy_port = proxy_port + 1; candidate_proxy_port <= proxy_port + 20; candidate_proxy_port++)); do
      if ! listener_is_ready "${candidate_proxy_port}"; then
        proxy_port="${candidate_proxy_port}"
        warn "Local proxy port ${requested_proxy_port} is already in use; using ${proxy_port} instead."
        break
      fi
    done
  fi

  write_workspace_browser_proxy_script
  write_workspace_browser_proxy_pac "${session_suffix}" "${proxy_port}"

  logfile="$(workspace_browser_proxy_logfile)"
  script_path="$(workspace_browser_proxy_script_path)"
  : > "${logfile}"

  nohup python3 "${script_path}" \
    --listen-port "${proxy_port}" \
    --session-suffix "${session_suffix}" \
    --local-http-port "${http_port}" \
    --local-https-port "${https_port}" > "${logfile}" 2>&1 &
  proxy_pid="$!"

  if ! wait_for_local_listener "${proxy_port}" 30; then
    kill "${proxy_pid}" 2>/dev/null || true
    tail -20 "${logfile}" >&2 || true
    die "Workspace browser proxy did not open on port ${proxy_port}."
  fi

  printf '%s\n' "${proxy_pid}" > "$(workspace_browser_proxy_pidfile)"
  printf '%s\n' "${proxy_port}" > "$(workspace_browser_proxy_portfile)"
  printf 'proxy_port=%s\n' "${proxy_port}"
  printf 'proxy_pac=%s\n' "$(workspace_browser_proxy_pacfile)"
}

detect_workspace_browser_binary() {
  local requested_browser="${1:-firefox}"
  local app_path binary_path

  case "${requested_browser}" in
    firefox)
      for app_path in \
        "${HOME}/Applications/Firefox.app" \
        "/Applications/Firefox.app" \
        "/Applications/Firefox Developer Edition.app" \
        "/Applications/Firefox Nightly.app" \
        "/Applications/LibreWolf.app"; do
        [[ -d "${app_path}" ]] || continue
        if [[ "${app_path}" == *"LibreWolf.app" ]]; then
          binary_path="${app_path}/Contents/MacOS/librewolf"
        else
          binary_path="${app_path}/Contents/MacOS/firefox"
        fi
        if [[ -x "${binary_path}" ]]; then
          printf '%s\n' "${binary_path}"
          return 0
        fi
      done
      ;;
    *)
      die "Unknown browser '${requested_browser}'. Use firefox."
      ;;
  esac

  die "Firefox was not found. Expected it under ~/Applications or a standard /Applications Firefox install."
}

write_workspace_browser_user_prefs() {
  local pac_uri="$1"
  local profile_dir

  profile_dir="$(workspace_browser_profile_dir)"
  cat > "${profile_dir}/user.js" <<EOF
user_pref("app.normandy.first_run", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.tabs.warnOnClose", false);
user_pref("browser.aboutConfig.showWarning", false);
user_pref("browser.startup.homepage", "about:blank");
user_pref("browser.startup.page", 0);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("network.captive-portal-service.enabled", false);
user_pref("network.proxy.type", 2);
user_pref("network.proxy.autoconfig_url", "${pac_uri}");
user_pref("network.proxy.autoconfig_retry_interval_min", 1);
user_pref("network.proxy.no_proxies_on", "");
EOF
}

print_workspace_browser_app_details() {
  local browser_binary="$1"
  local browser_url="$2"
  local host="$3"
  local proxy_port="${4:-}"
  local pac_file="${5:-}"

  printf 'browser_binary=%s\n' "${browser_binary}"
  printf 'browser_profile=%s\n' "$(workspace_browser_profile_dir)"
  printf 'browser_url=%s\n' "${browser_url}"
  printf 'session_host=%s\n' "${host}"
  [[ -n "${proxy_port}" ]] && printf 'browser_proxy_port=%s\n' "${proxy_port}"
  [[ -n "${pac_file}" ]] && printf 'browser_proxy_pac=%s\n' "${pac_file}"
}

workspace_browser_tunnel() {
  require_cmd curl
  require_cmd kubectl
  require_cmd lsof

  local action="start"
  shift || true

  local pidfile http_portfile https_portfile hostfile logfile pid http_port https_port host session_value
  local ingress_name gateway_namespace gateway_service listener_pid launcher_pid http_status https_status tracked_http_port tracked_https_port tracked_host
  pidfile="$(workspace_browser_tunnel_pidfile)"
  http_portfile="$(workspace_browser_tunnel_http_portfile)"
  https_portfile="$(workspace_browser_tunnel_https_portfile)"
  hostfile="$(workspace_browser_tunnel_hostfile)"
  logfile="$(workspace_browser_tunnel_logfile)"
  http_port="18081"
  https_port="18443"
  host=""
  session_value=""

  case "${action}" in
    start)
      local requested_bastion_port candidate_bastion_port
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --session-id|--cluster-id|--session-host|--host)
            [[ $# -ge 2 ]] || die "$1 requires a value."
            session_value="$2"
            shift 2
            ;;
          --http-port)
            [[ $# -ge 2 ]] || die "--http-port requires a value."
            http_port="$2"
            shift 2
            ;;
          --https-port)
            [[ $# -ge 2 ]] || die "--https-port requires a value."
            https_port="$2"
            shift 2
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-browser-tunnel start --session-id ses_xxx [--http-port 18081] [--https-port 18443]
  ./scripts/setup.sh workspace-browser-tunnel status
  ./scripts/setup.sh workspace-browser-tunnel stop

Requires kubectl access to the private AKS cluster, usually via:
  ./scripts/setup.sh bastion-tunnel start
  eval "$(./scripts/setup.sh kubeconfig-bastion --export)"

Starts a local port-forward to the private AKS app-routing Gateway service so a
browser on this Mac can reach the private session hostname after adding the
printed /etc/hosts entry.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-browser-tunnel option: $1"
            ;;
        esac
      done

      [[ -n "${session_value}" ]] || die "workspace-browser-tunnel start requires --session-id or --session-host."

      require_cluster_kubectl_access

      host="$(workspace_browser_primary_host "$(workspace_browser_session_suffix "${session_value}")")"
      ingress_name="ses-$(workspace_browser_session_suffix "${session_value}")-head"

      kubectl -n anyscale-operator get ingress "${ingress_name}" >/dev/null 2>&1 \
        || kubectl -n anyscale-operator get httproute "${ingress_name}" >/dev/null 2>&1 \
        || die "Neither Ingress nor HTTPRoute ${ingress_name} was found in namespace anyscale-operator. Confirm the session is still live before tunneling it."
      gateway_namespace="$(anyscale_gateway_namespace)"
      gateway_service="$(resolve_anyscale_gateway_service_name)"

      pid="$(pid_from_file "${pidfile}")"
      tracked_http_port="$(cat "${http_portfile}" 2>/dev/null || true)"
      tracked_https_port="$(cat "${https_portfile}" 2>/dev/null || true)"
      tracked_host="$(cat "${hostfile}" 2>/dev/null || true)"

      if pid_is_running "${pid}" \
        && [[ -n "${tracked_http_port}" && -n "${tracked_https_port}" ]] \
        && listener_is_ready "${tracked_http_port}" \
        && listener_is_ready "${tracked_https_port}" \
        && port_listeners_are_workspace_browser_tunnels "${tracked_http_port}" \
        && port_listeners_are_workspace_browser_tunnels "${tracked_https_port}"; then
        if [[ "${tracked_http_port}" != "${http_port}" || "${tracked_https_port}" != "${https_port}" ]]; then
          log "Restarting existing workspace browser tunnel on ports ${tracked_http_port}/${tracked_https_port} to use ${http_port}/${https_port}"
          kill "${pid}" 2>/dev/null || true
          stop_workspace_browser_tunnel_listeners_on_port "${tracked_http_port}" || true
          if [[ "${tracked_https_port}" != "${tracked_http_port}" ]]; then
            stop_workspace_browser_tunnel_listeners_on_port "${tracked_https_port}" || true
          fi
          clear_runtime_files "${pidfile}" "${http_portfile}" "${https_portfile}" "${hostfile}"
        else
          printf '%s\n' "${host}" > "${hostfile}"
          log "Workspace browser tunnel already running on 127.0.0.1:${http_port} and 127.0.0.1:${https_port}"
          print_workspace_browser_tunnel_details "${host}" "${http_port}" "${https_port}"
          printf 'log file: %s\n' "${logfile}"
          return 0
        fi
      fi

      if listener_is_ready "${http_port}"; then
        if ! port_listeners_are_workspace_browser_tunnels "${http_port}"; then
          die "Local HTTP port ${http_port} is already in use. Pick another with --http-port."
        fi
        stop_workspace_browser_tunnel_listeners_on_port "${http_port}" || true
      fi
      if listener_is_ready "${https_port}"; then
        if ! port_listeners_are_workspace_browser_tunnels "${https_port}"; then
          die "Local HTTPS port ${https_port} is already in use. Pick another with --https-port."
        fi
        stop_workspace_browser_tunnel_listeners_on_port "${https_port}" || true
      fi
      if listener_is_ready "${http_port}" || listener_is_ready "${https_port}"; then
        die "Requested local browser-tunnel ports are still in use after cleanup. Pick different ports."
      fi

      : > "${logfile}"
      log "Starting workspace browser tunnel for ${host} through ${gateway_namespace}/${gateway_service} on 127.0.0.1:${http_port}/${https_port}"
      nohup kubectl -n "${gateway_namespace}" port-forward "service/${gateway_service}" "${http_port}:80" "${https_port}:443" > "${logfile}" 2>&1 &
      launcher_pid="$!"

      if ! wait_for_local_listener "${http_port}" 30 || ! wait_for_local_listener "${https_port}" 30; then
        kill "${launcher_pid}" 2>/dev/null || true
        stop_workspace_browser_tunnel_listeners_on_port "${http_port}" || true
        stop_workspace_browser_tunnel_listeners_on_port "${https_port}" || true
        clear_runtime_files "${pidfile}" "${http_portfile}" "${https_portfile}" "${hostfile}"
        tail -20 "${logfile}" >&2 || true
        die "Workspace browser tunnel did not open on ports ${http_port}/${https_port}."
      fi

      listener_pid="$(first_listener_pid "${http_port}" 2>/dev/null || true)"
      [[ -n "${listener_pid}" ]] || die "Workspace browser tunnel opened but no listener PID was found."

      printf '%s\n' "${listener_pid}" > "${pidfile}"
      printf '%s\n' "${http_port}" > "${http_portfile}"
      printf '%s\n' "${https_port}" > "${https_portfile}"
      printf '%s\n' "${host}" > "${hostfile}"

      http_status="$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: ${host}" "http://127.0.0.1:${http_port}/" || true)"
      https_status="$(curl -skS -o /dev/null -w '%{http_code}' --resolve "${host}:${https_port}:127.0.0.1" "https://${host}:${https_port}/" || true)"
      if [[ "${http_status}" == "000" ]]; then
        warn "HTTP probe to ${host} via 127.0.0.1:${http_port} failed. Check ${logfile}."
      else
        printf 'http_status=%s\n' "${http_status}"
      fi
      if [[ "${https_status}" == "000" ]]; then
        warn "HTTPS probe to ${host} via 127.0.0.1:${https_port} failed. Check ${logfile}."
      else
        printf 'https_status=%s\n' "${https_status}"
      fi

      log "Workspace browser tunnel ready"
      print_workspace_browser_tunnel_details "${host}" "${http_port}" "${https_port}"
      printf 'log file: %s\n' "${logfile}"
      ;;
    status)
      pid="$(pid_from_file "${pidfile}")"
      http_port="$(cat "${http_portfile}" 2>/dev/null || true)"
      https_port="$(cat "${https_portfile}" 2>/dev/null || true)"
      host="$(cat "${hostfile}" 2>/dev/null || true)"

      if [[ -n "${http_port}" && -n "${https_port}" && -n "${host}" ]] \
        && listener_is_ready "${http_port}" \
        && listener_is_ready "${https_port}" \
        && port_listeners_are_workspace_browser_tunnels "${http_port}" \
        && port_listeners_are_workspace_browser_tunnels "${https_port}"; then
        pid="$(first_listener_pid "${http_port}" 2>/dev/null || true)"
        [[ -n "${pid}" ]] && printf '%s\n' "${pid}" > "${pidfile}"
        printf 'status=running\n'
        printf 'pid=%s\n' "${pid}"
        print_workspace_browser_tunnel_details "${host}" "${http_port}" "${https_port}"
        printf 'log=%s\n' "${logfile}"
        return 0
      fi

      clear_runtime_files "${pidfile}" "${http_portfile}" "${https_portfile}" "${hostfile}"
      printf 'status=stopped\n'
      printf 'log=%s\n' "${logfile}"
      return 1
      ;;
    stop)
      local stopped=false
      pid="$(pid_from_file "${pidfile}")"
      http_port="$(cat "${http_portfile}" 2>/dev/null || true)"
      https_port="$(cat "${https_portfile}" 2>/dev/null || true)"

      if pid_is_running "${pid}"; then
        kill "${pid}" 2>/dev/null || true
        stopped=true
      fi
      if [[ -n "${http_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${http_port}"; then
        stopped=true
      fi
      if [[ -n "${https_port}" && "${https_port}" != "${http_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${https_port}"; then
        stopped=true
      fi

      if [[ "${stopped}" == true ]]; then
        log "Stopped workspace browser tunnel${http_port:+ on 127.0.0.1:${http_port}/${https_port}}"
      else
        warn "No running workspace browser tunnel found."
      fi

      clear_runtime_files "${pidfile}" "${http_portfile}" "${https_portfile}" "${hostfile}"
      ;;
    *)
      die "Usage: ./scripts/setup.sh workspace-browser-tunnel {start|status|stop}"
      ;;
  esac
}

workspace_head_forward() {
  require_cmd kubectl
  require_cmd lsof

  local action="start"
  if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
    action="$1"
    shift || true
  fi

  local pidfile dashboard_portfile http_portfile sessionfile logfile pid dashboard_port http_port session_value session_id service_name listener_pid launcher_pid tracked_dashboard_port tracked_http_port tracked_session
  pidfile="$(workspace_head_forward_pidfile)"
  dashboard_portfile="$(workspace_head_forward_dashboard_portfile)"
  http_portfile="$(workspace_head_forward_http_portfile)"
  sessionfile="$(workspace_head_forward_sessionfile)"
  logfile="$(workspace_head_forward_logfile)"
  dashboard_port="18265"
  http_port="18080"
  session_value=""

  case "${action}" in
    start)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --session-id|--cluster-id|--session-host|--host)
            [[ $# -ge 2 ]] || die "$1 requires a value."
            session_value="$2"
            shift 2
            ;;
          --dashboard-port)
            [[ $# -ge 2 ]] || die "--dashboard-port requires a value."
            dashboard_port="$2"
            shift 2
            ;;
          --http-port)
            [[ $# -ge 2 ]] || die "--http-port requires a value."
            http_port="$2"
            shift 2
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-head-forward --session-id ses_xxx [--dashboard-port 18265] [--http-port 18080]
  ./scripts/setup.sh workspace-head-forward status
  ./scripts/setup.sh workspace-head-forward stop

Starts or reuses the Bastion-backed kubeconfig path and port-forwards the live
session head service directly to localhost. This bypasses the Anyscale
cluster_auth browser flow and exposes the Ray Dashboard on 127.0.0.1.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-head-forward option: $1"
            ;;
        esac
      done

      [[ -n "${session_value}" ]] || die "workspace-head-forward start requires --session-id or --session-host."

      bastion_tunnel start --port "64435"
      export_kubeconfig_env "$(kubeconfig_bastion --print-path)"
      require_cluster_kubectl_access

      session_id="$(workspace_browser_session_id "${session_value}")"
      service_name="${session_id//_/-}-head"

      kubectl -n anyscale-operator get service "${service_name}" >/dev/null 2>&1 \
        || die "Service ${service_name} was not found in namespace anyscale-operator. Confirm the session is still live before forwarding it."

      pid="$(pid_from_file "${pidfile}")"
      tracked_dashboard_port="$(cat "${dashboard_portfile}" 2>/dev/null || true)"
      tracked_http_port="$(cat "${http_portfile}" 2>/dev/null || true)"
      tracked_session="$(cat "${sessionfile}" 2>/dev/null || true)"

      if pid_is_running "${pid}" \
        && [[ -n "${tracked_dashboard_port}" && -n "${tracked_http_port}" ]] \
        && listener_is_ready "${tracked_dashboard_port}" \
        && listener_is_ready "${tracked_http_port}"; then
        if [[ "${tracked_dashboard_port}" == "${dashboard_port}" && "${tracked_http_port}" == "${http_port}" && "${tracked_session}" == "${session_id}" ]]; then
          log "Workspace head port-forward already running on 127.0.0.1:${dashboard_port} and 127.0.0.1:${http_port}"
          print_workspace_head_forward_details "${session_id}" "${dashboard_port}" "${http_port}"
          printf 'log file: %s\n' "${logfile}"
          return 0
        fi

        kill "${pid}" 2>/dev/null || true
        [[ -n "${tracked_dashboard_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${tracked_dashboard_port}" || true
        if [[ -n "${tracked_http_port}" && "${tracked_http_port}" != "${tracked_dashboard_port}" ]]; then
          stop_workspace_browser_tunnel_listeners_on_port "${tracked_http_port}" || true
        fi
        clear_runtime_files "${pidfile}" "${dashboard_portfile}" "${http_portfile}" "${sessionfile}"
      fi

      if listener_is_ready "${dashboard_port}"; then
        die "Local dashboard port ${dashboard_port} is already in use. Pick another with --dashboard-port."
      fi
      if listener_is_ready "${http_port}"; then
        die "Local HTTP port ${http_port} is already in use. Pick another with --http-port."
      fi

      : > "${logfile}"
      log "Starting workspace head port-forward for ${service_name} on 127.0.0.1:${dashboard_port}/${http_port}"
      nohup kubectl -n anyscale-operator port-forward service/"${service_name}" "${dashboard_port}:8265" "${http_port}:80" > "${logfile}" 2>&1 &
      launcher_pid="$!"

      if ! wait_for_local_listener "${dashboard_port}" 30 || ! wait_for_local_listener "${http_port}" 30; then
        kill "${launcher_pid}" 2>/dev/null || true
        [[ -n "${dashboard_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${dashboard_port}" || true
        [[ -n "${http_port}" && "${http_port}" != "${dashboard_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${http_port}" || true
        clear_runtime_files "${pidfile}" "${dashboard_portfile}" "${http_portfile}" "${sessionfile}"
        tail -20 "${logfile}" >&2 || true
        die "Workspace head port-forward did not open on ports ${dashboard_port}/${http_port}."
      fi

      listener_pid="$(first_listener_pid "${dashboard_port}" 2>/dev/null || true)"
      [[ -n "${listener_pid}" ]] || die "Workspace head port-forward opened but no listener PID was found."

      printf '%s\n' "${listener_pid}" > "${pidfile}"
      printf '%s\n' "${dashboard_port}" > "${dashboard_portfile}"
      printf '%s\n' "${http_port}" > "${http_portfile}"
      printf '%s\n' "${session_id}" > "${sessionfile}"

      print_workspace_head_forward_details "${session_id}" "${dashboard_port}" "${http_port}"
      printf 'log file: %s\n' "${logfile}"
      ;;
    status)
      pid="$(pid_from_file "${pidfile}")"
      dashboard_port="$(cat "${dashboard_portfile}" 2>/dev/null || true)"
      http_port="$(cat "${http_portfile}" 2>/dev/null || true)"
      session_id="$(cat "${sessionfile}" 2>/dev/null || true)"

      if [[ -n "${dashboard_port}" && -n "${http_port}" && -n "${session_id}" ]] \
        && pid_is_running "${pid}" \
        && listener_is_ready "${dashboard_port}" \
        && listener_is_ready "${http_port}"; then
        printf 'status=running\n'
        printf 'pid=%s\n' "${pid}"
        print_workspace_head_forward_details "${session_id}" "${dashboard_port}" "${http_port}"
        printf 'log=%s\n' "${logfile}"
        return 0
      fi

      printf 'status=stopped\n'
      printf 'log=%s\n' "${logfile}"
      return 1
      ;;
    stop)
      local stopped=false
      pid="$(pid_from_file "${pidfile}")"
      dashboard_port="$(cat "${dashboard_portfile}" 2>/dev/null || true)"
      http_port="$(cat "${http_portfile}" 2>/dev/null || true)"

      if pid_is_running "${pid}"; then
        kill "${pid}" 2>/dev/null || true
        stopped=true
      fi
      if [[ -n "${dashboard_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${dashboard_port}"; then
        stopped=true
        log "Stopped workspace head port-forward on 127.0.0.1:${dashboard_port}/${http_port}"
      elif [[ -n "${http_port}" && "${http_port}" != "${dashboard_port}" ]] && stop_workspace_browser_tunnel_listeners_on_port "${http_port}"; then
        stopped=true
        log "Stopped workspace head port-forward on 127.0.0.1:${dashboard_port}/${http_port}"
      fi
      if [[ "${stopped}" != true ]]; then
        warn "No workspace head port-forward was running."
      fi
      if [[ -n "${http_port}" && "${http_port}" != "${dashboard_port}" ]]; then
        stop_workspace_browser_tunnel_listeners_on_port "${http_port}" || true
      fi
      clear_runtime_files "${pidfile}" "${dashboard_portfile}" "${http_portfile}" "${sessionfile}"
      ;;
    *)
      die "Usage: ./scripts/setup.sh workspace-head-forward {start|status|stop}"
      ;;
  esac
}

workspace_head_open() {
  local action="start"
  if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
    action="$1"
    shift || true
  fi

  local session_value=""
  local session_id=""
  local session_suffix=""
  local browser_name="firefox"
  local browser_binary=""
  local browser_url=""
  local logfile=""
  local launcher_pid=""
  local profile_dir=""
  local dashboard_port="18265"
  local http_port="18080"
  local ingress_http_port="18081"
  local ingress_https_port="18443"
  local pac_uri=""
  local proxy_port=""
  local proxy_pac=""
  local keep_forward=false

  case "${action}" in
    start)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --session-id|--cluster-id|--session-host|--host)
            [[ $# -ge 2 ]] || die "$1 requires a value."
            session_value="$2"
            shift 2
            ;;
          --browser)
            [[ $# -ge 2 ]] || die "--browser requires a value."
            browser_name="$2"
            shift 2
            ;;
          --dashboard-port)
            [[ $# -ge 2 ]] || die "--dashboard-port requires a value."
            dashboard_port="$2"
            shift 2
            ;;
          --http-port)
            [[ $# -ge 2 ]] || die "--http-port requires a value."
            http_port="$2"
            shift 2
            ;;
          --ingress-http-port)
            [[ $# -ge 2 ]] || die "--ingress-http-port requires a value."
            ingress_http_port="$2"
            shift 2
            ;;
          --ingress-https-port)
            [[ $# -ge 2 ]] || die "--ingress-https-port requires a value."
            ingress_https_port="$2"
            shift 2
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-head-open --session-id ses_xxx [--browser firefox] [--dashboard-port 18265] [--http-port 18080] [--ingress-http-port 18081] [--ingress-https-port 18443]
  ./scripts/setup.sh workspace-head-open status
  ./scripts/setup.sh workspace-head-open stop [--keep-forward]

Starts or reuses the direct head-service port-forward and the local ingress
tunnel, configures a Firefox-only PAC proxy so embedded dashboard tiles that
reference the private session host route through localhost, and launches a
separate temporary Firefox profile directly to the local Ray Dashboard
fallback.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-head-open option: $1"
            ;;
        esac
      done

      [[ -n "${session_value}" ]] || die "workspace-head-open start requires --session-id or --session-host."

      workspace_head_forward start --session-id "${session_value}" --dashboard-port "${dashboard_port}" --http-port "${http_port}"
      workspace_browser_ready start --session-id "${session_value}" --http-port "${ingress_http_port}" --https-port "${ingress_https_port}"

      session_id="$(workspace_browser_session_id "${session_value}")"
      session_suffix="$(workspace_browser_session_suffix "${session_value}")"
      browser_url="http://127.0.0.1:${dashboard_port}/"
      browser_binary="$(detect_workspace_browser_binary "${browser_name}")"
      logfile="$(workspace_browser_app_logfile)"
      profile_dir="$(workspace_browser_profile_dir)"

      if workspace_browser_app_is_running; then
        stop_workspace_browser_app_processes || true
      fi
      rm -rf "${profile_dir}"
      mkdir -p "${profile_dir}"
      : > "${logfile}"

      if workspace_browser_proxy_is_running; then
        stop_workspace_browser_proxy_processes || true
      fi
      start_workspace_browser_proxy "${session_suffix}" "${ingress_http_port}" "${ingress_https_port}"
      proxy_port="$(cat "$(workspace_browser_proxy_portfile)" 2>/dev/null || true)"
      proxy_pac="$(workspace_browser_proxy_pacfile)"
      pac_uri="$(path_as_file_uri "${proxy_pac}")"
      write_workspace_browser_user_prefs "${pac_uri}"

      log "Launching temporary browser profile with ${browser_binary}"
      nohup "${browser_binary}" \
        -no-remote \
        -new-instance \
        -profile "${profile_dir}" \
        "${browser_url}" > "${logfile}" 2>&1 &
      launcher_pid="$!"

      sleep 2
      workspace_browser_app_is_running || die "The temporary browser did not stay running. Check ${logfile}."

      printf '%s\n' "${launcher_pid}" > "$(workspace_browser_app_pidfile)"
      printf '%s\n' "${browser_binary}" > "$(workspace_browser_app_browserfile)"
      printf '%s\n' "${browser_url}" > "$(workspace_browser_app_urlfile)"
      printf '%s\n' "ray-dashboard-${session_id}" > "$(workspace_browser_app_hostfile)"

      print_workspace_head_forward_details "${session_id}" "${dashboard_port}" "${http_port}"
      print_workspace_browser_app_details "${browser_binary}" "${browser_url}" "ray-dashboard-${session_id}" "${proxy_port}" "${proxy_pac}"
      printf 'browser_log=%s\n' "${logfile}"
      ;;
    status)
      workspace_head_forward status || true
      if workspace_browser_app_is_running; then
        browser_binary="$(cat "$(workspace_browser_app_browserfile)" 2>/dev/null || true)"
        browser_url="$(cat "$(workspace_browser_app_urlfile)" 2>/dev/null || true)"
        session_value="$(cat "$(workspace_browser_app_hostfile)" 2>/dev/null || true)"
        printf 'browser_status=running\n'
        print_workspace_browser_app_details "${browser_binary}" "${browser_url}" "${session_value}"
        printf 'browser_log=%s\n' "$(workspace_browser_app_logfile)"
        return 0
      fi

      printf 'browser_status=stopped\n'
      printf 'browser_log=%s\n' "$(workspace_browser_app_logfile)"
      return 1
      ;;
    stop)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --keep-forward)
            keep_forward=true
            shift
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-head-open stop [--keep-forward]

Stops the temporary browser profile and, by default, also stops the backing
head-service forward. Use --keep-forward if you only want to close the browser.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-head-open stop option: $1"
            ;;
        esac
      done

      if stop_workspace_browser_app_processes; then
        log "Stopped temporary browser profile"
      else
        warn "No temporary browser profile was running."
      fi
      rm -rf "$(workspace_browser_profile_dir)"
      clear_runtime_files \
        "$(workspace_browser_app_pidfile)" \
        "$(workspace_browser_app_browserfile)" \
        "$(workspace_browser_app_urlfile)" \
        "$(workspace_browser_app_hostfile)"

      if stop_workspace_browser_proxy_processes; then
        log "Stopped Firefox workspace proxy"
      else
        warn "No Firefox workspace proxy was running."
      fi
      clear_runtime_files \
        "$(workspace_browser_proxy_pidfile)" \
        "$(workspace_browser_proxy_portfile)" \
        "$(workspace_browser_proxy_pacfile)" \
        "$(workspace_browser_proxy_script_path)"

      if [[ "${keep_forward}" != true ]]; then
        workspace_browser_ready stop --keep-bastion || true
        workspace_head_forward stop || true
      fi
      ;;
    *)
      die "Usage: ./scripts/setup.sh workspace-head-open {start|status|stop}"
      ;;
  esac
}

workspace_browser_ready() {
  local action="start"
  if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
    action="$1"
    shift || true
  fi

  local session_value=""
  local bastion_port="64435"
  local http_port="18081"
  local https_port="18443"
  local keep_bastion=false
  local kubeconfig_path=""
  local browser_status=0
  local bastion_status=0

  case "${action}" in
    start)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --session-id|--cluster-id|--session-host|--host)
            [[ $# -ge 2 ]] || die "$1 requires a value."
            session_value="$2"
            shift 2
            ;;
          --bastion-port)
            [[ $# -ge 2 ]] || die "--bastion-port requires a value."
            bastion_port="$2"
            shift 2
            ;;
          --http-port)
            [[ $# -ge 2 ]] || die "--http-port requires a value."
            http_port="$2"
            shift 2
            ;;
          --https-port)
            [[ $# -ge 2 ]] || die "--https-port requires a value."
            https_port="$2"
            shift 2
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-browser-ready --session-id ses_xxx [--bastion-port 64435] [--http-port 18081] [--https-port 18443]
  ./scripts/setup.sh workspace-browser-ready status
  ./scripts/setup.sh workspace-browser-ready stop [--keep-bastion]

Single-command equivalent of:
  ./scripts/setup.sh bastion-tunnel start --port 64435
  eval "$(./scripts/setup.sh kubeconfig-bastion --export)"
  ./scripts/setup.sh workspace-browser-tunnel start --session-id ses_xxx

The command starts or reuses the Bastion tunnel, writes a Bastion-backed
kubeconfig, exports it for the current process, and starts the local browser
tunnel to the private app-routing Gateway service.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-browser-ready option: $1"
            ;;
        esac
      done

      [[ -n "${session_value}" ]] || die "workspace-browser-ready start requires --session-id or --session-host."

      requested_bastion_port="${bastion_port}"
      if listener_is_ready "${bastion_port}" && ! port_listeners_are_bastion_tunnels "${bastion_port}"; then
        for ((candidate_bastion_port = bastion_port + 1; candidate_bastion_port <= bastion_port + 20; candidate_bastion_port++)); do
          if ! listener_is_ready "${candidate_bastion_port}"; then
            bastion_port="${candidate_bastion_port}"
            warn "Local port ${requested_bastion_port} is already in use; using Bastion port ${bastion_port} instead."
            break
          fi
        done
      fi
      [[ -n "${bastion_port}" ]] || die "Could not determine a Bastion tunnel port."

      bastion_tunnel start --port "${bastion_port}"
      kubeconfig_path="$(kubeconfig_bastion --print-path)"
      export_kubeconfig_env "${kubeconfig_path}"
      printf 'kubeconfig=%s\n' "${kubeconfig_path}"
      workspace_browser_tunnel start --session-id "${session_value}" --http-port "${http_port}" --https-port "${https_port}"
      ;;
    status)
      bastion_tunnel status || bastion_status=$?
      browser_status=0
      workspace_browser_tunnel status || browser_status=$?
      if (( bastion_status != 0 || browser_status != 0 )); then
        return 1
      fi
      ;;
    stop)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --keep-bastion)
            keep_bastion=true
            shift
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-browser-ready stop [--keep-bastion]

Stops the local browser tunnel and, by default, also stops the reusable Bastion
tunnel started for it. Use --keep-bastion if you still need kubectl access.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-browser-ready stop option: $1"
            ;;
        esac
      done

      workspace_browser_tunnel stop || true
      if [[ "${keep_bastion}" != true ]]; then
        bastion_tunnel stop || true
      fi
      ;;
    *)
      die "Usage: ./scripts/setup.sh workspace-browser-ready {start|status|stop}"
      ;;
  esac
}

workspace_browser_open() {
  local action="start"
  if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
    action="$1"
    shift || true
  fi

  local session_value=""
  local session_id=""
  local browser_name="firefox"
  local browser_binary=""
  local browser_url=""
  local host=""
  local session_suffix=""
  local profile_dir=""
  local logfile=""
  local launcher_pid=""
  local bastion_port="64435"
  local http_port="18081"
  local https_port="18443"
  local keep_network=false
  local pac_uri=""
  local proxy_port=""
  local proxy_pac=""

  case "${action}" in
    start)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --session-id|--cluster-id|--session-host|--host)
            [[ $# -ge 2 ]] || die "$1 requires a value."
            session_value="$2"
            shift 2
            ;;
          --browser)
            [[ $# -ge 2 ]] || die "--browser requires a value."
            browser_name="$2"
            shift 2
            ;;
          --bastion-port)
            [[ $# -ge 2 ]] || die "--bastion-port requires a value."
            bastion_port="$2"
            shift 2
            ;;
          --http-port)
            [[ $# -ge 2 ]] || die "--http-port requires a value."
            http_port="$2"
            shift 2
            ;;
          --https-port)
            [[ $# -ge 2 ]] || die "--https-port requires a value."
            https_port="$2"
            shift 2
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-browser-open --session-id ses_xxx [--browser firefox] [--bastion-port 64435] [--http-port 18081] [--https-port 18443]
  ./scripts/setup.sh workspace-browser-open status
  ./scripts/setup.sh workspace-browser-open stop [--keep-network]

Starts the Bastion-backed browser workflow and launches a separate temporary
Firefox profile with its own PAC-configured local proxy for the private session
hostname. This avoids permanent /etc/hosts changes on the Mac and avoids
touching other browser instances.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-browser-open option: $1"
            ;;
        esac
      done

      [[ -n "${session_value}" ]] || die "workspace-browser-open start requires --session-id or --session-host."

      workspace_browser_ready start --session-id "${session_value}" --bastion-port "${bastion_port}" --http-port "${http_port}" --https-port "${https_port}"

      session_id="$(workspace_browser_session_id "${session_value}")"
      session_suffix="$(workspace_browser_session_suffix "${session_value}")"
      host="$(workspace_browser_primary_host "${session_suffix}")"
      browser_url="$(workspace_browser_auth_url "${session_id}" "${host}")"
      browser_binary="$(detect_workspace_browser_binary "${browser_name}")"
      logfile="$(workspace_browser_app_logfile)"
      profile_dir="$(workspace_browser_profile_dir)"

      if workspace_browser_app_is_running; then
        stop_workspace_browser_app_processes || true
      fi
      rm -rf "${profile_dir}"
      mkdir -p "${profile_dir}"
      : > "${logfile}"

      if workspace_browser_proxy_is_running; then
        stop_workspace_browser_proxy_processes || true
      fi
      start_workspace_browser_proxy "${session_suffix}" "${http_port}" "${https_port}"
      proxy_port="$(cat "$(workspace_browser_proxy_portfile)" 2>/dev/null || true)"
      proxy_pac="$(workspace_browser_proxy_pacfile)"
      pac_uri="$(path_as_file_uri "${proxy_pac}")"
      write_workspace_browser_user_prefs "${pac_uri}"

      log "Launching temporary browser profile with ${browser_binary}"
      nohup "${browser_binary}" \
        -no-remote \
        -new-instance \
        -profile "${profile_dir}" \
        "${browser_url}" > "${logfile}" 2>&1 &
      launcher_pid="$!"

      sleep 2
      workspace_browser_app_is_running || die "The temporary browser did not stay running. Check ${logfile}."

      printf '%s\n' "${launcher_pid}" > "$(workspace_browser_app_pidfile)"
      printf '%s\n' "${browser_binary}" > "$(workspace_browser_app_browserfile)"
      printf '%s\n' "${browser_url}" > "$(workspace_browser_app_urlfile)"
      printf '%s\n' "${host}" > "$(workspace_browser_app_hostfile)"

      print_workspace_browser_app_details "${browser_binary}" "${browser_url}" "${host}" "${proxy_port}" "${proxy_pac}"
      printf 'browser_log=%s\n' "${logfile}"
      ;;
    status)
      workspace_browser_ready status || true
      if workspace_browser_app_is_running && workspace_browser_proxy_is_running; then
        browser_binary="$(cat "$(workspace_browser_app_browserfile)" 2>/dev/null || true)"
        browser_url="$(cat "$(workspace_browser_app_urlfile)" 2>/dev/null || true)"
        host="$(cat "$(workspace_browser_app_hostfile)" 2>/dev/null || true)"
        proxy_port="$(cat "$(workspace_browser_proxy_portfile)" 2>/dev/null || true)"
        proxy_pac="$(workspace_browser_proxy_pacfile)"
        printf 'browser_status=running\n'
        print_workspace_browser_app_details "${browser_binary}" "${browser_url}" "${host}" "${proxy_port}" "${proxy_pac}"
        printf 'browser_log=%s\n' "$(workspace_browser_app_logfile)"
        return 0
      fi

      printf 'browser_status=stopped\n'
      printf 'browser_log=%s\n' "$(workspace_browser_app_logfile)"
      return 1
      ;;
    stop)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --keep-network)
            keep_network=true
            shift
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh workspace-browser-open stop [--keep-network]

Stops the temporary browser profile and, by default, also removes the backing
local Bastion/browser tunnel workflow. Use --keep-network if you only want to
close the temporary browser and keep the tunnel running.
USAGE
            return 0
            ;;
          *)
            die "Unknown workspace-browser-open stop option: $1"
            ;;
        esac
      done

      if stop_workspace_browser_app_processes; then
        log "Stopped temporary browser profile"
      else
        warn "No temporary browser profile was running."
      fi
      rm -rf "$(workspace_browser_profile_dir)"
      clear_runtime_files \
        "$(workspace_browser_app_pidfile)" \
        "$(workspace_browser_app_browserfile)" \
        "$(workspace_browser_app_urlfile)" \
        "$(workspace_browser_app_hostfile)"

      if stop_workspace_browser_proxy_processes; then
        log "Stopped Firefox workspace proxy"
      else
        warn "No Firefox workspace proxy was running."
      fi
      clear_runtime_files \
        "$(workspace_browser_proxy_pidfile)" \
        "$(workspace_browser_proxy_portfile)" \
        "$(workspace_browser_proxy_pacfile)" \
        "$(workspace_browser_proxy_script_path)"

      if [[ "${keep_network}" != true ]]; then
        workspace_browser_ready stop || true
      fi
      ;;
    *)
      die "Usage: ./scripts/setup.sh workspace-browser-open {start|status|stop}"
      ;;
  esac
}

anyscale_cli_bin() {
  printf '%s/.venv/bin/anyscale\n' "${ROOT_DIR}"
}

require_anyscale_cli() {
  local cli_bin
  cli_bin="$(anyscale_cli_bin)"
  [[ -x "${cli_bin}" ]] || die "Anyscale CLI not found at ${cli_bin}. Install it with uv and the repo-local .venv first."
}

anyscale_cli_auth_available() {
  local cli_bin output
  [[ -n "${ANYSCALE_CLI_TOKEN:-}" ]] && return 0
  cli_bin="$(anyscale_cli_bin)"
  output="$(ANYSCALE_HOST="${ANYSCALE_HOST:-$(default_anyscale_host)}" \
    "${cli_bin}" cloud list --max-items 1 --page-size 1 --no-interactive --json >/dev/null 2>&1)" && return 0
  [[ "${output}" != *"Credentials not found"* ]] || return 1
  return 1
}

require_anyscale_cli_auth() {
  require_anyscale_cli
  if anyscale_cli_auth_available; then
    return 0
  fi

  die "Anyscale CLI credentials not found or invalid. Run: ANYSCALE_HOST=$(default_anyscale_host) ${ROOT_DIR}/.venv/bin/anyscale login"
}

azure_login_command() {
  local -a cmd=(az login)
  local command_display

  if [[ -n "${TF_VAR_azure_tenant_id:-}" ]]; then
    cmd+=(--tenant "${TF_VAR_azure_tenant_id}")
  fi

  printf -v command_display '%q ' "${cmd[@]}"
  printf '%s\n' "${command_display% }"
}

ensure_azure_cli_login() {
  local az_account_error login_command prompt_response

  if az_account_error="$(az account show --only-show-errors 2>&1 >/dev/null)"; then
    return 0
  fi

  login_command="$(azure_login_command)"

  if [[ "${az_account_error}" == *".azure/azureProfile.json"* && "${az_account_error}" == *"Operation not permitted"* ]]; then
    die "Azure CLI auth context exists, but this shell cannot read ~/.azure/azureProfile.json. Re-run from a terminal with access to your existing az session, or use an unsandboxed shell."
  fi

  if [[ -t 0 && -t 1 ]]; then
    warn "Azure CLI is not logged in for this shell."
    warn "Run ${login_command} in this terminal, then press Enter to retry."

    while true; do
      printf 'Press Enter after Azure CLI login, or type "abort" to exit: ' >&2
      IFS= read -r prompt_response || die "Azure CLI login is required. Run: ${login_command}"

      case "${prompt_response}" in
        "")
          ;;
        abort)
          die "Azure CLI login is required. Run: ${login_command}"
          ;;
        *)
          warn "Unrecognized response '${prompt_response}'. Press Enter after Azure CLI login or type 'abort'."
          continue
          ;;
      esac

      if az account show --only-show-errors >/dev/null 2>&1; then
        return 0
      fi

      warn "Azure CLI login is still unavailable in this shell."
      warn "Run ${login_command} and retry."
    done
  fi

  die "Azure CLI login is required. Run: ${login_command}"
}

###############################################################################
preflight() {
  log "Checking required CLI tools..."
  for tool_name in az terraform kubectl kubelogin helm jq; do require_cmd "${tool_name}"; done
  check_terraform_lock_state
  render_tfvars

  log "Checking az login..."
  ensure_azure_cli_login

  local sub_id
  sub_id="${TF_VAR_azure_subscription_id}"
  log "Setting active subscription to ${sub_id}"
  az account set --subscription "${sub_id}" --only-show-errors
  ensure_aks_app_routing_gateway_api
}

###############################################################################
backend_override_path() {
  printf '%s\n' "${TERRAFORM_DIR}/backend_override.tf"
}

# The lab workload uses local Terraform state on the operator workstation, so
# any stale gitignored backend_override.tf from an earlier remote-backend run is
# removed before init.
remove_backend_override() {
  rm -f "$(backend_override_path)"
}

tf_init() {
  render_tfvars
  remove_backend_override
  log "terraform init"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_INIT_SECONDS}" terraform init -input=false
}

###############################################################################
validate() {
  render_tfvars
  log "terraform fmt"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_VALIDATE_SECONDS}" terraform fmt -recursive -check
  log "terraform validate"
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_VALIDATE_SECONDS}" terraform validate
}

# The plan-time contract tests (tests/*.tftest.hcl) assert on fixture inputs
# (project=tftest, etc.) and must run in a clean environment. The harness deploy
# and verify paths render the operator's real terraform.auto.tfvars.json and
# export computed TF_VAR_* values, which terraform test resolves over the test
# fixtures and breaks the naming/contract assertions. They are therefore run as a
# standalone gate (the reviewer, the quality gate, or `terraform -chdir=infra/terraform
# test`) rather than inside a live deploy. `validate()` above checks that the
# real, rendered configuration is syntactically valid.

###############################################################################
run_terraform_command_with_retry() {
  local action="$1"
  local timeout_seconds="$2"
  local success_exit_code="$3"
  shift 3

  local attempt=1
  local max_attempts="${SETUP_TERRAFORM_RETRY_ATTEMPTS:-6}"
  local delay_seconds="${SETUP_TERRAFORM_RETRY_DELAY_SECONDS:-20}"
  local rc output_file

  output_file="${CACHE_DIR}/terraform-${action}-retry.log"

  while (( attempt <= max_attempts )); do
    : > "${output_file}"
    set +e
    run_with_timeout "${timeout_seconds}" "$@" >"${output_file}" 2>&1
    rc=$?
    set -e

    if [[ -s "${output_file}" ]]; then
      cat "${output_file}"
    fi

    if [[ "${rc}" -eq 0 || "${rc}" -eq "${success_exit_code}" ]]; then
      rm -f "${output_file}"
      return 0
    fi

    if grep -Eqi 'Error acquiring the state lock|resource temporarily unavailable|Lock Info:' "${output_file}"; then
      if (( attempt < max_attempts )); then
        warn "Terraform ${action} hit a temporary state lock (attempt ${attempt}/${max_attempts}); retrying in ${delay_seconds}s."
        sleep "${delay_seconds}"
        attempt=$((attempt + 1))
        continue
      fi
    fi

    rm -f "${output_file}"
    return "${rc}"
  done

  rm -f "${output_file}"
  return "${rc}"
}

###############################################################################
plan() {
  render_tfvars
  ensure_aks_app_routing_gateway_api
  ensure_anyscale_marketplace_agreement_accepted
  ensure_anyscale_platform_deployment_state
  rm -f tfplan
  log "terraform plan -> tfplan"
  if ! run_terraform_command_with_retry "plan" "${SETUP_TIMEOUT_TERRAFORM_PLAN_SECONDS}" 0 \
    terraform plan -input=false -out=tfplan; then
    return 1
  fi
}

###############################################################################
apply() {
  render_tfvars
  ensure_anyscale_marketplace_agreement_accepted
  ensure_anyscale_platform_deployment_state
  if [[ ! -f tfplan ]]; then plan; fi
  log "terraform apply tfplan (this will take ~20 min - Azure Firewall + AKS)"
  if ! run_terraform_command_with_retry "apply" "${SETUP_TIMEOUT_TERRAFORM_APPLY_SECONDS}" 0 \
    terraform apply -auto-approve tfplan; then
    return 1
  fi
  sync_anyscale_cli_env
  rm -f tfplan
}

add_exit_trap() {
  local new_cmd="$1"
  local existing

  existing="$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT\$/\1/")"
  if [[ -n "${existing}" ]]; then
    trap "${existing}; ${new_cmd}" EXIT
  else
    trap "${new_cmd}" EXIT
  fi
}

run_lock_file() {
  printf '%s/run.lock' "${HARNESS_DIR}"
}

# terraform's own state lock only protects a single apply/destroy call, and
# run_terraform_command_with_retry (see "Error acquiring the state lock"
# handling above) treats lock contention as transient and retries -- so two
# overlapping `deploy`/`teardown` invocations don't fail fast against each
# other, they interleave for as long as both keep running, each retrying past
# the other's lock and issuing conflicting Azure API calls (observed live as
# repeated "AnotherOperationInProgress" 409s during a stuck private-endpoint
# destroy). Fail the second invocation immediately instead.
acquire_run_lock() {
  local lock_file existing_pid
  lock_file="$(run_lock_file)"
  mkdir -p "${HARNESS_DIR}"
  if [[ -f "${lock_file}" ]]; then
    existing_pid="$(cat "${lock_file}" 2>/dev/null || true)"
    if [[ -n "${existing_pid}" ]] && pid_is_running "${existing_pid}"; then
      die "Another deploy/teardown/verify/proof run (pid ${existing_pid}) is already active for this environment (${lock_file}). Wait for it to finish, or confirm that pid is really dead, before retrying."
    fi
    warn "Removing stale run lock ${lock_file} (pid ${existing_pid:-unknown} is not running)."
  fi
  printf '%s\n' "$$" > "${lock_file}"
  add_exit_trap release_run_lock
}

release_run_lock() {
  local lock_file existing_pid
  lock_file="$(run_lock_file)"
  [[ -f "${lock_file}" ]] || return 0
  existing_pid="$(cat "${lock_file}" 2>/dev/null || true)"
  [[ "${existing_pid}" == "$$" ]] && rm -f "${lock_file}"
  return 0
}

setup_run_init() {
  local run_name="$1"
  local stage_total="$2"
  local run_id

  acquire_run_lock

  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  SETUP_RUN_DIR="${HARNESS_DIR}/runs/${run_id}-${run_name}"
  SETUP_STAGE_LOG_DIR="${SETUP_RUN_DIR}/logs"
  SETUP_STAGE_INDEX=0
  SETUP_STAGE_TOTAL="${stage_total}"
  SETUP_STAGE_RESULTS=()

  mkdir -p "${SETUP_STAGE_LOG_DIR}"
  printf 'stage\tresult\tduration_seconds\tlog\n' > "${SETUP_RUN_DIR}/stages.tsv"
  log "Run logs: ${SETUP_RUN_DIR}"
}

run_stage() {
  local stage_name="$1"
  shift

  local log_file start_epoch end_epoch duration exit_code
  SETUP_STAGE_INDEX=$((SETUP_STAGE_INDEX + 1))
  log_file="${SETUP_STAGE_LOG_DIR}/$(printf '%02d' "${SETUP_STAGE_INDEX}")-${stage_name}.log"
  start_epoch="$(date +%s)"

  log "[${SETUP_STAGE_INDEX}/${SETUP_STAGE_TOTAL}] ${stage_name} started"
  set +e
  ( set -e; "$@" ) 2>&1 | tee "${log_file}"
  exit_code=${PIPESTATUS[0]}
  set -e

  end_epoch="$(date +%s)"
  duration=$((end_epoch - start_epoch))

  if [[ "${exit_code}" -eq 0 ]]; then
    log "[${SETUP_STAGE_INDEX}/${SETUP_STAGE_TOTAL}] ${stage_name} ok (${duration}s)"
    SETUP_STAGE_RESULTS+=("${stage_name}:PASS:${duration}s")
    printf '%s\tPASS\t%s\t%s\n' "${stage_name}" "${duration}" "${log_file}" >> "${SETUP_RUN_DIR}/stages.tsv"
    return 0
  fi

  warn "[${SETUP_STAGE_INDEX}/${SETUP_STAGE_TOTAL}] ${stage_name} failed (${duration}s). See ${log_file}"
  SETUP_STAGE_RESULTS+=("${stage_name}:FAIL:${duration}s")
  printf '%s\tFAIL\t%s\t%s\n' "${stage_name}" "${duration}" "${log_file}" >> "${SETUP_RUN_DIR}/stages.tsv"
  setup_run_summary
  exit "${exit_code}"
}

setup_run_summary() {
  local result_line stage_name stage_result stage_duration

  [[ -n "${SETUP_RUN_DIR}" ]] || return 0
  {
    printf '# Setup Run Summary\n\n'
    printf 'Run directory: `%s`\n\n' "${SETUP_RUN_DIR}"
    printf '| Stage | Result | Duration |\n'
    printf '|---|---:|---:|\n'
    for result_line in "${SETUP_STAGE_RESULTS[@]}"; do
      IFS=':' read -r stage_name stage_result stage_duration <<<"${result_line}"
      printf '| `%s` | %s | %s |\n' "${stage_name}" "${stage_result}" "${stage_duration}"
    done
  } > "${SETUP_RUN_DIR}/summary.md"

  log "Summary: ${SETUP_RUN_DIR}/summary.md"
}

deploy_e2e_cleanup() {
  if [[ "${DEPLOY_E2E_STARTED_TUNNEL:-0}" == "1" ]]; then
    bastion_tunnel stop >/dev/null 2>&1 || true
  fi
}

ensure_deploy_e2e_bastion_access() {
  local kubeconfig_path bastion_port requested_bastion_port candidate_bastion_port

  bastion_port="${ANYSCALE_BASTION_PORT:-${DEFAULT_BASTION_TUNNEL_PORT}}"

  if bastion_tunnel status >/dev/null 2>&1; then
    kubeconfig_path="$(bastion_kubeconfig_path)"
    if [[ -f "${kubeconfig_path}" ]] && kubectl_readyz "${kubeconfig_path}" >/dev/null 2>&1; then
      log "Reusing existing Bastion tunnel"
    else
      warn "Existing Bastion tunnel is not responding to kubectl /readyz; restarting it."
      bastion_tunnel stop >/dev/null 2>&1 || true
      bastion_tunnel start --port "${bastion_port}"
      DEPLOY_E2E_STARTED_TUNNEL=1
    fi
  else
    requested_bastion_port="${bastion_port}"
    if listener_is_ready "${bastion_port}" && ! port_listeners_are_bastion_tunnels "${bastion_port}"; then
      for ((candidate_bastion_port = bastion_port + 1; candidate_bastion_port <= bastion_port + 20; candidate_bastion_port++)); do
        if ! listener_is_ready "${candidate_bastion_port}"; then
          bastion_port="${candidate_bastion_port}"
          warn "Local port ${requested_bastion_port} is already in use; using Bastion port ${bastion_port} instead."
          break
        fi
      done
      if [[ "${bastion_port}" == "${requested_bastion_port}" ]]; then
        die "Local port ${requested_bastion_port} and the next 20 ports are all in use by non-Bastion listeners. Free a port or set ANYSCALE_BASTION_PORT to an open port."
      fi
    fi

    bastion_tunnel start --port "${bastion_port}"
    DEPLOY_E2E_STARTED_TUNNEL=1
  fi

  kubeconfig_path="$(kubeconfig_bastion --print-path)"
  export_kubeconfig_env "${kubeconfig_path}"
  log "Using Bastion-backed kubeconfig ${KUBECONFIG}"
  if ! kubectl_readyz "${kubeconfig_path}" >/dev/null 2>&1; then
    warn "Bastion-backed kubeconfig is not responding after tunnel selection; restarting Bastion tunnel and retrying."
    bastion_tunnel stop >/dev/null 2>&1 || true
    bastion_tunnel start --port "${bastion_port}"
    DEPLOY_E2E_STARTED_TUNNEL=1
    kubeconfig_path="$(kubeconfig_bastion --print-path)"
    export_kubeconfig_env "${kubeconfig_path}"
  fi

  kubectl --request-timeout="${SETUP_TIMEOUT_KUBECTL_READY_SECONDS}s" get nodes -o wide || {
    warn "kubectl node listing failed through Bastion; restarting Bastion tunnel once more."
    bastion_tunnel stop >/dev/null 2>&1 || true
    bastion_tunnel start --port "${bastion_port}"
    DEPLOY_E2E_STARTED_TUNNEL=1
    kubeconfig_path="$(kubeconfig_bastion --print-path)"
    export_kubeconfig_env "${kubeconfig_path}"
    kubectl --request-timeout="${SETUP_TIMEOUT_KUBECTL_READY_SECONDS}s" get nodes -o wide
  }
}

ensure_direct_private_cluster_access() {
  # Direct private AKS API access from inside the VNet (no Bastion tunnel).
  local rg cluster kubeconfig_file
  # Derive names from env (TF_VAR_*) rather than terraform output: an in-VNet
  # runner may have no local Terraform state, and these match Terraform's
  # resource_group_name / aks_cluster_name outputs exactly.
  rg="$(resource_group_name)"
  cluster="$(target_aks_cluster_name)"
  [[ -n "${rg}" && -n "${cluster}" ]] || die "Could not derive the resource group and AKS cluster name from TF_VAR_* env vars."

  kubeconfig_file="${HARNESS_DIR}/kubeconfig.direct"
  mkdir -p "${HARNESS_DIR}"

  az aks get-credentials \
    --resource-group "${rg}" \
    --name "${cluster}" \
    --file "${kubeconfig_file}" \
    --overwrite-existing \
    --only-show-errors >/dev/null

  # On the jump host az is authenticated via managed identity; kubelogin in
  # azurecli mode reuses that token. The private API FQDN resolves through the
  # foundation DNS Private Resolver from inside the VNet.
  KUBECONFIG="${kubeconfig_file}" kubelogin convert-kubeconfig -l azurecli >/dev/null

  export_kubeconfig_env "${kubeconfig_file}"
  log "Using direct private AKS kubeconfig ${KUBECONFIG} (in-VNet private API access)"
  kubectl --request-timeout="${SETUP_TIMEOUT_KUBECTL_READY_SECONDS}s" get nodes -o wide
}

# Capability probe: can this machine reach the AKS API server directly, i.e. does
# the cluster's private FQDN resolve to a private address from here?
#
# Memoized because the access helpers are called repeatedly per run, but ONLY for
# definitive answers — those where the private FQDN was actually retrieved. A
# failure to look the cluster up is not evidence of non-adjacency: during e2e the
# first call can land before the cluster exists, and caching "no" there would pin
# an in-VNet runner to a Bastion tunnel for the rest of the run.
PRIVATE_AKS_API_DNS_READY_CACHE=""
private_aks_api_dns_ready() {
  local rg cluster private_fqdn

  case "${PRIVATE_AKS_API_DNS_READY_CACHE}" in
    yes) return 0 ;;
    no) return 1 ;;
  esac

  rg="$(resource_group_name)"
  cluster="$(target_aks_cluster_name)"
  [[ -n "${rg}" && -n "${cluster}" ]] || return 1

  private_fqdn="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az aks show --resource-group "${rg}" --name "${cluster}" \
    --query privateFqdn -o tsv --only-show-errors 2>/dev/null || true)"
  # No FQDN yet (cluster absent, or a public-only cluster): stay uncached.
  [[ -n "${private_fqdn}" && "${private_fqdn}" != "null" ]] || return 1

  if host_resolves_privately "${private_fqdn}"; then
    PRIVATE_AKS_API_DNS_READY_CACHE="yes"
    return 0
  fi
  PRIVATE_AKS_API_DNS_READY_CACHE="no"
  return 1
}

ensure_cluster_access() {
  # Position-aware private AKS access: use the API server directly when this
  # machine is inside the VNet, otherwise tunnel through Bastion. Deliberately
  # not keyed off any declared mode — the deciding factor is whether the
  # private API resolves from here, which the probe answers directly. Set
  # ANYSCALE_FORCE_BASTION=true to force the tunnel even when adjacent.
  if [[ "${ANYSCALE_FORCE_BASTION:-false}" != "true" ]] && private_aks_api_dns_ready; then
    ensure_direct_private_cluster_access
    return 0
  fi
  ensure_deploy_e2e_bastion_access
}

remove_local_terraform_state_artifacts() {
  rm -f terraform.tfstate terraform.tfstate.backup .terraform.tfstate.lock.info tfplan tfplan.* *.tfplan
  rm -f terraform.tfstate.*.backup
  rm -rf terraform.tfstate.d
}

ensure_local_state_matches_target() {
  local desired_resource_group current_resource_group backup_path

  [[ -f terraform.tfstate ]] || return 0

  desired_resource_group="$(resource_group_name)"
  current_resource_group="$(jq -r '.outputs.resource_group_name.value // empty' terraform.tfstate 2>/dev/null || true)"

  [[ -n "${current_resource_group}" ]] || return 0
  [[ "${current_resource_group}" == "${desired_resource_group}" ]] && return 0

  backup_path="$(terraform_state_backup_path "retarget-${current_resource_group}")"
  cp terraform.tfstate "${backup_path}"

  if [[ -f terraform.tfstate.backup ]]; then
    cp terraform.tfstate.backup "${backup_path}.previous"
  fi

  warn "Local Terraform state targets ${current_resource_group}, but the current deployment target is ${desired_resource_group}."
  log "Backed up the previous local Terraform state to ${backup_path}"
  log "Clearing local Terraform state and saved plans before continuing with the new target"
  remove_local_terraform_state_artifacts
}

deploy_e2e_phase1() {
  log "Phase 1: build the Azure foundation and private AKS cluster"
  export TF_VAR_anyscale_platform='{"enabled":false}'
  plan
  apply
  outputs
}

deploy_e2e_phase2() {
  log "Phase 2: install the Anyscale platform extension and cloud resource"
  unset TF_VAR_anyscale_platform
  plan
  apply
  outputs
}

# Opens a Bastion tunnel to the Linux jump host, syncs the bootstrap script and
# local chart, then SSH-invokes scripts/bootstrap-k8s.sh for the given phase.
# Called from deploy_bootstrap_a_stage / deploy_bootstrap_b_stage.
invoke_jump_host_bootstrap() {
  local phase="$1"
  load_env
  require_cmd az
  require_cmd rsync
  require_cmd jq

  local canonical_repo_path
  canonical_repo_path="${ANYSCALE_AKS_REPO_PATH:-/opt/anyscale-aks-sample}"

  # ---- Foundation outputs (vm id, Bastion, admin username, gateway IP) -----
  local output_json admin_rg vm_id bastion_name_val admin_user gateway_ip
  output_json="$(terraform output -json)"
  admin_rg="$(resource_group_name)"
  vm_id="$(jq -r '.linux_jump_host_vm_id.value // empty' <<<"${output_json}")"
  bastion_name_val="$(jq -r '.bastion_name.value // empty' <<<"${output_json}")"
  admin_user="$(jq -r '.linux_jump_host_admin_username.value // empty' <<<"${output_json}")"
  gateway_ip="$(jq -r '.anyscale_userdata_gateway_ip.value // empty' <<<"${output_json}")"

  [[ -n "${vm_id}" ]] || die "Admin output linux_jump_host_vm_id is empty. Apply Module 1 first."
  [[ -n "${bastion_name_val}" ]] || die "Admin output bastion_name is empty. Apply Module 1 first."
  [[ -n "${gateway_ip}" ]] || die "Admin output anyscale_userdata_gateway_ip is empty. Apply Module 1 first."
  [[ -n "${admin_user}" ]] || admin_user="azureoperator"

  local ssh_key
  ssh_key="${SSH_PRIVATE_KEY_PATH:-${HOME}/.ssh/id_ed25519}"
  [[ -f "${ssh_key}" ]] || die "SSH private key not found at ${ssh_key}. Set SSH_PRIVATE_KEY_PATH."

  # ---- Workload Terraform outputs (AKS, bootstrap contract) ----------------
  local aks_cluster aks_rg bootstrap_contract
  aks_cluster="$(terraform_output_raw aks_cluster_name)"
  aks_rg="$(terraform_output_raw resource_group_name)"
  [[ -n "${aks_cluster}" ]] || die "Terraform output aks_cluster_name is empty. Run foundation first."
  [[ -n "${aks_rg}" ]] || die "Terraform output resource_group_name is empty."

  bootstrap_contract="$(terraform_output_json bootstrap_script_contract)"

  local operator_ns operator_sa extension_release_name tenant_id identity_client_id
  operator_ns="$(jq -r '.operator_namespace' <<<"${bootstrap_contract}")"
  operator_sa="$(jq -r '.operator_service_account' <<<"${bootstrap_contract}")"
  extension_release_name="$(jq -r '.extension_release_name' <<<"${bootstrap_contract}")"
  tenant_id="$(jq -r '.azure_tenant_id' <<<"${bootstrap_contract}")"
  identity_client_id="$(jq -r '.operator_identity_client_id' <<<"${bootstrap_contract}")"

  local gpu_ns nvidia_release nvidia_version
  gpu_ns="$(jq -r '.helm_releases.nvidia_device_plugin.namespace' <<<"${bootstrap_contract}")"
  nvidia_release="$(jq -r '.helm_releases.nvidia_device_plugin.release_name' <<<"${bootstrap_contract}")"
  nvidia_version="$(jq -r '.helm_releases.nvidia_device_plugin.chart_version' <<<"${bootstrap_contract}")"

  local gw_release gw_name gw_class gw_service_name gw_https_enabled
  gw_release="$(jq -r '.helm_releases.anyscale_gateway.release_name' <<<"${bootstrap_contract}")"
  gw_name="$(jq -r '.helm_releases.anyscale_gateway.gateway_name' <<<"${bootstrap_contract}")"
  gw_class="$(jq -r '.helm_releases.anyscale_gateway.gateway_class_name' <<<"${bootstrap_contract}")"
  gw_service_name="$(jq -r '.helm_releases.anyscale_gateway.service_name' <<<"${bootstrap_contract}")"
  gw_https_enabled="$(jq -r '(.helm_releases.anyscale_gateway.https_listeners | length) > 0' <<<"${bootstrap_contract}")"

  # Phase-b requires the cloud deployment ID from the post-platform apply.
  local cloud_deployment_id=""
  if [[ "${phase}" == "phase-b" ]]; then
    cloud_deployment_id="$(terraform_output_raw anyscale_cloud_deployment_id 2>/dev/null || true)"
    [[ -n "${cloud_deployment_id}" && "${cloud_deployment_id}" != "null" ]] \
      || die "Terraform output anyscale_cloud_deployment_id is empty. Apply platform stage first."
  fi

  # ---- Open Bastion tunnel to jump host port 22 ----------------------------
  # A prior invocation of this stage that was killed hard (not a clean exit)
  # leaves its `az network bastion tunnel` child orphaned, still holding its
  # local port -- the EXIT trap below never gets to run. Reap any such stale
  # tunnel on a candidate port before giving up on it, the same way
  # bastion_tunnel start() self-heals its own port, so an interrupted prior
  # run doesn't permanently burn through the 20-port search window.
  local jh_port requested_jh_port candidate_jh_port jh_pid known_hosts_file outer_exit_trap
  requested_jh_port="${BOOTSTRAP_BASTION_SSH_PORT:-50023}"
  jh_port="${requested_jh_port}"
  if listener_is_ready "${jh_port}" && port_listeners_are_bastion_tunnels "${jh_port}"; then
    warn "Removing stale Bastion tunnel listener on 127.0.0.1:${jh_port} before opening a fresh one."
    stop_bastion_listeners_on_port "${jh_port}" || true
    wait_for_listener_shutdown "${jh_port}" 10 || true
  fi
  if listener_is_ready "${jh_port}"; then
    for ((candidate_jh_port = requested_jh_port + 1; candidate_jh_port <= requested_jh_port + 20; candidate_jh_port++)); do
      if listener_is_ready "${candidate_jh_port}" && port_listeners_are_bastion_tunnels "${candidate_jh_port}"; then
        warn "Removing stale Bastion tunnel listener on 127.0.0.1:${candidate_jh_port} before opening a fresh one."
        stop_bastion_listeners_on_port "${candidate_jh_port}" || true
        wait_for_listener_shutdown "${candidate_jh_port}" 10 || true
      fi
      if ! listener_is_ready "${candidate_jh_port}"; then
        jh_port="${candidate_jh_port}"
        warn "Local bootstrap SSH port ${requested_jh_port} is already in use; using ${jh_port} instead."
        break
      fi
    done
    if [[ "${jh_port}" == "${requested_jh_port}" ]]; then
      die "Local bootstrap SSH port ${requested_jh_port} and the next 20 ports are already in use by non-Bastion-tunnel listeners. Free a port or set BOOTSTRAP_BASTION_SSH_PORT to an open port."
    fi
  fi
  known_hosts_file="$(mktemp "${TMPDIR:-/tmp}/anyscale-bastion-known-hosts.XXXXXX")"
  outer_exit_trap="$(trap -p EXIT || true)"
  log "Opening Bastion tunnel to jump host on local port ${jh_port} ..."
  az network bastion tunnel \
    --name "${bastion_name_val}" \
    --resource-group "${admin_rg}" \
    --target-resource-id "${vm_id}" \
    --resource-port 22 \
    --port "${jh_port}" >/dev/null 2>&1 &
  jh_pid=$!
  trap 'rm -f "${known_hosts_file}"; kill "${jh_pid}" 2>/dev/null || true; [[ "${outer_exit_trap}" == *deploy_e2e_cleanup* ]] && deploy_e2e_cleanup' EXIT

  local waited=0
  while ! { command -v lsof >/dev/null 2>&1 && lsof -i :"${jh_port}" >/dev/null 2>&1; }; do
    sleep 1
    waited=$((waited + 1))
    if [[ ${waited} -ge 20 ]]; then
      kill "${jh_pid}" 2>/dev/null || true
      die "Bastion tunnel did not bind local port ${jh_port} within 20 s."
    fi
  done
  log "Bastion tunnel ready on 127.0.0.1:${jh_port} (pid ${jh_pid})."

  local ssh_base_opts="-p ${jh_port} -i ${ssh_key} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${known_hosts_file} -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2"
  local ssh_target="${admin_user}@127.0.0.1"

  # Ensure canonical path exists and is owned by the admin user. Bastion-backed
  # SSH can briefly report connection-refused while the tunnel is still warming.
  local ssh_attempt ssh_ok=0
  for ssh_attempt in {1..6}; do
    # shellcheck disable=SC2029
    if ssh ${ssh_base_opts} "${ssh_target}" \
      "sudo mkdir -p '${canonical_repo_path}/scripts/lib' \
       && sudo mkdir -p '${canonical_repo_path}/infra/terraform/modules/cluster_bootstrap/charts' \
       && sudo chown -R ${admin_user} '${canonical_repo_path}'" >/dev/null 2>&1; then
      ssh_ok=1
      break
    fi
    if [[ ${ssh_attempt} -lt 6 ]]; then
      warn "Bastion-backed SSH is not ready yet (attempt ${ssh_attempt}/6); retrying in 5s..."
      sleep 5
    fi
  done
  [[ ${ssh_ok} -eq 1 ]] || die "Unable to reach the jump host over Bastion after 6 SSH attempts."

  # ---- Sync repo contents to the jump host before remote bootstrap --------
  log "Syncing repository contents to jump host ..."
  rsync -az --delete \
    -e "ssh ${ssh_base_opts}" \
    --exclude '.git/' \
    --exclude '.terraform/' \
    --exclude '.cache/' \
    --exclude '.venv/' \
    --exclude '*.tfstate*' \
    "${ROOT_DIR}/" \
    "${ssh_target}:${canonical_repo_path}/"

  if [[ -f "${ROOT_DIR}/.env" ]]; then
    log "Copying .env to jump host ..."
    rsync -az \
      -e "ssh ${ssh_base_opts}" \
      "${ROOT_DIR}/.env" \
      "${ssh_target}:${canonical_repo_path}/.env"
  fi

  log "Ensuring jump host operator tooling is present..."
  # shellcheck disable=SC2029
  ssh ${ssh_base_opts} "${ssh_target}" \
    "cd '${canonical_repo_path}' \
     && if ! command -v az >/dev/null 2>&1 \
        || ! command -v kubectl >/dev/null 2>&1 \
        || ! command -v kubelogin >/dev/null 2>&1 \
        || ! command -v helm >/dev/null 2>&1; then \
          bash scripts/bootstrap-jump-host.sh; \
        elif ! az account show --only-show-errors >/dev/null 2>&1; then \
          az login --identity --only-show-errors >/dev/null; \
        fi"

  # ---- Invoke bootstrap-k8s.sh on the jump host via piped bash script ------
  log "Running bootstrap-k8s.sh ${phase} on jump host ..."
  {
    printf 'set -euo pipefail\n'
    printf 'export %s=%q\n' "AKS_CLUSTER_NAME"              "${aks_cluster}"
    printf 'export %s=%q\n' "AKS_RG"                        "${aks_rg}"
    printf 'export %s=%q\n' "OPERATOR_NAMESPACE"             "${operator_ns}"
    printf 'export %s=%q\n' "OPERATOR_SA_NAME"               "${operator_sa}"
    printf 'export %s=%q\n' "WORKLOAD_IDENTITY_CLIENT_ID"    "${identity_client_id}"
    printf 'export %s=%q\n' "WORKLOAD_IDENTITY_TENANT_ID"    "${tenant_id}"
    printf 'export %s=%q\n' "EXTENSION_RELEASE_NAME"         "${extension_release_name}"
    printf 'export %s=%q\n' "GPU_RESOURCES_NAMESPACE"        "${gpu_ns}"
    printf 'export %s=%q\n' "NVIDIA_RELEASE_NAME"            "${nvidia_release}"
    printf 'export %s=%q\n' "NVIDIA_CHART_VERSION"           "${nvidia_version}"
    printf 'export %s=%q\n' "GPU_POOLS_ENABLED"              "$(gpu_pools_enabled && printf 'true' || printf 'false')"
    printf 'export %s=%q\n' "GATEWAY_RELEASE_NAME"           "${gw_release}"
    printf 'export %s=%q\n' "GATEWAY_NAME"                   "${gw_name}"
    printf 'export %s=%q\n' "GATEWAY_CLASS_NAME"             "${gw_class}"
    printf 'export %s=%q\n' "GATEWAY_SERVICE_NAME"           "${gw_service_name}"
    printf 'export %s=%q\n' "GATEWAY_SERVICE_HTTPS_ENABLED"  "${gw_https_enabled}"
    printf 'export %s=%q\n' "GATEWAY_PRIVATE_IP"             "${gateway_ip}"
    if [[ -n "${cloud_deployment_id}" ]]; then
      printf 'export %s=%q\n' "CLOUD_DEPLOYMENT_ID"          "${cloud_deployment_id}"
    fi
    printf 'cd %q && bash scripts/bootstrap-k8s.sh %q\n' \
      "${canonical_repo_path}" "${phase}"
  } | ssh ${ssh_base_opts} "${ssh_target}" bash

  kill "${jh_pid}" 2>/dev/null || true
  rm -f "${known_hosts_file}"
  if [[ -n "${outer_exit_trap}" ]]; then
    eval "${outer_exit_trap}"
  else
    trap - EXIT
  fi
  log "Jump host bootstrap ${phase} complete."
}

require_full_deploy_inputs() {
  load_env
  sync_anyscale_cli_env
  require_env_var ANYSCALE_CLOUD_NAME
  require_anyscale_cli_auth
  require_cmd rsync
}

deploy_prepare_stage() {
  require_full_deploy_inputs
  preflight
}

deploy_reset_stage() {
  load_env
  sync_anyscale_cli_env

  if [[ "${DEPLOY_FROM_SCRATCH}" == true ]]; then
    if [[ "${DEPLOY_FORCE_YES}" == true ]]; then
      nuke --yes
    else
      nuke
    fi
  else
    ensure_local_state_matches_target
  fi
}

deploy_init_validate_stage() {
  tf_init
  validate
}

foundation_state_complete() {
  terraform state show module.aks.azurerm_kubernetes_cluster.this >/dev/null 2>&1 \
    && terraform state show module.aks.azurerm_monitor_data_collection_rule.container_insights >/dev/null 2>&1
}

# Returns 0 (true) when a phase-1 (anyscale platform disabled) plan reports
# pending changes, i.e. the foundation is NOT fully reconciled. A coarse
# "cluster + DCR exist in state" check is not enough: an apply that aborted
# mid-way (for example a transient private-endpoint InternalServerError) leaves
# the sentinel resources present but other foundation resources — the AMPLS
# private endpoint, jump-host role assignments — missing. Treat a plan error as
# drift so a partial foundation is reconciled rather than silently skipped.
foundation_phase1_has_drift() {
  local drift_plan rc
  drift_plan="tfplan.foundation-drift"
  render_tfvars
  ensure_aks_app_routing_gateway_api
  ensure_anyscale_marketplace_agreement_accepted
  ensure_anyscale_platform_deployment_state
  log "terraform plan -detailed-exitcode (foundation drift check)"
  rc=0
  TF_VAR_anyscale_platform='{"enabled":false}' \
    run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_PLAN_SECONDS}" \
    terraform plan -input=false -detailed-exitcode -out="${drift_plan}" >/dev/null 2>&1 || rc=$?
  rm -f "${drift_plan}"
  # terraform plan -detailed-exitcode: 0=no changes, 1=error, 2=changes.
  [[ "${rc}" -ne 0 ]]
}

deploy_foundation_stage() {
  load_env
  sync_anyscale_cli_env

  if aks_cluster_exists_for_target && foundation_state_complete && ! foundation_phase1_has_drift; then
    log "Target AKS cluster $(target_aks_cluster_name) and foundation are fully reconciled. Skipping phase-1 apply."
    return 0
  fi

  ( deploy_e2e_phase1 )
}

deploy_platform_stage() {
  deploy_e2e_phase2
}

deploy_bootstrap_a_stage() {
  invoke_jump_host_bootstrap "phase-a"
}

deploy_bootstrap_b_stage() {
  invoke_jump_host_bootstrap "phase-b"
}

deploy_workspaces_stage() {
  ensure_cluster_access
  anyscale_workspaces_register
}

deploy_health_stage() {
  health
}

deploy() {
  DEPLOY_FROM_SCRATCH=false
  DEPLOY_FORCE_YES=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from-scratch)
        DEPLOY_FROM_SCRATCH=true
        shift
        ;;
      --yes|-y)
        DEPLOY_FORCE_YES=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh deploy
  ./scripts/setup.sh deploy --from-scratch --yes

Runs the full private AKS + Anyscale deployment without a token pause.
Use `anyscale login` for local OAuth auth. ANYSCALE_CLI_TOKEN is optional for
non-interactive and in-pod Anyscale CLI calls.
USAGE
        return 0
        ;;
      *)
        die "Unknown deploy option: $1"
        ;;
    esac
  done

  [[ "${DEPLOY_FROM_SCRATCH}" == false && "${DEPLOY_FORCE_YES}" == true ]] && die "--yes is only valid with --from-scratch."

  DEPLOY_E2E_STARTED_TUNNEL=0
  trap deploy_e2e_cleanup EXIT

  setup_run_init "deploy" 9
  run_stage "prepare"               deploy_prepare_stage
  run_stage "reset-or-state"        deploy_reset_stage
  run_stage "terraform-init-validate" deploy_init_validate_stage
  run_stage "foundation"            deploy_foundation_stage
  run_stage "bootstrap-a"           deploy_bootstrap_a_stage
  run_stage "platform"              deploy_platform_stage
  run_stage "bootstrap-b"           deploy_bootstrap_b_stage
  run_stage "workspaces"            deploy_workspaces_stage
  run_stage "health"                deploy_health_stage
  setup_run_summary

  log "Deployment complete. Run ./scripts/anyscale-aks.sh verify --full, then ./scripts/anyscale-aks.sh proof all."
}

verify_static_stage() {
  preflight
  tf_init
  validate
}

verify_live_stage() {
  health
  if [[ "${VERIFY_SKIP_OBSERVABILITY}" == true ]]; then
    validate_focused --skip-observability
  else
    validate_focused
  fi
}

verify() {
  local mode="full"
  VERIFY_SKIP_OBSERVABILITY=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --static)
        mode="static"
        shift
        ;;
      --live)
        mode="live"
        shift
        ;;
      --full)
        mode="full"
        shift
        ;;
      --skip-observability)
        VERIFY_SKIP_OBSERVABILITY=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh verify --static
  ./scripts/setup.sh verify --live [--skip-observability]
  ./scripts/setup.sh verify --full [--skip-observability]
USAGE
        return 0
        ;;
      *)
        die "Unknown verify option: $1"
        ;;
    esac
  done

  case "${mode}" in
    static)
      setup_run_init "verify-static" 1
      run_stage "static" verify_static_stage
      ;;
    live)
      setup_run_init "verify-live" 1
      run_stage "live" verify_live_stage
      ;;
    full)
      setup_run_init "verify-full" 2
      run_stage "static" verify_static_stage
      run_stage "live" verify_live_stage
      ;;
    *)
      die "Unknown verify mode: ${mode}"
      ;;
  esac

  setup_run_summary
}

###############################################################################
outputs() {
  load_env
  sync_anyscale_cli_env
  terraform output
}

###############################################################################
# Read-only environment status. Kubernetes checks require an active Bastion
# tunnel because the AKS API server is private.
###############################################################################
status() {
  load_env
  sync_anyscale_cli_env

  local resource_group cluster private_fqdn
  resource_group="$(terraform_output_raw resource_group_name)"
  cluster="$(terraform_output_raw aks_cluster_name)"
  private_fqdn="$(terraform_output_raw aks_private_fqdn)"

  [[ -n "${resource_group}" && -n "${cluster}" ]] || die "Terraform outputs are missing. Run ./scripts/setup.sh deploy first."

  log "Terraform deployment"
  printf '  Resource group: %s\n' "${resource_group}"
  printf '  AKS cluster:    %s\n' "${cluster}"
  printf '  Private FQDN:   %s\n' "${private_fqdn}"

  log "Anyscale CLI metadata"
  printf '  Host:               %s\n' "${ANYSCALE_HOST:-$(default_anyscale_host)}"
  printf '  Browser auth host:  %s\n' "${ANYSCALE_BROWSER_AUTH_HOST:-$(default_anyscale_browser_auth_host)}"
  printf '  Cloud name:         %s\n' "${ANYSCALE_CLOUD_NAME:-<unset>}"
  printf '  Cloud deployment:   %s\n' "${ANYSCALE_CLOUD_DEPLOYMENT_ID:-<unset>}"

  log "Azure AKS state"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az aks show \
    --resource-group "${resource_group}" \
    --name "${cluster}" \
    --query '{provisioningState:provisioningState,power:powerState.code,private:apiServerAccessProfile.enablePrivateCluster,vnetIntegration:apiServerAccessProfile.enableVnetIntegration,kubernetesVersion:kubernetesVersion}' \
    --output table \
    --only-show-errors

  log "Node pools"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az aks nodepool list \
    --resource-group "${resource_group}" \
    --cluster-name "${cluster}" \
    --query '[].{name:name,mode:mode,vmSize:vmSize,count:count,min:minCount,max:maxCount,state:provisioningState}' \
    --output table \
    --only-show-errors

  log "Enterprise DNS path"
  printf '  VNet DNS servers:             %s\n' "$(terraform output -json vnet_dns_servers | jq -r 'join(", ")')"
  printf '  DNS resolver inbound IP:      %s\n' "$(terraform output -raw dns_resolver_inbound_endpoint_ip)"
  printf '  Azure Firewall private IP:    %s\n' "$(terraform output -raw firewall_private_ip)"

  if kubectl get nodes --request-timeout=15s >/dev/null 2>&1; then
    log "Kubernetes nodes"
    kubectl get nodes -o wide

    log "Helm add-ons"
    helm list -n gpu-resources || true
    helm list -n "$(anyscale_gateway_namespace)" || true

    log "App-routing Gateway"
    kubectl get gateway -n "$(anyscale_gateway_namespace)" "$(anyscale_gateway_name)" -o wide || true
    kubectl get service -n "$(anyscale_gateway_namespace)" "$(anyscale_gateway_service_name)" -o wide || true

    if [[ -n "${ANYSCALE_CLI_TOKEN:-}" ]]; then
      log "Run ./scripts/setup.sh health for Azure, operator, workspace, and recent log checks."
    fi
  else
    log "kubectl cannot reach the private API server from this shell. Run ./scripts/setup.sh verify --live to refresh Bastion-backed access and retry live checks."
  fi
}

health() {
  local cpu_workspace_name="aks-cpu-workspace"
  local gpu_workspace_name="aks-gpu-workspace"
  local resource_group cluster namespace extension_name cloud_resource_id cli_bin
  local aks_provisioning_state aks_power_state extension_state cloud_state
  local cpu_status_raw cpu_status gpu_status_raw gpu_status
  local cpu_health_wait_log gpu_health_wait_log
  local cpu_head_pod operator_log_matches workspace_log_matches

  load_env
  sync_anyscale_cli_env
  require_cmd az
  require_cmd jq
  require_anyscale_cli_auth
  ensure_cluster_access
  require_env_var ANYSCALE_CLOUD_NAME

  resource_group="$(resource_group_name)"
  cluster="$(target_aks_cluster_name)"
  extension_name="$(anyscale_extension_resource_name)"
  cloud_resource_id="$(anyscale_cloud_resource_azure_id)"
  namespace="${TF_VAR_anyscale_operator_namespace}"
  cli_bin="$(anyscale_cli_bin)"

  [[ -n "${resource_group}" && -n "${cluster}" ]] || die "Resource group and AKS cluster names are unavailable. Ensure TF_VAR_project/environment/region_short are set in .env."
  [[ -n "${extension_name}" ]] || die "Could not determine the Anyscale AKS extension name. Ensure the Anyscale.AKS.Operator extension is installed (run ./scripts/setup.sh deploy first)."
  [[ -n "${cloud_resource_id}" ]] || die "Could not determine the Anyscale cloud resource id."

  aks_provisioning_state="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az aks show \
    --resource-group "${resource_group}" \
    --name "${cluster}" \
    --query 'provisioningState' \
    --output tsv \
    --only-show-errors)"
  aks_power_state="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az aks show \
    --resource-group "${resource_group}" \
    --name "${cluster}" \
    --query 'powerState.code' \
    --output tsv \
    --only-show-errors)"
  [[ "${aks_provisioning_state}" == "Succeeded" ]] || die "AKS cluster ${cluster} provisioningState is ${aks_provisioning_state}, expected Succeeded."
  [[ "${aks_power_state}" == "Running" ]] || die "AKS cluster ${cluster} power state is ${aks_power_state}, expected Running."
  log "Azure AKS cluster ${cluster} is ${aks_provisioning_state}/${aks_power_state}."

  extension_state="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az k8s-extension show \
    --cluster-type managedClusters \
    --cluster-name "${cluster}" \
    --resource-group "${resource_group}" \
    --name "${extension_name}" \
    --query 'provisioningState' \
    --output tsv \
    --only-show-errors)"
  [[ "${extension_state}" == "Succeeded" ]] || die "Anyscale AKS extension ${extension_name} provisioningState is ${extension_state}, expected Succeeded."
  log "Anyscale AKS extension ${extension_name} provisioningState=${extension_state}."

  cloud_state="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az resource show \
    --ids "${cloud_resource_id}" \
    --query 'properties.provisioningState' \
    --output tsv \
    --only-show-errors)"
  [[ "${cloud_state}" == "Succeeded" ]] || die "Anyscale cloud resource provisioningState is ${cloud_state}, expected Succeeded."
  log "Anyscale cloud resource provisioningState=${cloud_state}."

  log "Checking Kubernetes rollouts"
  kubectl rollout status deployment/anyscale-operator -n "${namespace}" --timeout=5m >/dev/null
  kubectl rollout status deployment/istiod -n aks-istio-system --timeout=5m >/dev/null
  kubectl -n "$(anyscale_gateway_namespace)" wait --for=condition=Programmed "gateway.gateway.networking.k8s.io/$(anyscale_gateway_name)" --timeout=10m >/dev/null
  log "Anyscale operator, app-routing Istio control plane, and Anyscale Gateway are Available."

  cpu_status_raw="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 status \
      --name "${cpu_workspace_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"
  cpu_status="$(normalize_anyscale_workspace_status "${cpu_status_raw}")"
  [[ -n "${cpu_status}" ]] || cpu_status="UNKNOWN"

  cpu_health_wait_log="$(harness_state_file "${cpu_workspace_name}.health.wait.log")"
  if [[ "${cpu_status}" == "RUNNING" ]]; then
    log "CPU workspace ${cpu_workspace_name} API status=${cpu_status}."
  elif [[ "${cpu_status}" =~ ^(CREATE_FAILED|FAILED|ERROR)$ ]]; then
    die "CPU workspace ${cpu_workspace_name} is unhealthy with API status ${cpu_status}."
  elif [[ "${cpu_status}" =~ ^(TERMINATED|TERMINATING)$ ]]; then
    warn "CPU workspace ${cpu_workspace_name} API status is ${cpu_status}; warm-starting before health check."
    ensure_workload_workspace_running "${cpu_workspace_name}" "${cli_bin}" "${cpu_health_wait_log}"
  else
    warn "CPU workspace ${cpu_workspace_name} API status is ${cpu_status}; confirming readiness from the Kubernetes runtime."
  fi
  wait_for_workspace_runtime_stable "${cpu_workspace_name}" "aks-cpu-" "${cpu_health_wait_log}"

  if gpu_pools_enabled; then
    gpu_status_raw="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 status \
        --name "${gpu_workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"
    gpu_status="$(normalize_anyscale_workspace_status "${gpu_status_raw}")"
    [[ -n "${gpu_status}" ]] || gpu_status="UNKNOWN"

    gpu_health_wait_log="$(harness_state_file "${gpu_workspace_name}.health.wait.log")"
    case "${gpu_status}" in
      CREATE_FAILED|FAILED|ERROR)
        die "GPU workspace ${gpu_workspace_name} is unhealthy with API status ${gpu_status}."
        ;;
      RUNNING)
        log "GPU workspace ${gpu_workspace_name} API status=${gpu_status}."
        ;;
      TERMINATED|TERMINATING)
        warn "GPU workspace ${gpu_workspace_name} API status is ${gpu_status}; warm-starting before health check."
        ensure_workload_workspace_running "${gpu_workspace_name}" "${cli_bin}" "${gpu_health_wait_log}"
        ;;
      *)
        warn "GPU workspace ${gpu_workspace_name} API status is ${gpu_status}; confirming readiness from the Kubernetes runtime."
        ;;
    esac
    wait_for_workspace_runtime_stable "${gpu_workspace_name}" "aks-gput4-" "${gpu_health_wait_log}"
  else
    log "Skipping GPU workspace health: $(gpu_disabled_notice)"
  fi

  operator_log_matches="$(kubectl logs -n "${namespace}" deploy/anyscale-operator -c operator --since=30m 2>&1 \
    | egrep -i 'error|warn|fail|exception|backoff|forbidden' \
    | tail -n 20 || true)"
  if [[ -n "${operator_log_matches}" ]]; then
    warn "Recent Anyscale operator log matches from the last 30m:"
    printf '%s\n' "${operator_log_matches}"
  else
    log "No recent Anyscale operator error/warn matches in the last 30m."
  fi

  cpu_head_pod="$(workspace_head_pod_name "${cpu_workspace_name}")"
  workspace_log_matches="$(kubectl logs -n "${namespace}" "${cpu_head_pod}" -c ray --since=30m 2>&1 \
    | egrep -i 'error|exception|traceback|fail|fatal' \
    | tail -n 20 || true)"
  if [[ -n "${workspace_log_matches}" ]]; then
    warn "Recent CPU workspace ray log matches from the last 30m:"
    printf '%s\n' "${workspace_log_matches}"
  else
    log "No recent CPU workspace ray error matches in the last 30m."
  fi

  log "Anyscale health check completed."
}

###############################################################################
# Open a private AKS API shell through Azure Bastion (az aks bastion preview).
# Docs: https://learn.microsoft.com/azure/bastion/bastion-connect-to-aks-private-cluster
###############################################################################
bastion() {
  local use_admin=false
  if [[ "${1:-}" == "--admin" ]]; then
    use_admin=true
  fi

  local rg cluster bastion_id
  rg="$(terraform output -raw resource_group_name)"
  cluster="$(terraform output -raw aks_cluster_name)"
  bastion_id="$(terraform output -json | jq -r '.aks_bastion_connect_command.value' | grep -oE '/subscriptions/[^ ]+/bastionHosts/[^ ]+')"

  ensure_bastion_extensions

  if [[ "${use_admin}" == true ]]; then
    warn "Opening break-glass admin Bastion shell. Prefer non-admin kubelogin access for normal validation."
    az aks bastion --name "${cluster}" --resource-group "${rg}" --admin --bastion "${bastion_id}" --yes
  else
    log "Opening Entra-backed Bastion shell. Run setup.sh kubeconfig inside the shell if kubectl needs conversion."
    az aks bastion --name "${cluster}" --resource-group "${rg}" --bastion "${bastion_id}" --yes
  fi
}

###############################################################################
# Check whether the optional Private Link path to the Anyscale control plane
# (module.anyscale_privatelink) is actually connected, not just deployed.
# `terraform apply` succeeds with the endpoint left Pending -- Anyscale must
# approve the cross-tenant connection on their side before it carries
# traffic -- so this is the only way to know the feature really works.
###############################################################################
privatelink_status() {
  load_env
  require_cmd az
  require_cmd jq

  local enabled endpoint_id private_ip record_fqdns connection_state
  enabled="$(terraform output -json anyscale_privatelink | jq -r '.enabled')"

  if [[ "${enabled}" != "true" ]]; then
    log "Private Link to the Anyscale control plane is disabled (TF_VAR_enable_anyscale_privatelink is not \"true\"). Nothing to check."
    return 0
  fi

  endpoint_id="$(terraform output -json anyscale_privatelink | jq -r '.endpoint_id')"
  private_ip="$(terraform output -json anyscale_privatelink | jq -r '.private_ip')"
  record_fqdns="$(terraform output -json anyscale_privatelink | jq -r '.record_fqdns | join(", ")')"

  [[ -n "${endpoint_id}" && "${endpoint_id}" != "null" ]] || die "anyscale_privatelink.endpoint_id output is empty. Run ./scripts/setup.sh deploy first."

  log "Private endpoint: ${endpoint_id}"
  log "Private IP:       ${private_ip}"
  log "DNS records:      ${record_fqdns}"

  # `az network private-endpoint-connection list --id` expects the ID of the
  # PaaS resource that OWNS the connection (storage account, ACR, ...) and
  # validates it against a fixed allow-list of first-party resource types --
  # a cross-tenant connection to an externally-vended Private Link Service
  # (like Anyscale's) is never on that list, so it always errors here. Read
  # the connection state directly off the private endpoint instead, which is
  # exactly what it exposes regardless of what's on the other end. A
  # connection created against an alias (rather than a resource ID) lands in
  # manualPrivateLinkServiceConnections, not privateLinkServiceConnections --
  # check both since which one populates isn't something callers control.
  connection_state="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" az network private-endpoint show \
    --ids "${endpoint_id}" \
    --query '[privateLinkServiceConnections[], manualPrivateLinkServiceConnections[]][] | [0].privateLinkServiceConnectionState.status' \
    --output tsv \
    --only-show-errors)"

  case "${connection_state}" in
    Approved)
      log "Connection state: Approved. The Private Link path is live."
      ;;
    Pending)
      warn "Connection state: Pending. Anyscale has not approved this connection yet -- traffic will NOT flow until they do. Ask your Anyscale contact to approve the private endpoint connection for ${endpoint_id}, then re-run this command."
      ;;
    Rejected|Disconnected|"")
      warn "Connection state: ${connection_state:-<empty>}. The Private Link path is not usable. Contact Anyscale about the connection for ${endpoint_id}."
      ;;
    *)
      warn "Connection state: ${connection_state} (unrecognized)."
      ;;
  esac

  if kubectl get nodes --request-timeout=15s >/dev/null 2>&1; then
    log "Resolving Private Link DNS records from inside the cluster"
    local namespace host
    namespace="$(validation_namespace)"
    prepare_validation_namespace
    host="$(printf '%s\n' "${record_fqdns}" | cut -d, -f1 | xargs)"
    kubectl delete job --namespace "${namespace}" anyscale-privatelink-dns --ignore-not-found >/dev/null 2>&1 || true
    kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-privatelink-dns
  namespace: ${namespace}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: privatelink-dns
        image: curlimages/curl:8.11.1
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -eu
          echo "== resolving ${host} (expect ${private_ip}) =="
          nslookup "${host}"
EOF
    wait_for_job "${namespace}" anyscale-privatelink-dns 5m || warn "DNS check job did not complete cleanly; inspect it with kubectl logs -n ${namespace} job/anyscale-privatelink-dns."
  else
    log "kubectl cannot reach the private API server from this shell, so the in-cluster DNS check was skipped. Run ./scripts/setup.sh verify --live or start a Bastion tunnel first, then re-run this command."
  fi
}

###############################################################################
# Run a noninteractive Bastion tunnel that agents and scripts can reuse without
# entering the interactive `az aks bastion` subshell wrapper.
###############################################################################
bastion_tunnel() {
  require_cmd az
  require_cmd lsof

  local action="${1:-start}"
  shift || true

  local pidfile portfile logfile pid port rg cluster bastion_rg bastion_name bastion_id cluster_id launcher_pid listener_pid
  pidfile="$(bastion_tunnel_pidfile)"
  portfile="$(bastion_tunnel_portfile)"
  logfile="$(bastion_tunnel_logfile)"
  port="${DEFAULT_BASTION_TUNNEL_PORT}"

  case "${action}" in
    start)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --port)
            [[ $# -ge 2 ]] || die "--port requires a value."
            port="$2"
            shift 2
            ;;
          --help|-h)
            cat <<'USAGE'
Usage:
  ./scripts/setup.sh bastion-tunnel start [--port 64430]
  ./scripts/setup.sh bastion-tunnel status
  ./scripts/setup.sh bastion-tunnel stop

Starts a reusable Azure Bastion tunnel to the private AKS API server using
`az network bastion tunnel`.
USAGE
            return 0
            ;;
          *)
            die "Unknown bastion-tunnel option: $1"
            ;;
        esac
      done

      pid="$(pid_from_file "${pidfile}")"
      if pid_is_running "${pid}"; then
        port="$(cat "${portfile}" 2>/dev/null || echo "${port}")"
        if ! listener_is_ready "${port}"; then
          warn "Recorded Bastion tunnel pid ${pid} is running but 127.0.0.1:${port} is not listening. Restarting it."
          kill "${pid}" 2>/dev/null || true
          clear_runtime_files "${pidfile}" "${portfile}"
        elif ! port_listeners_are_bastion_tunnels "${port}"; then
          die "Tracked Bastion tunnel port ${port} is in use by another process. Stop it or choose another port with --port."
        else
          listener_pid="$(first_listener_pid "${port}" 2>/dev/null || true)"
          if [[ -n "${listener_pid}" ]]; then
            printf '%s\n' "${listener_pid}" > "${pidfile}"
            pid="${listener_pid}"
          fi
          log "Bastion tunnel already running on 127.0.0.1:${port} (pid ${pid})"
          printf 'log file: %s\n' "${logfile}"
          return 0
        fi
      fi

      if listener_is_ready "${port}"; then
        if ! port_listeners_are_bastion_tunnels "${port}"; then
          die "Local port ${port} is already in use. Pick another port with --port."
        fi

        warn "Removing stale Bastion tunnel listener on 127.0.0.1:${port} before starting a fresh tunnel."
        stop_bastion_listeners_on_port "${port}" || true
        if listener_is_ready "${port}"; then
          die "Local port ${port} is already in use after removing stale Bastion listeners. Pick another port with --port."
        fi
      fi

      rg="$(resolve_aks_context resource_group_name)"
      cluster="$(resolve_aks_context aks_cluster_name)"
      bastion_name="$(resolve_aks_context bastion_name)"
      bastion_id="$(resolve_aks_context bastion_id)"
      bastion_rg="$(awk -F/ '{for (i=1; i<=NF; i++) if (tolower($i)=="resourcegroups") {print $(i+1); exit}}' <<<"${bastion_id}")"
      cluster_id="$(resolve_aks_cluster_id)"
      [[ -n "${rg}" && -n "${cluster}" && -n "${bastion_rg}" && -n "${bastion_name}" && -n "${cluster_id}" ]] || die "Missing Terraform outputs required for the Bastion tunnel."

      ensure_bastion_extensions
      : > "${logfile}"

      log "Starting Bastion tunnel to ${cluster} on 127.0.0.1:${port}"
      nohup az network bastion tunnel \
        --resource-group "${bastion_rg}" \
        --name "${bastion_name}" \
        --target-resource-id "${cluster_id}" \
        --resource-port 443 \
        --port "${port}" > "${logfile}" 2>&1 &
      launcher_pid="$!"

      printf '%s\n' "${port}" > "${portfile}"

      if ! wait_for_local_listener "${port}" 30; then
        kill "${launcher_pid}" 2>/dev/null || true
        stop_bastion_listeners_on_port "${port}" || true
        clear_runtime_files "${pidfile}" "${portfile}"
        tail -20 "${logfile}" >&2 || true
        die "Bastion tunnel did not open on port ${port}."
      fi

      listener_pid="$(first_listener_pid "${port}" 2>/dev/null || true)"
      [[ -n "${listener_pid}" ]] || die "Bastion tunnel opened on port ${port} but no listener PID was found."
      printf '%s\n' "${listener_pid}" > "${pidfile}"

      log "Bastion tunnel ready on 127.0.0.1:${port} (pid ${listener_pid})"
      printf 'export ANYSCALE_BASTION_PORT=%s\n' "${port}"
      printf 'log file: %s\n' "${logfile}"
      ;;
    status)
      pid="$(pid_from_file "${pidfile}")"
      port="$(cat "${portfile}" 2>/dev/null || true)"
      if [[ -n "${port}" ]] && listener_is_ready "${port}" && port_listeners_are_bastion_tunnels "${port}"; then
        pid="$(first_listener_pid "${port}" 2>/dev/null || true)"
        [[ -n "${pid}" ]] && printf '%s\n' "${pid}" > "${pidfile}"
        printf 'status=running\n'
        printf 'pid=%s\n' "${pid}"
        printf 'port=%s\n' "${port}"
        printf 'log=%s\n' "${logfile}"
        return 0
      fi

      clear_runtime_files "${pidfile}" "${portfile}"
      printf 'status=stopped\n'
      printf 'log=%s\n' "${logfile}"
      return 1
      ;;
    stop)
      local stopped=false
      pid="$(pid_from_file "${pidfile}")"
      port="$(cat "${portfile}" 2>/dev/null || true)"
      if pid_is_running "${pid}"; then
        kill "${pid}" 2>/dev/null || true
        stopped=true
      fi
      if [[ -n "${port}" ]] && stop_bastion_listeners_on_port "${port}"; then
        stopped=true
      fi
      if [[ "${stopped}" == true ]]; then
        log "Stopped Bastion tunnel${port:+ on 127.0.0.1:${port}}"
      else
        warn "No running Bastion tunnel found."
      fi
      clear_runtime_files \
        "${pidfile}" \
        "${portfile}" \
        "$(bastion_kubeconfig_path)" \
        "$(bastion_admin_kubeconfig_path)"
      ;;
    *)
      die "Usage: ./scripts/setup.sh bastion-tunnel {start|status|stop}"
      ;;
  esac
}

###############################################################################
# Fetch a dedicated kubeconfig that targets the local Bastion tunnel rather than
# the cluster private FQDN directly.
###############################################################################
kubeconfig_bastion() {
  require_cmd az
  require_cmd kubectl
  require_cmd kubelogin

  local admin=false print_path=false export_line=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --admin)
        admin=true
        shift
        ;;
      --print-path)
        print_path=true
        shift
        ;;
      --export)
        export_line=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh kubeconfig-bastion [--admin] [--print-path|--export]

Writes a kubeconfig file pointed at the local Bastion tunnel listener.
Run ./scripts/setup.sh bastion-tunnel start first.
USAGE
        return 0
        ;;
      *)
        die "Unknown kubeconfig-bastion option: $1"
        ;;
    esac
  done

  local pidfile portfile pid port rg cluster kubeconfig_file tmp_file original_server tls_server_name
  pidfile="$(bastion_tunnel_pidfile)"
  portfile="$(bastion_tunnel_portfile)"
  pid="$(pid_from_file "${pidfile}")"

  port="$(cat "${portfile}" 2>/dev/null || true)"
  pid_is_running "${pid}" || die "Bastion tunnel is not running. Start it with ./scripts/setup.sh bastion-tunnel start."
  [[ -n "${port}" ]] || die "Could not determine the Bastion tunnel port."
  listener_is_ready "${port}" || die "Bastion tunnel is not listening on 127.0.0.1:${port}. Restart it with ./scripts/setup.sh bastion-tunnel start."

  rg="$(resolve_aks_context resource_group_name)"
  cluster="$(resolve_aks_context aks_cluster_name)"
  [[ -n "${rg}" && -n "${cluster}" ]] || die "Terraform outputs are missing. Run ./scripts/setup.sh deploy first."

  if [[ "${admin}" == true ]]; then
    kubeconfig_file="$(bastion_admin_kubeconfig_path)"
  else
    kubeconfig_file="$(bastion_kubeconfig_path)"
  fi

  if [[ "${admin}" == true ]]; then
    az aks get-credentials \
      --resource-group "${rg}" \
      --name "${cluster}" \
      --file "${kubeconfig_file}" \
      --overwrite-existing \
      --admin \
      --only-show-errors >/dev/null
  else
    az aks get-credentials \
      --resource-group "${rg}" \
      --name "${cluster}" \
      --file "${kubeconfig_file}" \
      --overwrite-existing \
      --only-show-errors >/dev/null
  fi

  original_server="$(kubectl config view --kubeconfig "${kubeconfig_file}" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  tls_server_name="${original_server#https://}"
  tls_server_name="${tls_server_name%%/*}"
  tls_server_name="${tls_server_name%%:*}"

  tmp_file="${kubeconfig_file}.tmp"
  awk -v port="${port}" -v tls_server_name="${tls_server_name}" '
    /^    server: https:\/\// {
      print "    server: https://127.0.0.1:" port
      if (tls_server_name != "") {
        print "    tls-server-name: " tls_server_name
      }
      next
    }
    { print }
  ' "${kubeconfig_file}" > "${tmp_file}"
  mv "${tmp_file}" "${kubeconfig_file}"

  if [[ "${admin}" != true ]]; then
    KUBECONFIG="${kubeconfig_file}" kubelogin convert-kubeconfig -l azurecli >/dev/null
  fi

  kubectl_readyz "${kubeconfig_file}"

  if [[ "${print_path}" == true ]]; then
    printf '%s\n' "${kubeconfig_file}"
    return 0
  fi

  if [[ "${export_line}" == true ]]; then
    printf 'export KUBECONFIG=%q\n' "${kubeconfig_file}"
    printf 'export KUBE_CONFIG_PATH=%q\n' "${kubeconfig_file}"
    return 0
  fi

  log "Bastion kubeconfig ready at ${kubeconfig_file}"
  printf 'export KUBECONFIG=%q\n' "${kubeconfig_file}"
  printf 'export KUBE_CONFIG_PATH=%q\n' "${kubeconfig_file}"
  KUBECONFIG="${kubeconfig_file}" kubectl get nodes -o wide
}

###############################################################################
# Fetch Entra-backed kubeconfig and convert it for kubectl with kubelogin.
# For private clusters, run this from a shell with network path to the API server,
# or inside the shell opened by ./scripts/setup.sh bastion.
###############################################################################
kubeconfig() {
  require_cmd az
  require_cmd kubelogin
  require_cmd kubectl

  local rg cluster current_server
  rg="$(terraform output -raw resource_group_name)"
  cluster="$(terraform output -raw aks_cluster_name)"

  current_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  if [[ -n "${KUBECONFIG:-}" && "${current_server}" =~ ^https://(localhost|127\.0\.0\.1):[0-9]+/?$ ]]; then
    log "Using Bastion-provided kubeconfig at ${KUBECONFIG}"
  else
    log "Fetching Entra-backed kubeconfig for ${cluster}"
    az aks get-credentials --resource-group "${rg}" --name "${cluster}" --overwrite-existing --only-show-errors
  fi

  log "Converting kubeconfig for azurecli login with kubelogin"
  kubelogin convert-kubeconfig -l azurecli

  log "Checking kubectl access"
  kubectl get --raw=/readyz >/dev/null
  kubectl auth can-i get nodes >/dev/null
  kubectl get nodes -o wide
}

ensure_kubelogin_kubeconfig() {
  require_cmd kubectl
  require_cmd kubelogin
  use_bastion_kubeconfig_if_present
  kubelogin convert-kubeconfig -l azurecli >/dev/null 2>&1 || true
}

validation_namespace() {
  printf 'anyscale-validation\n'
}

job_progress_state_file() {
  local namespace="$1"
  local job_name="$2"

  harness_state_file "job-progress-${namespace}-${job_name}.state"
}

job_pod_name() {
  local namespace="$1"
  local job_name="$2"

  kubectl get pod --namespace "${namespace}" -l "job-name=${job_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

job_event_snapshot() {
  local namespace="$1"
  local pod_name="$2"

  [[ -n "${pod_name}" ]] || return 0

  kubectl get events \
    --namespace "${namespace}" \
    --field-selector "involvedObject.kind=Pod,involvedObject.name=${pod_name}" \
    --sort-by=.lastTimestamp \
    -o custom-columns='REASON:.reason,MESSAGE:.message' \
    --no-headers 2>/dev/null | tail -3 | sed '/^$/d' || true
}

print_job_progress() {
  local namespace="$1"
  local job_name="$2"
  local active succeeded failed pod_name pod_phase node_name state_file event_snapshot status_snapshot
  local scheduler_pending=false autoscaler_triggered=false

  active="$(kubectl get job --namespace "${namespace}" "${job_name}" -o jsonpath='{.status.active}' 2>/dev/null || true)"
  succeeded="$(kubectl get job --namespace "${namespace}" "${job_name}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  failed="$(kubectl get job --namespace "${namespace}" "${job_name}" -o jsonpath='{.status.failed}' 2>/dev/null || true)"

  pod_name="$(job_pod_name "${namespace}" "${job_name}")"
  pod_phase="-"
  node_name="-"

  if [[ -n "${pod_name}" ]]; then
    pod_phase="$(kubectl get pod --namespace "${namespace}" "${pod_name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    node_name="$(kubectl get pod --namespace "${namespace}" "${pod_name}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  fi

  event_snapshot="$(job_event_snapshot "${namespace}" "${pod_name}")"
  [[ "${event_snapshot}" == *"FailedScheduling"* && "${event_snapshot}" == *"Insufficient nvidia.com/gpu"* ]] && scheduler_pending=true
  [[ "${event_snapshot}" == *"TriggeredScaleUp"* ]] && autoscaler_triggered=true

  status_snapshot="${active:-0}|${succeeded:-0}|${failed:-0}|${pod_name:-none}|${pod_phase:-Unknown}|${node_name:-pending}|${event_snapshot}"
  state_file="$(job_progress_state_file "${namespace}" "${job_name}")"
  if [[ -f "${state_file}" ]] && [[ "$(cat "${state_file}")" == "${status_snapshot}" ]]; then
    return 0
  fi
  printf '%s\n' "${status_snapshot}" > "${state_file}"

  log "Waiting on job/${job_name}: active=${active:-0} succeeded=${succeeded:-0} failed=${failed:-0} pod=${pod_name:-none} phase=${pod_phase:-Unknown} node=${node_name:-pending}"

  if [[ -n "${pod_name}" && "${pod_phase}" != "Succeeded" ]]; then
    if [[ "${job_name}" == "anyscale-gpu-smoke" && "${scheduler_pending}" == true ]]; then
      warn "GPU pod is still pending because no node currently advertises free nvidia.com/gpu capacity. This is expected while the GPU pool scales from zero and the NVIDIA device plugin converges."
      if [[ "${autoscaler_triggered}" == true ]]; then
        warn "Cluster autoscaler has already requested the GPU pool scale-up. Waiting for the new GPU node to become Ready and report GPU allocatable capacity."
      fi
    elif [[ -n "${event_snapshot}" ]]; then
      printf '%s\n' "${event_snapshot}"
    fi
  fi
}

print_job_logs_or_status() {
  local namespace="$1"
  local job_name="$2"
  local pod_name exit_code reason

  if kubectl logs --namespace "${namespace}" "job/${job_name}"; then
    return 0
  fi

  pod_name="$(job_pod_name "${namespace}" "${job_name}")"
  if [[ -n "${pod_name}" ]]; then
    exit_code="$(kubectl get pod --namespace "${namespace}" "${pod_name}" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)"
    reason="$(kubectl get pod --namespace "${namespace}" "${pod_name}" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)"

    if [[ "${exit_code}" == "0" ]]; then
      warn "Could not stream logs for completed job/${job_name}; pod ${pod_name} exited 0 (${reason:-Completed})."
      kubectl get pod --namespace "${namespace}" "${pod_name}" -o wide || true
      return 0
    fi

    kubectl describe pod --namespace "${namespace}" "${pod_name}" || true
  fi

  return 1
}

wait_for_job() {
  local namespace="$1"
  local job_name="$2"
  local timeout="${3:-20m}"
  local wait_log wait_pid wait_status progress_state_file progress_pid

  wait_log="$(mktemp "${TMPDIR:-${ROOT_DIR}}/wait-for-job.${job_name}.XXXXXX")"
  progress_state_file="$(job_progress_state_file "${namespace}" "${job_name}")"
  rm -f "${progress_state_file}"
  kubectl wait --namespace "${namespace}" --for=condition=complete "job/${job_name}" --timeout="${timeout}" >"${wait_log}" 2>&1 &
  wait_pid="$!"

  (
    while kill -0 "${wait_pid}" 2>/dev/null; do
      print_job_progress "${namespace}" "${job_name}" || true
      sleep 15
    done
  ) &
  progress_pid="$!"

  if wait "${wait_pid}"; then
    wait_status=0
  else
    wait_status=$?
  fi

  kill "${progress_pid}" 2>/dev/null || true
  wait "${progress_pid}" 2>/dev/null || true

  cat "${wait_log}"
  rm -f "${wait_log}"
  rm -f "${progress_state_file}"

  if [[ "${wait_status}" -ne 0 ]]; then
    local pod_name
    pod_name="$(job_pod_name "${namespace}" "${job_name}")"
    kubectl describe job --namespace "${namespace}" "${job_name}" || true
    if [[ -n "${pod_name}" ]]; then
      kubectl describe pod --namespace "${namespace}" "${pod_name}" || true
    fi
    return "${wait_status}"
  fi

  print_job_logs_or_status "${namespace}" "${job_name}"
}

cleanup_validation() {
  local namespace
  namespace="$(validation_namespace)"
  kubectl delete namespace "${namespace}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

prepare_validation_namespace() {
  local namespace
  namespace="$(validation_namespace)"
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply --validate=false -f -
}

control_plane_egress_smoke() {
  require_cmd jq
  require_cluster_kubectl_access
  load_env

  local namespace hosts_json hosts_env
  local hosts=()
  namespace="$(validation_namespace)"
  prepare_validation_namespace

  hosts_json="${TF_VAR_anyscale_fqdns:-[]}"
  while IFS= read -r host; do
    [[ -n "${host}" ]] && hosts+=("${host}")
  done < <(jq -r '(. + ["console.anyscale.com", "console.azure.anyscale.com", "api.anyscale.com"]) | unique[]' <<<"${hosts_json}")

  hosts_env=""
  for host in "${hosts[@]}"; do
    hosts_env+="${host} "
  done
  hosts_env="${hosts_env% }"

  log "Validating cluster egress to Anyscale control-plane endpoints"
  kubectl delete job --namespace "${namespace}" anyscale-control-plane-egress --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-control-plane-egress
  namespace: ${namespace}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: control-plane-egress
        image: curlimages/curl:8.11.1
        env:
        - name: HOSTS
          value: "${hosts_env}"
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -eu
          for host in \${HOSTS}; do
            echo "== resolving \${host} =="
            nslookup "\${host}"
            echo "== probing https://\${host}/ =="
            code="\$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 20 --max-time 60 "https://\${host}/")"
            case "\${code}" in
              2*|3*|4*) echo "https://\${host}/ -> HTTP \${code}" ;;
              *) echo "Unexpected HTTP status \${code} for https://\${host}/" >&2; exit 1 ;;
            esac
          done
          echo CONTROL_PLANE_EGRESS_OK
EOF
  wait_for_job "${namespace}" anyscale-control-plane-egress 15m
}

validate_access() {
  log "Validating kubelogin-backed kubectl access"
  ensure_kubelogin_kubeconfig
  kubectl get --raw=/readyz >/dev/null
  kubectl auth can-i get nodes
  kubectl get nodes -o wide
}

validate_private_dns_and_egress() {
  require_cmd az

  local namespace storage_account acr_login_server aks_private_fqdn workspace_customer_id region
  namespace="$(validation_namespace)"
  storage_account="$(operator_storage_account_name)"
  acr_login_server="$(custom_image_acr_name).azurecr.io"
  aks_private_fqdn="$(az aks show \
    --resource-group "$(resource_group_name)" \
    --name "$(target_aks_cluster_name)" \
    --query 'privateFqdn' \
    --output tsv \
    --only-show-errors)"
  workspace_customer_id="$(az monitor log-analytics workspace show \
    --resource-group "$(resource_group_name)" \
    --workspace-name "log-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}" \
    --query 'customerId' \
    --output tsv \
    --only-show-errors)"
  region="${TF_VAR_azure_location}"

  [[ -n "${aks_private_fqdn}" ]] || die "Could not determine the AKS private FQDN via Azure CLI."
  [[ -n "${workspace_customer_id}" ]] || die "Could not determine the Log Analytics workspace customer id via Azure CLI."

  log "Validating DNS resolution for Private Link and Anyscale endpoints"
  kubectl delete job --namespace "${namespace}" anyscale-dns-egress --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-dns-egress
  namespace: ${namespace}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: dns-egress
        image: curlimages/curl:8.11.1
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -eu
          for host in \
            ${storage_account}.blob.core.windows.net \
            ${storage_account}.dfs.core.windows.net \
            ${acr_login_server} \
            arcmktplaceprod.azurecr.io \
            ${aks_private_fqdn} \
            global.handler.control.monitor.azure.com \
            ${region}.handler.control.monitor.azure.com \
            ${workspace_customer_id}.ods.opinsights.azure.com \
            ${workspace_customer_id}.oms.opinsights.azure.com \
            api.anyscale.com \
            console.azure.anyscale.com \
            console.anyscale.com; do
            echo "== resolving \${host} =="
            nslookup "\${host}"
          done
          for url in \
            https://${storage_account}.blob.core.windows.net/ \
            https://arcmktplaceprod.azurecr.io/v2/ \
            https://global.handler.control.monitor.azure.com/ \
            https://${workspace_customer_id}.ods.opinsights.azure.com/ \
            https://api.anyscale.com/ \
            https://console.azure.anyscale.com/ \
            https://console.anyscale.com/; do
            echo "== probing \${url} =="
            code="\$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 20 --max-time 60 "\${url}")"
            case "\${code}" in
              2*|3*|4*) echo "\${url} -> HTTP \${code}" ;;
              *) echo "Unexpected HTTP status \${code} for \${url}" >&2; exit 1 ;;
            esac
          done
EOF
  wait_for_job "${namespace}" anyscale-dns-egress 15m
}

validate_workload_identity_storage() {
  require_cmd az

  local namespace service_account storage_account container tenant_id client_id
  namespace="${TF_VAR_anyscale_operator_namespace}"
  service_account="${TF_VAR_anyscale_operator_serviceaccount}"
  storage_account="$(operator_storage_account_name)"
  container="${TF_VAR_project}-${TF_VAR_environment}-blob"
  tenant_id="${TF_VAR_azure_tenant_id}"
  client_id="$(az identity show \
    --resource-group "$(resource_group_name)" \
    --name "id-anyscale-operator-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}" \
    --query 'clientId' \
    --output tsv \
    --only-show-errors)"

  [[ -n "${container}" ]] || die "Could not determine the Anyscale storage container name from TF_VAR_project/TF_VAR_environment."
  [[ -n "${client_id}" ]] || die "Could not determine the Anyscale operator managed identity client id via Azure CLI."

  kubectl get namespace "${namespace}" >/dev/null
  kubectl get serviceaccount --namespace "${namespace}" "${service_account}" >/dev/null

  log "Validating Anyscale operator Workload Identity read/write access to Azure Storage"
  kubectl delete job --namespace "${namespace}" anyscale-wi-storage --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-wi-storage
  namespace: ${namespace}
  labels:
    azure.workload.identity/use: "true"
spec:
  backoffLimit: 1
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: ${service_account}
      restartPolicy: Never
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: storage-rw
        image: mcr.microsoft.com/azure-cli:2.74.0
        env:
        - name: AZURE_CLIENT_ID
          value: "${client_id}"
        - name: AZURE_TENANT_ID
          value: "${tenant_id}"
        - name: STORAGE_ACCOUNT
          value: "${storage_account}"
        - name: STORAGE_CONTAINER
          value: "${container}"
        command: ["/bin/bash", "-lc"]
        args:
        - |
          set -euo pipefail
          test -f "\${AZURE_FEDERATED_TOKEN_FILE}"
          az login --service-principal \
            --username "\${AZURE_CLIENT_ID}" \
            --tenant "\${AZURE_TENANT_ID}" \
            --federated-token "\$(cat "\${AZURE_FEDERATED_TOKEN_FILE}")" \
            --allow-no-subscriptions \
            --only-show-errors >/dev/null
          blob_name="workload-identity-smoke-\${HOSTNAME}.txt"
          echo "WORKLOAD_IDENTITY_STORAGE_OK" > /tmp/wi.txt
          az storage blob upload \
            --account-name "\${STORAGE_ACCOUNT}" \
            --container-name "\${STORAGE_CONTAINER}" \
            --name "\${blob_name}" \
            --file /tmp/wi.txt \
            --auth-mode login \
            --overwrite true \
            --only-show-errors >/dev/null
          az storage blob download \
            --account-name "\${STORAGE_ACCOUNT}" \
            --container-name "\${STORAGE_CONTAINER}" \
            --name "\${blob_name}" \
            --file /tmp/wi.out \
            --auth-mode login \
            --only-show-errors >/dev/null
          grep -q WORKLOAD_IDENTITY_STORAGE_OK /tmp/wi.out
          az storage blob delete \
            --account-name "\${STORAGE_ACCOUNT}" \
            --container-name "\${STORAGE_CONTAINER}" \
            --name "\${blob_name}" \
            --auth-mode login \
            --only-show-errors >/dev/null
          echo WORKLOAD_IDENTITY_STORAGE_OK
EOF
  wait_for_job "${namespace}" anyscale-wi-storage 20m
}

validate_submitter_storage_access() {
  require_cmd az
  require_cmd python3

  local storage_account container blob_host dfs_host probe_file blob_name resolved_ip
  storage_account="$(operator_storage_account_name)"
  container="${TF_VAR_project}-${TF_VAR_environment}-blob"
  [[ -n "${container}" ]] || die "Could not determine the Anyscale storage container name from TF_VAR_project/TF_VAR_environment."
  blob_host="${storage_account}.blob.core.windows.net"
  dfs_host="${storage_account}.dfs.core.windows.net"
  probe_file="$(mktemp "${TMPDIR:-/tmp}/anyscale-submit-storage.XXXXXX")"
  blob_name="submitter-storage-smoke-$(date -u +%Y%m%dT%H%M%SZ).txt"

  printf 'SUBMITTER_STORAGE_OK\n' > "${probe_file}"

  for host in "${blob_host}" "${dfs_host}"; do
    resolved_ip="$(python3 - "${host}" <<'PY'
import socket
import sys

infos = socket.getaddrinfo(sys.argv[1], 443, type=socket.SOCK_STREAM)
print(infos[0][4][0])
PY
)"
    [[ -n "${resolved_ip}" ]] || die "Could not resolve ${host} from the submitter machine. Private DNS must be available before local anyscale job submit uploads can work."
    is_private_ip "${resolved_ip}" || die "${host} resolved to ${resolved_ip}, which is not a private address. Run from an in-VNet jump host with private DNS before submitting local working directories."
    log "${host} resolves privately to ${resolved_ip}"
  done

  log "Validating submitter machine Blob write/read/delete access to ${storage_account}/${container}"
  az storage blob upload \
    --account-name "${storage_account}" \
    --container-name "${container}" \
    --name "${blob_name}" \
    --file "${probe_file}" \
    --auth-mode login \
    --overwrite true \
    --only-show-errors >/dev/null
  az storage blob download \
    --account-name "${storage_account}" \
    --container-name "${container}" \
    --name "${blob_name}" \
    --file "${probe_file}.out" \
    --auth-mode login \
    --only-show-errors >/dev/null
  grep -q SUBMITTER_STORAGE_OK "${probe_file}.out"
  az storage blob delete \
    --account-name "${storage_account}" \
    --container-name "${container}" \
    --name "${blob_name}" \
    --auth-mode login \
    --only-show-errors >/dev/null
  rm -f "${probe_file}" "${probe_file}.out"
  log "Submitter machine storage access is ready for local anyscale job submit uploads."
}

# Capability probe: does this machine resolve the operator storage account's
# Blob and DFS endpoints privately? Uses operator_storage_account_name(), which
# falls back to the TF_VAR_*-derived name when no local Terraform state exists,
# so this answers correctly on an in-VNet runner as well as the workstation.
submitter_storage_private_dns_ready() {
  local storage_account host
  storage_account="$(operator_storage_account_name)"
  [[ -n "${storage_account}" ]] || return 1

  for host in "${storage_account}.blob.core.windows.net" "${storage_account}.dfs.core.windows.net"; do
    host_resolves_privately "${host}" || return 1
  done
}

# Guard the local anyscale submit path. When ANYSCALE_CLI_TOKEN is unset the
# harness submits from this machine, which must reach the PRIVATE storage account
# to upload the working dir. Fail fast with actionable guidance instead of a raw
# Azure 403 mid-upload.
#
# Gated on the DNS probe alone, never on where the command appears to run: an
# in-VNet runner passes the probe on its own merits, and a machine that fails it
# would fail the upload no matter what it claimed about itself.
require_submitter_storage_for_local_submit() {
  local what="$1"
  local jump_host_repo_path="${ANYSCALE_AKS_REPO_PATH:-/opt/anyscale-aks-sample}"
  [[ -n "${ANYSCALE_CLI_TOKEN:-}" ]] && return 0
  submitter_storage_private_dns_ready && return 0
  die "Cannot submit ${what} from this machine: it does not resolve the private Storage Blob/DFS endpoints, so the working-directory upload to the private storage account fails with HTTP 403. Recommended path: connect to the in-VNet Linux jump host through Azure Bastion, run 'cd ${jump_host_repo_path} && ANYSCALE_HOST=$(default_anyscale_host) .venv/bin/anyscale login --no-browser', then re-run this proof from that same jump-host repo. Non-interactive/CI fallback only: set ANYSCALE_CLI_TOKEN in .env so the harness submits from inside the workspace pod."
}

# Upfront gate for the job/service proof pipeline. The build/train/serve stages
# submit Anyscale jobs and services, which upload the working directory to the
# PRIVATE storage account and therefore need an authenticated Anyscale CLI. Fail
# fast here with position-aware guidance instead of part way through the pipeline.
# The recommended path is the in-VNet jump host after `anyscale login`;
# ANYSCALE_CLI_TOKEN is the non-interactive/CI fallback only.
workload_pipeline_preflight() {
  local jump_host_repo_path="${ANYSCALE_AKS_REPO_PATH:-/opt/anyscale-aks-sample}"
  load_env
  sync_anyscale_cli_env
  require_anyscale_cli
  anyscale_cli_auth_available && return 0
  # Already in-VNet: the only thing missing is the login, so say so here rather
  # than sending the operator to a jump host they are plausibly already on.
  if submitter_storage_private_dns_ready; then
    die "Anyscale CLI is not logged in on this machine. It resolves the private storage endpoints, so the job/service proofs can submit from here once you log in: cd ${jump_host_repo_path} && ANYSCALE_HOST=$(default_anyscale_host) .venv/bin/anyscale login --no-browser, then re-run this proof."
  fi
  die "Anyscale CLI is not authenticated for the job/service proofs. Recommended manual path: connect to the in-VNet Linux jump host through Azure Bastion, run 'cd ${jump_host_repo_path} && ANYSCALE_HOST=$(default_anyscale_host) .venv/bin/anyscale login --no-browser', then run this proof from that same jump-host repo. Non-interactive/CI fallback only: set ANYSCALE_CLI_TOKEN in .env."
}

validate_gateway_tls_lifecycle() {
  local require_service_certificate="${1:-false}"
  local cloud_deployment_id normalized_cloud_deployment_id namespace primary_secret service_secret gateway_name start_epoch now_epoch gateway_json
  cloud_deployment_id="$(terraform output -raw anyscale_cloud_deployment_id 2>/dev/null || true)"
  if [[ -z "${cloud_deployment_id}" || "${cloud_deployment_id}" == "null" ]]; then
    cloud_deployment_id="${ANYSCALE_CLOUD_DEPLOYMENT_ID:-}"
  fi
  namespace="$(anyscale_gateway_namespace)"
  gateway_name="$(anyscale_gateway_name)"
  [[ -n "${cloud_deployment_id}" && "${cloud_deployment_id}" != "null" ]] || die "anyscale_cloud_deployment_id is not available. Deploy the Anyscale cloud before TLS lifecycle validation."
  normalized_cloud_deployment_id="${cloud_deployment_id//_/-}"
  primary_secret="anyscale-${normalized_cloud_deployment_id}-certificate"
  service_secret="anyscale-svc-${normalized_cloud_deployment_id}-certificate"

  log "Validating Anyscale TLS certificate lifecycle in ${namespace}"
  # The primary cert secret is provisioned lazily by the Anyscale control plane on first workspace activation; poll briefly then degrade to warn.
  local primary_wait_seconds="${ANYSCALE_PRIMARY_CERT_WAIT_SECONDS:-180}"
  start_epoch="$(date +%s)"
  while ! kubectl -n "${namespace}" get secret "${primary_secret}" >/dev/null 2>&1; do
    now_epoch="$(date +%s)"
    if (( now_epoch - start_epoch >= primary_wait_seconds )); then
      warn "Primary Anyscale certificate secret ${namespace}/${primary_secret} is not present after ${primary_wait_seconds}s. The Anyscale control plane provisions this lazily on first workspace activation; this is expected on a fresh deploy and is not a hard failure."
      kubectl -n "${namespace}" describe gateway "${gateway_name}" || true
      return 0
    fi
    log "Waiting for primary Anyscale certificate secret ${namespace}/${primary_secret}"
    sleep 15
  done
  log "Primary Anyscale certificate secret ${namespace}/${primary_secret} exists."

  if [[ "${require_service_certificate}" == "true" ]]; then
    gateway_json="$(kubectl -n "${namespace}" get gateway "${gateway_name}" -o json)"
    if ! jq -e --arg secret "${service_secret}" '
      any(.spec.listeners[]?; (.hostname // "") == "*.s.azure.anyscaleuserdata.com" or any(.tls.certificateRefs[]?; .name == $secret))
    ' <<<"${gateway_json}" >/dev/null; then
      warn "Gateway ${namespace}/${gateway_name} does not currently declare a service HTTPS listener for ${service_secret}; skipping service certificate wait and validating the deployed service endpoint instead."
      kubectl -n "${namespace}" describe gateway "${gateway_name}" || true
      return 0
    fi

    start_epoch="$(date +%s)"
    while ! kubectl -n "${namespace}" get secret "${service_secret}" >/dev/null 2>&1; do
      now_epoch="$(date +%s)"
      if (( now_epoch - start_epoch >= 600 )); then
        die "Service certificate secret ${namespace}/${service_secret} did not appear within 10m after service deployment."
      fi
      log "Waiting for service certificate secret ${namespace}/${service_secret}"
      sleep 20
    done
    log "Service certificate secret ${namespace}/${service_secret} exists."
  elif kubectl -n "${namespace}" get secret "${service_secret}" >/dev/null 2>&1; then
    log "Service certificate secret ${namespace}/${service_secret} exists."
  else
    warn "Service certificate secret ${namespace}/${service_secret} is not present yet. This is expected until an Anyscale service is deployed."
  fi

  kubectl -n "${namespace}" describe gateway "${gateway_name}" || true
}

validate_app_routing_gateway() {
  local namespace gateway_name gateway_class gateway_ip service_ip route_namespace echo_namespace
  namespace="$(validation_namespace)"
  gateway_name="$(anyscale_gateway_name)"
  gateway_class="$(anyscale_gateway_class_name)"
  route_namespace="$(anyscale_gateway_namespace)"
  echo_namespace="${route_namespace}"

  log "Validating AKS app-routing Istio Gateway API reachability"
  kubectl get gatewayclass "${gateway_class}" >/dev/null
  kubectl -n "${route_namespace}" get gateway "${gateway_name}" >/dev/null
  kubectl -n "${route_namespace}" wait --for=condition=Programmed "gateway.gateway.networking.k8s.io/${gateway_name}" --timeout=15m

  kubectl apply --validate=false -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: anyscale-echo
  namespace: ${echo_namespace}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: anyscale-echo
  template:
    metadata:
      labels:
        app: anyscale-echo
    spec:
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: echo
        image: registry.k8s.io/e2e-test-images/agnhost:2.45
        args: ["netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: anyscale-echo
  namespace: ${echo_namespace}
spec:
  selector:
    app: anyscale-echo
  ports:
  - name: http
    port: 80
    targetPort: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: anyscale-echo
  namespace: ${echo_namespace}
spec:
  parentRefs:
  - name: ${gateway_name}
    namespace: ${route_namespace}
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /echo
    backendRefs:
    - name: anyscale-echo
      port: 80
EOF

  kubectl rollout status --namespace "${echo_namespace}" deployment/anyscale-echo --timeout=10m
  wait_for_httproute_parent_accepted "${echo_namespace}" anyscale-echo "${route_namespace}" "${gateway_name}" 10m

  gateway_ip="$(kubectl -n "${route_namespace}" get gateway "${gateway_name}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  if [[ -z "${gateway_ip}" ]]; then
    service_ip="$(kubectl -n "${route_namespace}" get service "$(resolve_anyscale_gateway_service_name)" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    gateway_ip="${service_ip}"
  fi
  [[ -n "${gateway_ip}" ]] || die "Gateway ${route_namespace}/${gateway_name} has no assigned private address."
  is_private_ip "${gateway_ip}" || die "Gateway ${route_namespace}/${gateway_name} address ${gateway_ip} is not private."

  kubectl delete job --namespace "${namespace}" anyscale-gateway-probe --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-gateway-probe
  namespace: ${namespace}
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      tolerations:
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: curl
        image: curlimages/curl:8.11.1
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -eu
          curl -fsS --connect-timeout 20 --max-time 60 "http://${gateway_ip}/echo"
          echo GATEWAY_OK
EOF
  wait_for_job "${namespace}" anyscale-gateway-probe 10m
}

wait_for_httproute_parent_accepted() {
  require_cmd python3

  local namespace route_name parent_namespace parent_name timeout start_epoch now_epoch timeout_seconds route_json route_status
  namespace="$1"
  route_name="$2"
  parent_namespace="$3"
  parent_name="$4"
  timeout="${5:-10m}"
  case "${timeout}" in
    *m) timeout_seconds=$((${timeout%m} * 60)) ;;
    *s) timeout_seconds="${timeout%s}" ;;
    *) timeout_seconds="${timeout}" ;;
  esac
  start_epoch="$(date +%s)"

  while true; do
    route_json="$(kubectl -n "${namespace}" get httproute "${route_name}" -o json 2>/dev/null || true)"
    if route_status="$(ROUTE_JSON="${route_json}" python3 - "${parent_namespace}" "${parent_name}" <<'PY'
import json
import os
import sys

parent_namespace, parent_name = sys.argv[1:3]
route = json.loads(os.environ.get("ROUTE_JSON") or "{}")

messages = []
for parent in route.get("status", {}).get("parents", []):
    ref = parent.get("parentRef", {})
    ref_namespace = ref.get("namespace", parent_namespace)
    if ref.get("name") != parent_name or ref_namespace != parent_namespace:
        continue
    for condition in parent.get("conditions", []):
        if condition.get("type") != "Accepted":
            continue
        status = condition.get("status", "Unknown")
        reason = condition.get("reason", "Unknown")
        message = condition.get("message", "")
        if status == "True":
            print("Accepted=True")
            raise SystemExit(0)
        messages.append(f"Accepted={status} reason={reason} message={message}".strip())

print("; ".join(messages) if messages else "Accepted condition not reported yet")
raise SystemExit(1)
PY
)"; then
      log "HTTPRoute ${namespace}/${route_name} is accepted by Gateway ${parent_namespace}/${parent_name}."
      return 0
    fi

    now_epoch="$(date +%s)"
    if (( now_epoch - start_epoch >= timeout_seconds )); then
      kubectl -n "${namespace}" get httproute "${route_name}" -o yaml || true
      die "HTTPRoute ${namespace}/${route_name} was not accepted by Gateway ${parent_namespace}/${parent_name} within ${timeout}: ${route_status}"
    fi
    log "Waiting for HTTPRoute ${namespace}/${route_name} to be accepted by Gateway ${parent_namespace}/${parent_name}: ${route_status}"
    sleep 10
  done
}

validate_gpu() {
  local namespace gpu_workspace_worker
  namespace="$(validation_namespace)"

  # gpu_pools_enabled reads TF_VAR_gpu_pool_configs, so the environment has to be
  # loaded before it is asked. load_env is idempotent.
  load_env
  if ! gpu_pools_enabled; then
    log "Skipping GPU validation: $(gpu_disabled_notice)"
    return 0
  fi

  log "Validating GPU node pool, autoscale, NVIDIA plugin, and nvidia-smi"
  log "GPU validation can take several minutes when the T4 pool scales from zero. Progress snapshots will print while the job waits."
  kubectl get daemonset --namespace gpu-resources nvidia-device-plugin >/dev/null

  gpu_workspace_worker="$(kubectl get pods -n "${TF_VAR_anyscale_operator_namespace}" \
    -l 'app.kubernetes.io/name=aks-gpu-workspace,ray-node-type=worker' \
    --request-timeout=15s \
    -o json 2>/dev/null \
    | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(.status.phase == "Running") | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | select(.spec.nodeName | startswith("aks-gput4-"))] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty' || true)"
  if [[ -n "${gpu_workspace_worker}" ]]; then
    log "Using existing GPU workspace worker ${gpu_workspace_worker} for nvidia-smi validation."
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
      kubectl exec -n "${TF_VAR_anyscale_operator_namespace}" -c ray "${gpu_workspace_worker}" -- \
      bash -lc 'nvidia-smi && echo GPU_OK'
    return 0
  fi

  kubectl delete job --namespace "${namespace}" anyscale-gpu-smoke --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply --validate=false -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: anyscale-gpu-smoke
  namespace: ${namespace}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.azure.com/accelerator
                operator: Exists
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      - key: node.anyscale.com/accelerator-type
        operator: Exists
        effect: NoSchedule
      - key: node.anyscale.com/capacity-type
        operator: Exists
        effect: NoSchedule
      containers:
      - name: nvidia-smi
        image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
        command: ["/bin/bash", "-lc"]
        args: ["nvidia-smi && echo GPU_OK"]
        resources:
          limits:
            nvidia.com/gpu: 1
EOF
  wait_for_job "${namespace}" anyscale-gpu-smoke 45m
}

validate_anyscale_operator_patches() {
  local namespace patches_yaml

  load_env
  namespace="${TF_VAR_anyscale_operator_namespace}"

  require_cluster_kubectl_access

  log "Validating Anyscale operator GPU toleration patches"
  patches_yaml="$(kubectl get configmap patches -n "${namespace}" -o jsonpath='{.data.patches\.yaml}')"
  [[ -n "${patches_yaml}" ]] || die "Anyscale operator patches ConfigMap is empty in namespace ${namespace}."

  grep -q 'key: node.anyscale.com/accelerator-type' <<<"${patches_yaml}" || die "Anyscale operator patches ConfigMap is missing the accelerator-type GPU toleration."
  grep -q 'key: nvidia.com/gpu' <<<"${patches_yaml}" || die "Anyscale operator patches ConfigMap is missing the AKS nvidia.com/gpu toleration."

  log "Anyscale operator patches ConfigMap includes both GPU tolerations."
}

validate_k8s() {
  validate_access
  validate_anyscale_operator_patches
  prepare_validation_namespace
  validate_private_dns_and_egress
  validate_workload_identity_storage
  validate_submitter_storage_access
  validate_app_routing_gateway
  validate_gateway_tls_lifecycle
  validate_gpu
  log "Functional Kubernetes validation completed."
}

validate_observability() {
  require_cmd az
  require_cmd jq

  local workspace_customer_id container_query diagnostics_query container_json diagnostics_json container_rows diagnostics_rows diagnostic_settings_count
  workspace_customer_id="$(terraform output -raw log_analytics_workspace_customer_id 2>/dev/null || true)"
  if [[ -z "${workspace_customer_id}" ]]; then
    workspace_customer_id="$(az monitor log-analytics workspace show \
      --resource-group "$(resource_group_name)" \
      --workspace-name "log-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}" \
      --query 'customerId' \
      --output tsv \
      --only-show-errors)"
  fi
  [[ -n "${workspace_customer_id}" ]] || die "Could not determine the Log Analytics workspace customer id. Run ./scripts/setup.sh deploy first."

  container_query='ContainerLogV2 | where TimeGenerated > ago(2h) | summarize Records=count(), Namespaces=make_set(PodNamespace, 10), Sample=any(LogMessage)'
  diagnostics_query='union isfuzzy=true withsource=TableName AzureDiagnostics, AzureMetrics, StorageBlobLogs, ContainerRegistryLoginEvents, ContainerRegistryRepositoryEvents, MicrosoftAzureBastionAuditLogs | where TimeGenerated > ago(2h) | summarize Records=count() by TableName | order by Records desc'

  log "Querying ContainerLogV2 in Log Analytics"
  container_json="$(az monitor log-analytics query --workspace "${workspace_customer_id}" --analytics-query "${container_query}" --output json --only-show-errors)"
  jq . <<<"${container_json}"
  container_rows="$(jq -r 'def n: tonumber? // 0; if type == "array" then (.[0].Records? | n) else (.tables[0].rows[0][0] | n) end' <<<"${container_json}")"
  [[ "${container_rows}" =~ ^[0-9]+$ && "${container_rows}" -gt 0 ]] || die "ContainerLogV2 has no records yet. Run this again after Azure Monitor ingestion catches up."

  diagnostic_settings_count="$(terraform output -json private_mode_validation 2>/dev/null \
    | jq -r '[.. | objects | .diagnostic_settings_enabled? // empty | select(. == true)] | length' 2>/dev/null || true)"
  [[ "${diagnostic_settings_count}" =~ ^[0-9]+$ ]] || diagnostic_settings_count=0
  if [[ "${diagnostic_settings_count}" -gt 0 ]]; then
    log "Querying diagnostic tables in Log Analytics"
    diagnostics_json="$(az monitor log-analytics query --workspace "${workspace_customer_id}" --analytics-query "${diagnostics_query}" --output json --only-show-errors)"
    jq . <<<"${diagnostics_json}"
    diagnostics_rows="$(jq -r 'def n: tonumber? // 0; if type == "array" then ([.[].Records? | n] | add // 0) else ([.tables[0].rows[]?[1] | n] | add // 0) end' <<<"${diagnostics_json}")"
    [[ "${diagnostics_rows}" =~ ^[0-9]+$ && "${diagnostics_rows}" -gt 0 ]] || die "Diagnostic tables have no records yet. Generate traffic and run this again after ingestion catches up."
  else
    log "Terraform-managed diagnostic settings state is unavailable or disabled; skipping diagnostic table query."
  fi

  log "Observability validation completed."
}

validate_focused() {
  local include_observability=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-observability)
        include_observability=false
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh validate-focused
  ./scripts/setup.sh validate-focused --skip-observability

Runs the post-deploy live validation suite with PASS/FAIL output and per-check
logs under .cache/focused-validation/<timestamp>/.
USAGE
        return 0
        ;;
      *)
        die "Unknown validate-focused option: $1"
        ;;
    esac
  done

  reset_focused_validation_run
  log "Running focused live validation suite"

  local cluster_access_ready=false
  local validation_namespace_ready=false

  if run_focused_validation_check "kubectl-access" "kubelogin kubectl access" validate_access; then
    cluster_access_ready=true
  fi

  if [[ "${cluster_access_ready}" == true ]]; then
    run_focused_validation_check "anyscale-operator-patches" "Anyscale operator GPU toleration patches" validate_anyscale_operator_patches || true
    if run_focused_validation_check "validation-namespace" "validation namespace preparation" prepare_validation_namespace; then
      validation_namespace_ready=true
    fi
  else
    skip_focused_validation_check "anyscale-operator-patches" "Anyscale operator GPU toleration patches" "skipped because kubectl access failed"
    skip_focused_validation_check "validation-namespace" "validation namespace preparation" "skipped because kubectl access failed"
  fi

  if [[ "${validation_namespace_ready}" == true ]]; then
    run_focused_validation_check "private-dns-egress" "private DNS and control-plane egress" validate_private_dns_and_egress || true
    run_focused_validation_check "workload-identity-storage" "workload identity storage access" validate_workload_identity_storage || true
    if submitter_storage_private_dns_ready; then
      run_focused_validation_check "submitter-storage" "submitter private storage access" validate_submitter_storage_access || true
    else
      skip_focused_validation_check "submitter-storage" "submitter private storage access" "skipped because this submitter is not resolving Storage Blob/DFS endpoints through private DNS; run from an in-VNet jump host with private DNS before local working-directory uploads"
    fi
    run_focused_validation_check "app-routing-gateway" "app-routing Gateway private reachability" validate_app_routing_gateway || true
    run_focused_validation_check "gateway-tls-lifecycle" "Anyscale Gateway TLS lifecycle" validate_gateway_tls_lifecycle || true
    run_focused_validation_check "gpu-smoke" "GPU scheduling and nvidia-smi" validate_gpu || true
  else
    skip_focused_validation_check "private-dns-egress" "private DNS and control-plane egress" "skipped because validation namespace setup failed"
    skip_focused_validation_check "workload-identity-storage" "workload identity storage access" "skipped because validation namespace setup failed"
    skip_focused_validation_check "submitter-storage" "submitter private storage access" "skipped because validation namespace setup failed"
    skip_focused_validation_check "app-routing-gateway" "app-routing Gateway private reachability" "skipped because validation namespace setup failed"
    skip_focused_validation_check "gateway-tls-lifecycle" "Anyscale Gateway TLS lifecycle" "skipped because validation namespace setup failed"
    skip_focused_validation_check "gpu-smoke" "GPU scheduling and nvidia-smi" "skipped because validation namespace setup failed"
  fi

  if [[ "${include_observability}" == true ]]; then
    run_focused_validation_check "observability" "Log Analytics and diagnostics ingestion" validate_observability || true
  else
    skip_focused_validation_check "observability" "Log Analytics and diagnostics ingestion" "skipped by --skip-observability"
  fi

  write_focused_validation_summary
  [[ "${FOCUSED_VALIDATION_FAIL_COUNT}" -eq 0 ]]
}

###############################################################################
write_anyscale_compute_config_file() {
  local file_path="$1"
  local profile="${2:-mixed}"

  case "${profile}" in
    mixed)
      cat > "${file_path}" <<EOF
cloud: ${ANYSCALE_CLOUD_NAME}
head_node:
  required_resources:
    CPU: 4
    memory: 16Gi
  advanced_instance_config:
    spec:
      nodeSelector:
        agentpool: cpu
worker_nodes:
  - name: cpu-workers
    required_resources:
      CPU: 4
      memory: 16Gi
    min_nodes: 1
    max_nodes: 4
    advanced_instance_config:
      spec:
        nodeSelector:
          agentpool: cpu
  - name: gpu-workers
    required_resources:
      CPU: 4
      GPU: 1
      memory: 16Gi
    required_labels:
      ray.io/accelerator-type: T4
    min_nodes: 1
    max_nodes: 2
    advanced_instance_config:
      spec:
        nodeSelector:
          agentpool: gput4
        tolerations:
          - key: nvidia.com/gpu
            operator: Exists
            effect: NoSchedule
          - key: node.anyscale.com/accelerator-type
            operator: Exists
            effect: NoSchedule
          - key: node.anyscale.com/capacity-type
            operator: Exists
            effect: NoSchedule
EOF
      ;;
    cpu)
      cat > "${file_path}" <<EOF
cloud: ${ANYSCALE_CLOUD_NAME}
head_node:
  required_resources:
    CPU: 4
    memory: 16Gi
  advanced_instance_config:
    spec:
      nodeSelector:
        agentpool: cpu
worker_nodes:
  - name: cpu-workers
    required_resources:
      CPU: 4
      memory: 16Gi
    min_nodes: 1
    max_nodes: 1
    advanced_instance_config:
      spec:
        nodeSelector:
          agentpool: cpu
EOF
      ;;
    gpu)
      cat > "${file_path}" <<EOF
cloud: ${ANYSCALE_CLOUD_NAME}
head_node:
  required_resources:
    CPU: 4
    memory: 16Gi
  advanced_instance_config:
    spec:
      nodeSelector:
        agentpool: cpu
worker_nodes:
  - name: gpu-workers
    required_resources:
      CPU: 4
      GPU: 1
      memory: 16Gi
    required_labels:
      ray.io/accelerator-type: T4
    min_nodes: 1
    max_nodes: 1
    advanced_instance_config:
      spec:
        nodeSelector:
          agentpool: gput4
        tolerations:
          - key: nvidia.com/gpu
            operator: Exists
            effect: NoSchedule
          - key: node.anyscale.com/accelerator-type
            operator: Exists
            effect: NoSchedule
          - key: node.anyscale.com/capacity-type
            operator: Exists
            effect: NoSchedule
EOF
      ;;
    *)
      die "Unknown Anyscale compute config profile ${profile}"
      ;;
  esac
}

anyscale_compute_config_worker_min_nodes_signature_from_file() {
  local file_path="$1"

  awk '
    $1 == "-" && $2 == "name:" { name = $3; next }
    $1 == "name:" { name = $2; next }
    $1 == "min_nodes:" && name != "" { print name "=" $2; name = "" }
  ' "${file_path}" | sort
}

anyscale_compute_config_worker_min_nodes_signature_from_output() {
  local raw_output="$1"

  printf '%s\n' "${raw_output}" | awk '
    /^config:/ { in_config = 1; next }
    !in_config { next }
    $1 == "-" && $2 == "name:" { name = $3; next }
    $1 == "name:" { name = $2; next }
    $1 == "min_nodes:" && name != "" { print name "=" $2; name = "" }
  ' | sort
}

anyscale_compute_config_output_matches_profile() {
  local raw_output="$1"
  local profile="$2"

  grep -q 'CPU: 4' <<<"${raw_output}" || return 1
  grep -q 'memory: 16Gi' <<<"${raw_output}" || return 1
  ! grep -Eq 'CPU: 8|memory: 32Gi' <<<"${raw_output}" || return 1

  case "${profile}" in
    mixed)
      grep -q 'GPU: 1' <<<"${raw_output}" || return 1
      grep -q 'node.anyscale.com/capacity-type' <<<"${raw_output}" || return 1
      ;;
    gpu)
      grep -q 'GPU: 1' <<<"${raw_output}" || return 1
      grep -q 'node.anyscale.com/capacity-type' <<<"${raw_output}" || return 1
      ;;
    cpu)
      ! grep -q 'GPU: 1' <<<"${raw_output}" || return 1
      ;;
  esac
}

ensure_anyscale_compute_config() {
  local compute_config_name="$1"
  local cli_bin="$2"
  local config_file="$3"
  local profile="${4:-mixed}"
  local get_output
  local desired_worker_min_nodes current_worker_min_nodes

  write_anyscale_compute_config_file "${config_file}" "${profile}"

  if get_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" compute-config get \
      --name "${compute_config_name}" \
      --cloud-name "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
    desired_worker_min_nodes="$(anyscale_compute_config_worker_min_nodes_signature_from_file "${config_file}")"
    current_worker_min_nodes="$(anyscale_compute_config_worker_min_nodes_signature_from_output "${get_output}")"
    if grep -q 'required_resources' <<<"${get_output}" \
      && ! grep -Eq 'instance_type:|14CPU-56GB-CPU|8CPU-32GB-1xT4-AKS' <<<"${get_output}" \
      && [[ "${current_worker_min_nodes}" == "${desired_worker_min_nodes}" ]] \
      && anyscale_compute_config_output_matches_profile "${get_output}" "${profile}"; then
      log "Using existing Anyscale declarative compute config ${compute_config_name}"
      return 0
    fi
    log "Refreshing Anyscale compute config ${compute_config_name} to declarative profile ${profile}"
  else
    log "Creating Anyscale declarative compute config ${compute_config_name} (profile ${profile})"
  fi

  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" compute-config create \
      --name "${compute_config_name}" \
      --config-file "${config_file}" >/dev/null
}

anyscale_compute_config_version_name() {
  local compute_config_name="$1"
  local cli_bin="$2"
  local get_output

  get_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" compute-config get \
      --name "${compute_config_name}" \
      --cloud-name "${ANYSCALE_CLOUD_NAME}" 2>&1)"

  awk -F': ' '/^name:/ {print $2; exit}' <<<"${get_output}"
}

resolve_ipv4_addresses() {
  local host="$1"

  python3 - "$host" <<'PY'
import socket
import sys

host = sys.argv[1]
ips = sorted(
    {
        result[4][0]
        for result in socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
    }
)
for ip in ips:
    print(ip)
PY
}

probe_tls_server_name() {
  local server_name="$1"
  local ip_address="$2"

  python3 - "$server_name" "$ip_address" <<'PY'
import socket
import ssl
import sys

server_name, ip_address = sys.argv[1], sys.argv[2]
context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_REQUIRED

with socket.create_connection((ip_address, 443), timeout=10) as raw_socket:
    with context.wrap_socket(raw_socket, server_hostname=server_name) as tls_socket:
        certificate = tls_socket.getpeercert()

dns_names = [value for key, value in certificate.get("subjectAltName", ()) if key == "DNS"]
if not dns_names:
    for rdn in certificate.get("subject", ()):
        for key, value in rdn:
            if key == "commonName":
                dns_names.append(value)

print(",".join(dns_names))

# ssl.match_hostname was removed in Python 3.12 (Ubuntu 24.04 default); use
# an inline RFC 6125 s6.4.3 wildcard check that works on all supported versions.
def _match_hostname(hostname: str, pattern: str) -> bool:
    if pattern.startswith("*."):
        _, _, suffix = pattern.partition(".")
        label, dot, rest = hostname.partition(".")
        return bool(dot) and rest.lower() == suffix.lower() and "." not in label
    return hostname.lower() == pattern.lower()

if not any(_match_hostname(server_name, pat) for pat in dns_names):
    print(f"hostname {server_name!r} doesn't match SANs: {dns_names}", file=sys.stderr)
    raise SystemExit(1)
PY
}

get_anyscale_cloud_metadata() {
  local cli_bin="$1"
  local attempts="${ANYSCALE_CLOUD_METADATA_RETRY_ATTEMPTS:-20}"
  local delay_seconds="${ANYSCALE_CLOUD_METADATA_RETRY_SECONDS:-15}"
  local attempt cloud_output list_output list_cloud_id

  require_positive_integer_arg "ANYSCALE_CLOUD_METADATA_RETRY_ATTEMPTS" "${attempts}"
  require_positive_integer_arg "ANYSCALE_CLOUD_METADATA_RETRY_SECONDS" "${delay_seconds}"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if cloud_output="$(ANYSCALE_HOST="${ANYSCALE_HOST:-$(default_anyscale_host)}" \
      run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
        "${cli_bin}" cloud get \
          --name "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      printf '%s\n' "${cloud_output}"
      return 0
    fi

    if list_output="$(ANYSCALE_HOST="${ANYSCALE_HOST:-$(default_anyscale_host)}" \
      run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
        "${cli_bin}" cloud list \
          --name "${ANYSCALE_CLOUD_NAME}" \
          --max-items 1 \
          --page-size 1 \
          --no-interactive \
          --json 2>&1)" \
      && list_cloud_id="$(jq -r '.[0].id // empty' <<<"${list_output}" 2>/dev/null)" \
      && [[ -n "${list_cloud_id}" ]]; then
      printf 'id: %s\n' "${list_cloud_id}"
      return 0
    fi

    if ((attempt < attempts)); then
      warn "Anyscale cloud metadata for ${ANYSCALE_CLOUD_NAME} is not available yet (${attempt}/${attempts}); retrying in ${delay_seconds}s." >&2
      sleep "${delay_seconds}"
    fi
  done

  [[ -n "${list_output:-}" ]] && cloud_output+=$'\n'"${list_output}"
  printf '%s\n' "${cloud_output}"
  return 1
}

ensure_anyscale_azure_cloud_dns_alias() {
  local cli_bin="$1"
  local cloud_output cloud_id host_label generic_host azure_host endpoint_source_host
  local coredns_block patch_payload certificate_names=""
  local operator_pod=""
  local tls_verified_ip=""
  local -a azure_host_ips=()
  local -a resolved_ips=()

  cloud_output="$(get_anyscale_cloud_metadata "${cli_bin}")" || die "Unable to inspect Anyscale cloud metadata for DNS aliasing. Last Anyscale CLI output: ${cloud_output}"
  cloud_id="$(awk -F': ' '/^id:/ {print $2; exit}' <<<"${cloud_output}")"
  [[ -n "${cloud_id}" ]] || die "Anyscale cloud metadata did not include a cloud id for DNS aliasing."

  host_label="${cloud_id//_/-}"
  generic_host="${host_label}.anyscale-cloud.dev"
  azure_host="${host_label}.azure.anyscale-cloud.dev"

  while IFS= read -r ip; do
    [[ -n "${ip}" ]] && azure_host_ips+=("${ip}")
  done < <(resolve_ipv4_addresses "${azure_host}" 2>/dev/null || true)

  if ((${#azure_host_ips[@]} > 0)); then
    endpoint_source_host="${azure_host}"
    resolved_ips=("${azure_host_ips[@]}")
  else
    endpoint_source_host="${generic_host}"
    while IFS= read -r ip; do
      [[ -n "${ip}" ]] && resolved_ips+=("${ip}")
    done < <(resolve_ipv4_addresses "${generic_host}")
  fi

  ((${#resolved_ips[@]} > 0)) || die "Unable to resolve ${endpoint_source_host}; cannot validate the Azure-specific Anyscale cloud endpoint."

  for ip in "${resolved_ips[@]}"; do
    if certificate_names="$(probe_tls_server_name "${azure_host}" "${ip}" 2>/dev/null)"; then
      tls_verified_ip="${ip}"
      break
    fi
  done

  if [[ -z "${tls_verified_ip}" ]]; then
    die "Anyscale cloud endpoint ${azure_host} is not usable: ${endpoint_source_host} resolves to ${resolved_ips[*]}, but the presented certificate names (${certificate_names:-unknown}) do not match ${azure_host}. CoreDNS aliasing would still fail TLS hostname verification; this must be fixed by Anyscale's Azure endpoint/certificate provisioning."
  fi

  operator_pod="$(kubectl get pods -n anyscale-operator -l app=anyscale-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${operator_pod}" ]] && kubectl exec -n anyscale-operator "${operator_pod}" -c operator -- sh -c "getent hosts ${azure_host} >/dev/null" >/dev/null 2>&1; then
    log "Anyscale cloud endpoint ${azure_host} already resolves in-cluster and presents a matching certificate."
    return 0
  fi

  coredns_block="$(
    printf 'azure.anyscale-cloud.dev:53 {\n'
    printf '    errors\n'
    printf '    cache 30\n'
    printf '    hosts {\n'
    for ip in "${resolved_ips[@]}"; do
      printf '        %s %s\n' "${ip}" "${azure_host}"
    done
    printf '        fallthrough\n'
    printf '    }\n'
    printf '    forward . /etc/resolv.conf\n'
    printf '}\n'
  )"

  if kubectl get configmap coredns-custom -n kube-system >/dev/null 2>&1; then
    patch_payload="$(jq -n --arg block "${coredns_block}" '{data: {"anyscale-azure-cloud.server": $block}}')"
    kubectl patch configmap coredns-custom -n kube-system --type merge -p "${patch_payload}" >/dev/null
  else
    {
      printf 'apiVersion: v1\n'
      printf 'kind: ConfigMap\n'
      printf 'metadata:\n'
      printf '  name: coredns-custom\n'
      printf '  namespace: kube-system\n'
      printf 'data:\n'
      printf '  anyscale-azure-cloud.server: |\n'
      sed 's/^/    /' <<<"${coredns_block}"
    } | kubectl apply -f - >/dev/null
  fi

  kubectl rollout restart deployment coredns -n kube-system >/dev/null
  kubectl rollout status deployment coredns -n kube-system --timeout=300s >/dev/null

  if [[ -n "${operator_pod}" ]]; then
    kubectl exec -n anyscale-operator "${operator_pod}" -c operator -- sh -c "getent hosts ${azure_host} >/dev/null" >/dev/null 2>&1 || true
  fi

  log "Installed CoreDNS alias ${azure_host} -> ${endpoint_source_host} (${resolved_ips[*]}), validated via ${tls_verified_ip}."
}

write_anyscale_workspace_update_file() {
  local workspace_json="$1"
  local file_path="$2"
  local compute_config_name="$3"
  local workspace_name image_uri idle_termination_minutes

  workspace_name="$(jq -r '.name // empty' <<<"${workspace_json}")"
  image_uri="$(jq -r '.config.image_uri // empty' <<<"${workspace_json}")"
  idle_termination_minutes="$(jq -r '.config.idle_termination_minutes // -1' <<<"${workspace_json}")"

  [[ -n "${workspace_name}" ]] || die "Cannot build Anyscale workspace update file without a workspace name."
  [[ -n "${image_uri}" ]] || die "Workspace ${workspace_name} does not expose config.image_uri; cannot build a safe update file."

  {
    printf 'name: %s\n' "${workspace_name}"
    printf 'image_uri: %s\n' "${image_uri}"
    printf 'compute_config: %s\n' "${compute_config_name}"
    printf 'idle_termination_minutes: %s\n' "${idle_termination_minutes}"
    if jq -e '.config.env_vars | type == "object" and length > 0' <<<"${workspace_json}" >/dev/null 2>&1; then
      printf 'env_vars:\n'
      jq -r '.config.env_vars | to_entries[] | "  \(.key): " + (.value | @json)' <<<"${workspace_json}"
    else
      printf 'env_vars: {}\n'
    fi
  } > "${file_path}"
}

normalize_anyscale_workspace_status() {
  local raw_status="$1"

  printf '%s\n' "${raw_status}" \
    | tail -n 1 \
    | sed -E 's/'$'\033''\[[0-9;]*[A-Za-z]//g' \
    | sed -E 's/^.*\)[[:space:]]*//' \
    | tr -d '\r' \
    | awk '{$1=$1; print}'
}

require_positive_integer_arg() {
  local name="$1"
  local value="$2"

  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || die "${name} must be a positive integer."
}

workspace_wait_sleep_seconds() {
  local attempt="$1"

  if (( attempt <= 6 )); then
    printf '5\n'
  elif (( attempt <= 12 )); then
    printf '10\n'
  else
    printf '15\n'
  fi
}

wait_for_anyscale_workspace_running() {
  local workspace_name="$1"
  local cli_bin="$2"
  local wait_log="$3"
  local deadline current_epoch raw_status current_status previous_status="" attempt=1 sleep_seconds

  ANYSCALE_WORKSPACE_WAIT_RESULT=""
  : > "${wait_log}"
  deadline=$(( $(date +%s) + SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS ))
  local terminal_status_streak=""

  while true; do
    if ! raw_status="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 status \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      printf '%s\n' "${raw_status}" | tee -a "${wait_log}"
      return 1
    fi

    current_status="$(normalize_anyscale_workspace_status "${raw_status}")"
    printf '%s\n' "${raw_status}" >> "${wait_log}"

    if [[ -z "${current_status}" ]]; then
      current_status="UNKNOWN"
    fi

    if [[ "${current_status}" != "${previous_status}" ]]; then
      log "Workspace ${workspace_name} status: ${current_status}"
      previous_status="${current_status}"
    fi

    case "${current_status}" in
      RUNNING)
        ANYSCALE_WORKSPACE_WAIT_RESULT="${current_status}"
        return 0
        ;;
      TERMINATED|TERMINATING|CREATE_FAILED|FAILED|ERROR)
        # A freshly-created workspace can transiently report TERMINATED/ERROR for one poll
        # before its controller actually starts provisioning. Only treat this as fatal once
        # the same terminal status is confirmed on a second consecutive poll.
        if [[ "${terminal_status_streak}" == "${current_status}" ]]; then
          ANYSCALE_WORKSPACE_WAIT_RESULT="${current_status}"
          return 1
        fi
        terminal_status_streak="${current_status}"
        warn "Workspace ${workspace_name} reported ${current_status}; re-checking once before treating it as fatal (can be transient right after creation)."
        current_epoch=$(date +%s)
        if (( current_epoch >= deadline )); then
          ANYSCALE_WORKSPACE_WAIT_RESULT="Timed out waiting for RUNNING; last observed state=${current_status}"
          return 1
        fi
        sleep "$(workspace_wait_sleep_seconds "${attempt}")"
        attempt=$((attempt + 1))
        continue
        ;;
      *)
        terminal_status_streak=""
        ;;
    esac

    if anyscale_workspace_runtime_ready_on_cluster "${workspace_name}"; then
      warn "Workspace ${workspace_name} is still reported as ${current_status} by the Anyscale API, but the Ray head pod is Ready and serving on the cluster. Proceeding with Kubernetes-backed readiness confirmation."
      ANYSCALE_WORKSPACE_WAIT_RESULT="RUNNING (confirmed via Kubernetes head-pod readiness while Anyscale API reported ${current_status})"
      return 0
    fi

    current_epoch=$(date +%s)
    if (( current_epoch >= deadline )); then
      ANYSCALE_WORKSPACE_WAIT_RESULT="Timed out waiting for RUNNING; last observed state=${current_status}"
      return 1
    fi

    sleep_seconds="$(workspace_wait_sleep_seconds "${attempt}")"
    sleep "${sleep_seconds}"
    attempt=$((attempt + 1))
  done
}

wait_for_anyscale_workspace_running_attempts() {
  local workspace_name="$1"
  local cli_bin="$2"
  local wait_log="$3"
  local max_attempts="$4"
  local interval_seconds="$5"
  local attempt raw_status current_status previous_status=""
  local terminal_status_streak=""

  require_positive_integer_arg "--max-attempts" "${max_attempts}"
  require_positive_integer_arg "--interval-seconds" "${interval_seconds}"

  ANYSCALE_WORKSPACE_WAIT_RESULT=""
  : > "${wait_log}"

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ! raw_status="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 status \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      printf 'attempt=%s/%s\n' "${attempt}" "${max_attempts}" >> "${wait_log}"
      printf '%s\n' "${raw_status}" | tee -a "${wait_log}"
      return 1
    fi

    current_status="$(normalize_anyscale_workspace_status "${raw_status}")"
    printf 'attempt=%s/%s\n' "${attempt}" "${max_attempts}" >> "${wait_log}"
    printf '%s\n' "${raw_status}" >> "${wait_log}"

    if [[ -z "${current_status}" ]]; then
      current_status="UNKNOWN"
    fi

    if [[ "${current_status}" != "${previous_status}" ]]; then
      log "Workspace ${workspace_name} status (${attempt}/${max_attempts}): ${current_status}"
      previous_status="${current_status}"
    fi

    case "${current_status}" in
      RUNNING)
        ANYSCALE_WORKSPACE_WAIT_RESULT="${current_status}"
        return 0
        ;;
      TERMINATED|TERMINATING|CREATE_FAILED|FAILED|ERROR)
        # See wait_for_anyscale_workspace_running: a freshly-created workspace can
        # transiently report a terminal-looking status for one poll before its
        # controller starts provisioning. Confirm on a second consecutive poll.
        if [[ "${terminal_status_streak}" == "${current_status}" ]]; then
          ANYSCALE_WORKSPACE_WAIT_RESULT="${current_status}"
          return 1
        fi
        terminal_status_streak="${current_status}"
        warn "Workspace ${workspace_name} reported ${current_status}; re-checking once before treating it as fatal (can be transient right after creation)."
        if (( attempt < max_attempts )); then
          sleep "${interval_seconds}"
        fi
        continue
        ;;
      *)
        terminal_status_streak=""
        ;;
    esac

    if anyscale_workspace_runtime_ready_on_cluster "${workspace_name}"; then
      warn "Workspace ${workspace_name} is still reported as ${current_status} by the Anyscale API, but the Ray head pod is Ready and serving on the cluster. Proceeding with Kubernetes-backed readiness confirmation."
      ANYSCALE_WORKSPACE_WAIT_RESULT="RUNNING (confirmed via Kubernetes head-pod readiness while Anyscale API reported ${current_status})"
      return 0
    fi

    if (( attempt < max_attempts )); then
      sleep "${interval_seconds}"
    fi
  done

  ANYSCALE_WORKSPACE_WAIT_RESULT="Timed out waiting for RUNNING after ${max_attempts} attempts; last observed state=${current_status}"
  return 1
}

anyscale_workspace_runtime_ready_on_cluster() {
  local workspace_name="$1"
  local namespace head_pod_name pod_phase pod_ready

  namespace="${TF_VAR_anyscale_operator_namespace}"
  head_pod_name="$(kubectl get pods -n "${namespace}" \
    -l "app.kubernetes.io/name=${workspace_name},ray-node-type=head" \
    --request-timeout=15s \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  [[ -n "${head_pod_name}" ]] || return 1

  pod_phase="$(kubectl get pod -n "${namespace}" "${head_pod_name}" \
    --request-timeout=15s \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  pod_ready="$(kubectl get pod -n "${namespace}" "${head_pod_name}" \
    --request-timeout=15s \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"

  [[ "${pod_phase}" == "Running" && "${pod_ready}" == "True" ]] || return 1

  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod_name}" -- \
    bash -lc 'ray status >/dev/null 2>&1'
}

wait_for_anyscale_workspace_terminated_attempts() {
  local workspace_name="$1"
  local cli_bin="$2"
  local wait_log="$3"
  local max_attempts="$4"
  local interval_seconds="$5"
  local attempt raw_status current_status previous_status=""

  require_positive_integer_arg "--max-attempts" "${max_attempts}"
  require_positive_integer_arg "--interval-seconds" "${interval_seconds}"

  ANYSCALE_WORKSPACE_WAIT_RESULT=""
  : > "${wait_log}"

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ! raw_status="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 status \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      printf 'attempt=%s/%s\n' "${attempt}" "${max_attempts}" >> "${wait_log}"
      printf '%s\n' "${raw_status}" | tee -a "${wait_log}"
      return 1
    fi

    current_status="$(normalize_anyscale_workspace_status "${raw_status}")"
    printf 'attempt=%s/%s\n' "${attempt}" "${max_attempts}" >> "${wait_log}"
    printf '%s\n' "${raw_status}" >> "${wait_log}"

    if [[ -z "${current_status}" ]]; then
      current_status="UNKNOWN"
    fi

    if [[ "${current_status}" != "${previous_status}" ]]; then
      log "Workspace ${workspace_name} status (${attempt}/${max_attempts}): ${current_status}"
      previous_status="${current_status}"
    fi

    if [[ "${current_status}" == "TERMINATED" ]]; then
      ANYSCALE_WORKSPACE_WAIT_RESULT="${current_status}"
      return 0
    fi

    if (( attempt < max_attempts )); then
      sleep "${interval_seconds}"
    fi
  done

  ANYSCALE_WORKSPACE_WAIT_RESULT="Timed out waiting for TERMINATED after ${max_attempts} attempts; last observed state=${current_status}"
  return 1
}

workspace_head_pod_name() {
  local workspace_name="$1"
  local namespace head_pod_name

  namespace="${TF_VAR_anyscale_operator_namespace}"
  head_pod_name="$(kubectl get pods -n "${namespace}" \
    -l "app.kubernetes.io/name=${workspace_name},ray-node-type=head" \
    --request-timeout=15s \
    -o json 2>/dev/null \
    | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(.status.phase == "Running") | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty' || true)"

  [[ -n "${head_pod_name}" ]] || die "Could not find a Ray head pod for workspace ${workspace_name} in namespace ${namespace}."
  printf '%s\n' "${head_pod_name}"
}

wait_for_workspace_runtime_stable() {
  local workspace_name="$1"
  local worker_node_prefix="$2"
  local wait_log="$3"
  local namespace deadline current_epoch snapshot_json terminating_count head_name worker_line stable_count=0 previous_summary="" sleep_seconds

  namespace="${TF_VAR_anyscale_operator_namespace}"
  deadline=$(( $(date +%s) + SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS ))
  : > "${wait_log}.runtime-stable"

  while true; do
    snapshot_json="$(kubectl get pods -n "${namespace}" \
      -l "app.kubernetes.io/name=${workspace_name}" \
      --request-timeout=15s \
      -o json 2>/dev/null || true)"
    terminating_count="$(jq -r '[.items[] | select(.metadata.deletionTimestamp != null)] | length' <<<"${snapshot_json}")"
    head_name="$(jq -r '[.items[] | select(.metadata.labels["ray-node-type"] == "head") | select(.metadata.deletionTimestamp == null) | select(.status.phase == "Running") | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty' <<<"${snapshot_json}")"
    worker_line="$(jq -r --arg prefix "${worker_node_prefix}" '[.items[] | select(.metadata.labels["ray-node-type"] == "worker") | select(.metadata.deletionTimestamp == null) | select(.status.phase == "Running") | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | select(.spec.nodeName | startswith($prefix))] | sort_by(.metadata.creationTimestamp) | last | if . == null then "" else [.metadata.name, .spec.nodeName, .status.podIP] | @tsv end' <<<"${snapshot_json}")"

    printf 'terminating=%s head=%s worker=%s\n' "${terminating_count}" "${head_name}" "${worker_line}" >> "${wait_log}.runtime-stable"

    if [[ "${terminating_count}" == "0" && -n "${head_name}" && -n "${worker_line}" ]] \
      && anyscale_workspace_runtime_ready_on_cluster "${workspace_name}"; then
      stable_count=$((stable_count + 1))
      if (( stable_count >= 2 )); then
        log "Workspace ${workspace_name} runtime is stable with worker on ${worker_node_prefix}*."
        return 0
      fi
    else
      stable_count=0
    fi

    summary="terminating=${terminating_count} head=${head_name:-none} worker=${worker_line:-none} stable=${stable_count}/2"
    if [[ "${summary}" != "${previous_summary}" ]]; then
      log "Waiting for workspace ${workspace_name} runtime stability: ${summary}"
      previous_summary="${summary}"
    fi

    current_epoch=$(date +%s)
    if (( current_epoch >= deadline )); then
      die "Workspace ${workspace_name} runtime did not become stable. See ${wait_log}.runtime-stable."
    fi

    if (( stable_count > 0 )); then
      sleep_seconds=5
    else
      sleep_seconds=15
    fi
    sleep "${sleep_seconds}"
  done
}

workspace_exec_head_bash() {
  local workspace_name="$1"
  local script="$2"

  workspace_exec_head_bash_with_timeout "${workspace_name}" "${script}" "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}"
}

workspace_exec_head_bash_with_timeout() {
  local workspace_name="$1"
  local script="$2"
  local timeout_seconds="$3"
  local namespace head_pod_name

  require_positive_integer_arg "--command-timeout-seconds" "${timeout_seconds}"

  namespace="${TF_VAR_anyscale_operator_namespace}"
  head_pod_name="$(workspace_head_pod_name "${workspace_name}")"

  run_with_timeout "${timeout_seconds}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod_name}" -- bash -lc "${script}"
}

workspace_cpu_probe_command() {
  cat <<'EOF'
python - <<'PY'
import ray

ray.init(address="auto")

@ray.remote(num_cpus=1)
def cpu_probe():
    return "CPU_WORKSPACE_OK"

print(ray.get(cpu_probe.remote()))
PY
EOF
}

run_workspace_cpu_probe_with_timeout() {
  local workspace_name="$1"
  local timeout_seconds="$2"
  local cpu_ray_command

  cpu_ray_command="$(workspace_cpu_probe_command)"
  workspace_exec_head_bash_with_timeout "${workspace_name}" "${cpu_ray_command}" "${timeout_seconds}"
}

run_workspace_cpu_probe_with_retries() {
  local workspace_name="$1"
  local timeout_seconds="$2"
  local cpu_ray_log="$3"
  local max_attempts="${4:-4}"
  local cli_bin="${5:-}"
  local wait_log="${6:-}"
  local probe_attempt probe_exit

  require_positive_integer_arg "cpu-probe-max-attempts" "${max_attempts}"

  for ((probe_attempt=1; probe_attempt<=max_attempts; probe_attempt++)); do
    log "Ray num_cpus=1 probe attempt ${probe_attempt}/${max_attempts} on ${workspace_name}"
    probe_exit=0
    run_workspace_cpu_probe_with_timeout "${workspace_name}" "${timeout_seconds}" 2>&1 | tee "${cpu_ray_log}" || probe_exit=$?
    if [[ "${probe_exit}" -eq 0 ]] && grep -q 'CPU_WORKSPACE_OK' "${cpu_ray_log}"; then
      return 0
    fi
    if [[ "${probe_attempt}" -eq "${max_attempts}" ]]; then
      return 1
    fi
    log "CPU probe attempt ${probe_attempt} failed (exit=${probe_exit}); waiting 30s for workspace readiness to settle and retrying"
    sleep 30
    if [[ -n "${cli_bin}" && -n "${wait_log}" ]]; then
      wait_for_anyscale_workspace_running_attempts "${workspace_name}" "${cli_bin}" "${wait_log}" 10 30 || true
    fi
  done
}

###############################################################################
anyscale_workspaces_register() {
  local cpu_workspace_name="aks-cpu-workspace"
  local gpu_workspace_name="aks-gpu-workspace"
  local cpu_compute_config_name="aks-cpu"
  local gpu_compute_config_name="aks-gpu"
  local cli_bin namespace
  local cpu_compute_config_file gpu_compute_config_file
  local cpu_create_log cpu_start_log cpu_wait_log cpu_validate_log
  local gpu_create_log gpu_start_log gpu_wait_log gpu_validate_log

  load_env
  sync_anyscale_cli_env
  require_anyscale_cli_auth
  require_cmd jq
  require_cluster_kubectl_access
  require_env_var ANYSCALE_CLOUD_NAME
  require_env_var ANYSCALE_CLOUD_DEPLOYMENT_ID

  cli_bin="$(anyscale_cli_bin)"
  namespace="${TF_VAR_anyscale_operator_namespace}"
  mkdir -p "${CACHE_DIR}"

  ensure_anyscale_azure_cloud_dns_alias "${cli_bin}"

  cpu_compute_config_file="${CACHE_DIR}/anyscale-compute.${cpu_compute_config_name}.yaml"
  gpu_compute_config_file="${CACHE_DIR}/anyscale-compute.${gpu_compute_config_name}.yaml"
  cpu_create_log="${CACHE_DIR}/${cpu_workspace_name}.create.log"
  cpu_start_log="${CACHE_DIR}/${cpu_workspace_name}.start.log"
  cpu_wait_log="${CACHE_DIR}/${cpu_workspace_name}.wait.log"
  cpu_validate_log="${CACHE_DIR}/${cpu_workspace_name}.validate.log"
  gpu_create_log="${CACHE_DIR}/${gpu_workspace_name}.create.log"
  gpu_start_log="${CACHE_DIR}/${gpu_workspace_name}.start.log"
  gpu_wait_log="${CACHE_DIR}/${gpu_workspace_name}.wait.log"
  gpu_validate_log="${CACHE_DIR}/${gpu_workspace_name}.validate.log"

  ensure_registered_workspace() {
    local workspace_name="$1"
    local compute_config_name="$2"
    local create_log="$3"
    local workspace_json workspace_id workspace_state current_compute_config target_compute_config current_image_uri target_image_uri target_ray_version
    local create_output create_status update_output terminate_output workspace_update_file get_log update_log terminate_log terminate_wait_log
    local workspace_inspect_timeout="${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_INSPECT_SECONDS}"
    local workspace_lifecycle_timeout="${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS}"
    local -a update_cmd create_cmd

    target_image_uri=""
    target_ray_version=""
    if custom_image_enabled; then
      target_image_uri="$(custom_image_uri)"
      target_ray_version="${ANYSCALE_CUSTOM_IMAGE_RAY_VERSION}"
    fi

    create_status=0
    if run_with_timeout "${workspace_lifecycle_timeout}" \
      "${cli_bin}" workspace_v2 status \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" >/dev/null 2>&1; then
      log "Workspace ${workspace_name} already exists"
      get_log="${CACHE_DIR}/${workspace_name}.get.log"
      if ! workspace_json="$(run_with_timeout "${workspace_inspect_timeout}" \
        "${cli_bin}" workspace_v2 get \
          --name "${workspace_name}" \
          --cloud "${ANYSCALE_CLOUD_NAME}" \
          --json 2>&1)"; then
        printf '%s\n' "${workspace_json}" | tee "${get_log}"
        log "Workspace ${workspace_name} metadata lookup did not complete within ${workspace_inspect_timeout}s. Skipping compute-config drift check; start and runtime validation will still run."
        return 0
      fi
      workspace_id="$(jq -r '.id // empty' <<<"${workspace_json}")"
      workspace_state="$(jq -r '.state // empty' <<<"${workspace_json}")"
      current_compute_config="$(jq -r '.config.compute_config // empty' <<<"${workspace_json}")"
      current_image_uri="$(jq -r '.config.image_uri // empty' <<<"${workspace_json}")"
      target_compute_config="$(anyscale_compute_config_version_name "${compute_config_name}" "${cli_bin}")"

      if [[ -n "${workspace_id}" && -n "${target_compute_config}" ]] \
        && { [[ "${current_compute_config}" != "${target_compute_config}" ]] \
          || [[ -n "${target_image_uri}" && "${current_image_uri}" != "${target_image_uri}" ]]; }; then
        update_log="${CACHE_DIR}/${workspace_name}.update-workspace-runtime.log"
        terminate_log="${CACHE_DIR}/${workspace_name}.terminate-for-update.log"
        terminate_wait_log="${CACHE_DIR}/${workspace_name}.terminate-for-update.wait.log"
        workspace_update_file="${CACHE_DIR}/${workspace_name}.update-workspace-runtime.yaml"

        if [[ "${workspace_state}" != "TERMINATED" ]]; then
          log "Terminating workspace ${workspace_name} before runtime update"
          if ! terminate_output="$(run_with_timeout "${workspace_lifecycle_timeout}" \
            "${cli_bin}" workspace_v2 terminate \
              --name "${workspace_name}" \
              --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
            printf '%s\n' "${terminate_output}" | tee "${terminate_log}"
            if ! grep -Eiq 'already.*terminated|currently in state: TERMINATED' <<<"${terminate_output}"; then
              die "Workspace ${workspace_name} could not be terminated for runtime update. See ${terminate_log}."
            fi
          else
            printf '%s\n' "${terminate_output}" | tee "${terminate_log}"
          fi
          if ! wait_for_anyscale_workspace_terminated_attempts "${workspace_name}" "${cli_bin}" "${terminate_wait_log}" 30 20; then
            printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${terminate_wait_log}"
            die "${workspace_name} did not reach TERMINATED before runtime update. See ${terminate_wait_log}."
          fi
        fi

        write_anyscale_workspace_update_file "${workspace_json}" "${workspace_update_file}" "${compute_config_name}"
        update_cmd=("${cli_bin}" workspace_v2 update "${workspace_id}" -f "${workspace_update_file}" --compute-config "${compute_config_name}")
        if [[ -n "${target_image_uri}" ]]; then
          update_cmd+=(--image-uri "${target_image_uri}" --ray-version "${target_ray_version}")
        fi
        if ! update_output="$(run_with_timeout "${workspace_lifecycle_timeout}" "${update_cmd[@]}" 2>&1)"; then
          printf '%s\n' "${update_output}" | tee "${update_log}"
          die "Workspace ${workspace_name} runtime update failed. See ${update_log}."
        fi
        printf '%s\n' "${update_output}" | tee "${update_log}"
      fi
      return 0
    fi

    log "Creating workspace ${workspace_name} with compute config ${compute_config_name}"
    create_cmd=("${cli_bin}" workspace_v2 create --name "${workspace_name}" --compute-config "${compute_config_name}" --cloud "${ANYSCALE_CLOUD_NAME}")
    if [[ -n "${target_image_uri}" ]]; then
      create_cmd+=(--image-uri "${target_image_uri}" --ray-version "${target_ray_version}")
    fi
    if ! create_output="$(run_with_timeout "${workspace_lifecycle_timeout}" "${create_cmd[@]}" 2>&1)"; then
      create_status=$?
    fi
    printf '%s\n' "${create_output}" | tee "${create_log}"
    if [[ "${create_status}" -ne 0 ]] && ! grep -q 'Workspace created successfully id:' <<<"${create_output}"; then
      die "Workspace ${workspace_name} creation failed. See ${create_log}."
    fi
  }

  start_workspace_for_validation() {
    local workspace_name="$1"
    local start_log="$2"
    local start_output status_output workspace_status

    if status_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 status \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      workspace_status="$(normalize_anyscale_workspace_status "${status_output}")"
      [[ -n "${workspace_status}" ]] || workspace_status="UNKNOWN"
      printf '%s\n' "${status_output}" > "${start_log}.status"

      case "${workspace_status}" in
        RUNNING)
          log "Workspace ${workspace_name} is already RUNNING; skipping start to avoid churn."
          printf '%s\n' "${workspace_status}" | tee "${start_log}"
          return 0
          ;;
        STARTING)
          log "Workspace ${workspace_name} is already STARTING; waiting for it to become RUNNING."
          printf '%s\n' "${workspace_status}" | tee "${start_log}"
          return 0
          ;;
        CREATE_FAILED|FAILED|ERROR)
          die "Workspace ${workspace_name} is unhealthy with API status ${workspace_status}."
          ;;
        TERMINATED|TERMINATING|UNKNOWN)
          ;;
      esac
    else
      printf '%s\n' "${status_output}" > "${start_log}.status"
    fi

    if ! start_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS}" \
      "${cli_bin}" workspace_v2 start \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
      printf '%s\n' "${start_output}" | tee "${start_log}"
      if ! grep -Eiq 'already.*running|currently in state: STARTING|currently in state: RUNNING' <<<"${start_output}"; then
        die "Workspace ${workspace_name} start failed. See ${start_log}."
      fi
    else
      printf '%s\n' "${start_output}" | tee "${start_log}"
    fi
  }

  wait_for_workspace_running_or_die() {
    local workspace_name="$1"
    local wait_log="$2"

    if ! wait_for_anyscale_workspace_running "${workspace_name}" "${cli_bin}" "${wait_log}"; then
      printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}"
      die "Workspace ${workspace_name} did not reach RUNNING. See ${wait_log}."
    fi
    printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}"
  }

  validate_workspace_warm_capacity() {
    local workspace_name="$1"
    local worker_node_prefix="$2"
    local validate_log="$3"
    local deadline current_epoch head_pod head_node worker_line

    head_pod="$(workspace_head_pod_name "${workspace_name}")"
    head_node="$(kubectl get pod -n "${namespace}" "${head_pod}" --request-timeout=15s -o jsonpath='{.spec.nodeName}')"
    deadline=$(( $(date +%s) + SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS ))

    while true; do
      worker_line="$(kubectl get pods -n "${namespace}" \
        -l "app.kubernetes.io/name=${workspace_name},ray-node-type=worker" \
        --request-timeout=15s \
        -o wide --no-headers 2>/dev/null \
        | awk -v prefix="${worker_node_prefix}" '$3 == "Running" && $7 ~ "^"prefix {print; exit}')"
      if [[ -n "${worker_line}" ]]; then
        {
          printf 'workspace=%s\n' "${workspace_name}"
          printf 'head_pod=%s\n' "${head_pod}"
          printf 'head_node=%s\n' "${head_node}"
          printf 'worker=%s\n' "${worker_line}"
          kubectl get pods -n "${namespace}" -l "app.kubernetes.io/name=${workspace_name}" --request-timeout=15s -o wide
        } 2>&1 | tee "${validate_log}"
        return 0
      fi

      current_epoch="$(date +%s)"
      if (( current_epoch >= deadline )); then
        {
          printf 'workspace=%s\n' "${workspace_name}"
          printf 'head_pod=%s\n' "${head_pod}"
          printf 'head_node=%s\n' "${head_node}"
          printf 'missing_worker_prefix=%s\n' "${worker_node_prefix}"
          kubectl get pods -n "${namespace}" -l "app.kubernetes.io/name=${workspace_name}" --request-timeout=15s -o wide
        } 2>&1 | tee "${validate_log}"
        die "Workspace ${workspace_name} did not keep a warm worker on ${worker_node_prefix}*. See ${validate_log}."
      fi

      sleep 15
    done
  }

  validate_anyscale_operator_patches
  ensure_anyscale_compute_config "${cpu_compute_config_name}" "${cli_bin}" "${cpu_compute_config_file}" "cpu"
  ensure_registered_workspace "${cpu_workspace_name}" "${cpu_compute_config_name}" "${cpu_create_log}"
  start_workspace_for_validation "${cpu_workspace_name}" "${cpu_start_log}"
  wait_for_workspace_running_or_die "${cpu_workspace_name}" "${cpu_wait_log}"
  validate_workspace_warm_capacity "${cpu_workspace_name}" "aks-cpu-" "${cpu_validate_log}"

  if ! gpu_pools_enabled; then
    log "Skipping the ${gpu_compute_config_name} compute config and ${gpu_workspace_name}: $(gpu_disabled_notice)"
    log "CPU workspace ${cpu_workspace_name} is registered, running, and warm on the expected node pool."
    return 0
  fi

  ensure_anyscale_compute_config "${gpu_compute_config_name}" "${cli_bin}" "${gpu_compute_config_file}" "gpu"
  ensure_registered_workspace "${gpu_workspace_name}" "${gpu_compute_config_name}" "${gpu_create_log}"
  start_workspace_for_validation "${gpu_workspace_name}" "${gpu_start_log}"
  wait_for_workspace_running_or_die "${gpu_workspace_name}" "${gpu_wait_log}"
  validate_workspace_warm_capacity "${gpu_workspace_name}" "aks-gput4-" "${gpu_validate_log}"

  log "CPU workspace ${cpu_workspace_name} and GPU workspace ${gpu_workspace_name} are registered, running, and warm on the expected node pools."
}

###############################################################################
custom_image_enabled() {
  [[ "${ANYSCALE_CUSTOM_IMAGE_ENABLED:-false}" == "true" ]]
}

custom_image_requirement_name() {
  printf '%s\n' "${ANYSCALE_CUSTOM_IMAGE_REQUIREMENT%%==*}"
}

custom_image_uri() {
  local acr_login_server

  if [[ -n "${ANYSCALE_CUSTOM_IMAGE_URI:-}" ]]; then
    printf '%s\n' "${ANYSCALE_CUSTOM_IMAGE_URI}"
    return 0
  fi

  acr_login_server="$(custom_image_acr_name).azurecr.io"
  printf '%s/%s:%s\n' \
    "${acr_login_server}" \
    "${ANYSCALE_CUSTOM_IMAGE_REPOSITORY}" \
    "${ANYSCALE_CUSTOM_IMAGE_TAG}"
}

custom_image_acr_name() {
  # Prefer the Terraform output when local state is available (workstation).
  # Fall back to the deterministic name derived from TF_VAR_* env vars so the
  # build can run on the in-VNet jump host, which has no local Terraform state
  # (mirrors resource_group_name and Terraform local.names.acr =
  # substr("cr<project><environment><region_short>", 0, 50)).
  local acr_login_server derived
  acr_login_server="$(terraform output -raw acr_login_server 2>/dev/null || true)"
  if [[ -n "${acr_login_server}" ]]; then
    printf '%s\n' "${acr_login_server%%.*}"
    return 0
  fi
  derived="cr${TF_VAR_project}${TF_VAR_environment}${TF_VAR_region_short}"
  printf '%s\n' "${derived:0:50}"
}

operator_storage_account_name() {
  # Prefer the Terraform output when local state is available (workstation).
  # Fall back to the deterministic name derived from TF_VAR_* so this resolves on
  # the in-VNet jump host, which has no local Terraform state (mirrors
  # local.names.storage_account = substr("st<project><environment><region_short>", 0, 24)).
  local from_tf derived
  from_tf="$(terraform output -raw storage_account_name 2>/dev/null || true)"
  if [[ -n "${from_tf}" ]]; then
    printf '%s\n' "${from_tf}"
    return 0
  fi
  derived="st${TF_VAR_project}${TF_VAR_environment}${TF_VAR_region_short}"
  printf '%s\n' "${derived:0:24}"
}

anyscale_extension_resource_name() {
  # Prefer the Terraform output when local state is available (workstation).
  # Fall back to an Azure CLI lookup so this resolves on the in-VNet jump host,
  # which has no local Terraform state.
  local from_tf
  from_tf="$(terraform output -raw anyscale_extension_name 2>/dev/null || true)"
  if [[ -n "${from_tf}" ]]; then
    printf '%s\n' "${from_tf}"
    return 0
  fi
  az k8s-extension list \
    --resource-group "$(resource_group_name)" \
    --cluster-name "$(target_aks_cluster_name)" \
    --cluster-type managedClusters \
    --query "[?extensionType=='Anyscale.AKS.Operator'].name | [0]" \
    --output tsv \
    --only-show-errors
}

require_custom_image_acr_private_dns() {
  local acr_name="$1"
  local acr_host="${acr_name}.azurecr.io"
  local data_host="${acr_name}.${TF_VAR_azure_location}.data.azurecr.io"
  local private_ip data_private_ip local_ips data_local_ips

  private_ip="$(az network private-dns record-set a show \
    --resource-group "$(resource_group_name)" \
    --zone-name privatelink.azurecr.io \
    --name "${acr_name}" \
    --query 'aRecords[0].ipv4Address' \
    --output tsv \
    --only-show-errors 2>/dev/null || true)"

  [[ -n "${private_ip}" ]] || die "Could not read the private DNS A record for ${acr_host}."
  data_private_ip="$(az network private-dns record-set a show \
    --resource-group "$(resource_group_name)" \
    --zone-name privatelink.azurecr.io \
    --name "${acr_name}.${TF_VAR_azure_location}.data" \
    --query 'aRecords[0].ipv4Address' \
    --output tsv \
    --only-show-errors 2>/dev/null || true)"

  [[ -n "${data_private_ip}" ]] || die "Could not read the private DNS A record for ${data_host}."

  local_ips="$(resolve_ipv4_addresses "${acr_host}" 2>/dev/null | tr '\n' ' ' || true)"
  data_local_ips="$(resolve_ipv4_addresses "${data_host}" 2>/dev/null | tr '\n' ' ' || true)"
  if ! grep -qw "${private_ip}" <<<"${local_ips}"; then
    die "${acr_host} resolves locally to '${local_ips:-<none>}' but must resolve to private endpoint ${private_ip}. ${data_host} resolves locally to '${data_local_ips:-<none>}' and must resolve to ${data_private_ip}. Run from an in-VNet jump host with private DNS before building and pushing the custom image. AKS API access should remain Bastion-backed."
  fi
  if ! grep -qw "${data_private_ip}" <<<"${data_local_ips}"; then
    die "${data_host} resolves locally to '${data_local_ips:-<none>}' but must resolve to private endpoint ${data_private_ip}. ${acr_host} resolves locally to '${local_ips:-<none}' and must resolve to ${private_ip}. Run from an in-VNet jump host with private DNS before building and pushing the custom image. AKS API access should remain Bastion-backed."
  fi
}

custom_image_acr_token() {
  local acr_name="$1"

  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az acr login --name "${acr_name}" --expose-token --query accessToken -o tsv --only-show-errors
}

require_custom_image_acr_push_role() {
  local acr_name="$1"
  local acr_id principal_id role_count rc

  acr_id="$(az acr show --name "${acr_name}" --query id -o tsv --only-show-errors)"
  principal_id="$(current_azure_principal_object_id)"
  [[ -n "${principal_id}" ]] || die "Could not determine the active Azure principal object id for ACR push preflight."

  # Best-effort role verification. az role assignment list enriches output with
  # principal display names via Microsoft Graph (directoryObjects/getByIds),
  # which the jump-host managed identity cannot reach (Graph egress is
  # firewalled). When the lookup is unavailable, warn and defer to the
  # authoritative gate below (az acr login --expose-token + podman push). The
  # full check still runs on the workstation where Graph is reachable.
  rc=0
  role_count="$(az role assignment list \
    --scope "${acr_id}" \
    --include-inherited \
    --query "[?principalId=='${principal_id}' && (roleDefinitionName=='AcrPush' || roleDefinitionName=='Owner' || roleDefinitionName=='Contributor' || roleDefinitionName=='Container Registry Repository Contributor' || roleDefinitionName=='Container Registry Repository Writer')] | length(@)" \
    --output tsv \
    --only-show-errors 2>/dev/null)" || rc=$?

  if [[ "${rc}" -ne 0 || ! "${role_count}" =~ ^[0-9]+$ ]]; then
    warn "Could not verify an ACR push role for principal ${principal_id} on ${acr_name} (role-assignment lookup unavailable, e.g. Microsoft Graph is unreachable from the jump host). Continuing; the ACR login and push are the authoritative check."
    return 0
  fi

  [[ "${role_count}" -gt 0 ]] \
    || die "Active Azure principal ${principal_id} does not have AcrPush or an equivalent push role on ${acr_name}. Grant AcrPush on the registry before local custom-image prepare."
}

custom_image_preflight() {
  local check_token="${1:-true}"
  local image_uri acr_name token_output

  load_env
  require_cmd az
  require_cmd jq
  require_cmd podman
  [[ -f "$(custom_image_build_context_dir)/Dockerfile" ]] || die "Missing workloads/custom-image/Dockerfile."
  [[ -f "$(custom_image_build_context_dir)/requirements-custom-image.txt" ]] || die "Missing workloads/custom-image/requirements-custom-image.txt."

  image_uri="$(custom_image_uri)"
  acr_name="$(custom_image_acr_name)"

  log "Checking custom image local build readiness for ${image_uri}."
  log "Bastion is used for AKS API access. Run from an in-VNet jump host with private DNS routing for local ACR build/push."

  if ! podman info >/dev/null 2>&1; then
    die "Podman is installed but not ready. Start your Podman machine manually before custom-image prepare."
  fi

  require_custom_image_acr_private_dns "${acr_name}"
  require_custom_image_acr_push_role "${acr_name}"

  if [[ "${check_token}" == true ]]; then
    token_output="$(custom_image_acr_token "${acr_name}" 2>&1 >/dev/null)" \
      || die "Could not get an ACR access token for ${acr_name}. Ensure Azure login is fresh, the current principal has AcrPush, and role propagation has completed. ACR output: ${token_output}"
  fi

  printf 'CUSTOM_IMAGE_PREFLIGHT_OK image_uri=%s\n' "${image_uri}"
}

custom_image_repository_name() {
  printf '%s\n' "${ANYSCALE_CUSTOM_IMAGE_REPOSITORY}"
}

custom_image_build_context_dir() {
  printf '%s/workloads/custom-image\n' "${ROOT_DIR}"
}

custom_image_prepare() {
  local image_uri acr_name repository_name build_context token

  custom_image_preflight false
  mkdir -p "${CACHE_DIR}/tmp"

  image_uri="$(custom_image_uri)"
  acr_name="$(custom_image_acr_name)"
  repository_name="$(custom_image_repository_name)"
  build_context="$(custom_image_build_context_dir)"

  log "Preparing custom image ${image_uri} with Podman."
  token="$(custom_image_acr_token "${acr_name}" 2>&1)" \
    || die "Could not get an ACR access token for ${acr_name}. Ensure Azure login is fresh, the current principal has AcrPush, and role propagation has completed. ACR output: ${token}"
  printf '%s' "${token}" | podman login "${acr_name}.azurecr.io" \
    --username 00000000-0000-0000-0000-000000000000 \
    --password-stdin >/dev/null

  TMPDIR="${TMPDIR:-${CACHE_DIR}/tmp}" podman build \
    --platform linux/amd64 \
    --build-arg "ANYSCALE_BASE_IMAGE=${ANYSCALE_CUSTOM_IMAGE_BASE_IMAGE:-docker.io/anyscale/ray:2.55.1-slim-py312-cu129}" \
    -t "${image_uri}" \
    "${build_context}"

  podman image inspect "${image_uri}" --format '{{.Os}}/{{.Architecture}}' | grep -q '^linux/amd64$' \
    || die "Custom image ${image_uri} was not built as linux/amd64."

  podman push "${image_uri}"

  az acr repository show-tags \
    --name "${acr_name}" \
    --repository "${repository_name}" \
    --query "[?@=='${ANYSCALE_CUSTOM_IMAGE_TAG}']" \
    --output tsv \
    --only-show-errors | grep -q "${ANYSCALE_CUSTOM_IMAGE_TAG}" \
    || die "Pushed image tag ${ANYSCALE_CUSTOM_IMAGE_TAG} was not visible in ACR repository ${repository_name}."

  printf 'CUSTOM_IMAGE_BUILD_OK image_uri=%s\n' "${image_uri}"
}

custom_image_runtime_flags() {
  custom_image_enabled || return 0
  printf '%s\n' \
    --image-uri "$(custom_image_uri)" \
    --ray-version "${ANYSCALE_CUSTOM_IMAGE_RAY_VERSION}"
}

###############################################################################
# Image signing (Notation + Key Vault) and AKS Image Integrity (Ratify).
# Signing runs on the in-VNet jump host (reaches the private ACR + Key Vault
# endpoints). apply-ratify also runs from the in-VNet jump host for private
# Key Vault + AKS access; when Terraform state is absent it derives the Ratify
# client id / Key Vault URI / ACR login server from Azure CLI and deterministic
# names.
###############################################################################
signing_key_vault_name() {
  # Prefer the Terraform output (workstation). Fall back to the deterministic
  # name derived from TF_VAR_* so signing works on the jump host, which has no
  # local Terraform state (mirrors local.names.key_vault = substr(kv-<suffix>, 0, 24)).
  local from_tf derived
  from_tf="$(terraform output -raw key_vault_name 2>/dev/null || true)"
  if [[ -n "${from_tf}" ]]; then
    printf '%s\n' "${from_tf}"
    return 0
  fi
  derived="kv-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  printf '%s\n' "${derived:0:24}"
}

custom_image_resolve_digest() {
  local acr_name="$1" repo="$2" tag="$3"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az acr repository show \
      --name "${acr_name}" \
      --image "${repo}:${tag}" \
      --query digest -o tsv --only-show-errors
}

ensure_signing_certificate() {
  local akv_name="$1" cert_name="$2" policy_file exists

  exists="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az keyvault certificate show --vault-name "${akv_name}" --name "${cert_name}" \
      --query name -o tsv --only-show-errors 2>/dev/null || true)"
  [[ -n "${exists}" ]] && return 0

  mkdir -p "${CACHE_DIR}/tmp"
  policy_file="$(mktemp "${CACHE_DIR}/tmp/signing-cert-policy.XXXXXX.json")"
  cat > "${policy_file}" <<JSON
{
  "issuerParameters": {
    "name": "Self"
  },
  "keyProperties": {
    "exportable": false,
    "keySize": 2048,
    "keyType": "RSA",
    "reuseKey": true
  },
  "secretProperties": {
    "contentType": "application/x-pem-file"
  },
  "x509CertificateProperties": {
    "ekus": [
      "1.3.6.1.5.5.7.3.3"
    ],
    "keyUsage": [
      "digitalSignature"
    ],
    "subject": "${ANYSCALE_SIGNING_CERT_SUBJECT}",
    "validityInMonths": ${ANYSCALE_SIGNING_CERT_VALIDITY_MONTHS:-12}
  }
}
JSON

  log "Creating signing certificate ${cert_name} in private Key Vault ${akv_name}."
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az keyvault certificate create --vault-name "${akv_name}" --name "${cert_name}" \
      --policy "@${policy_file}" --only-show-errors >/dev/null \
    || { rm -f "${policy_file}"; die "Could not create signing certificate ${cert_name} in Key Vault ${akv_name}. Ensure this principal has Key Vault Certificates Officer and reaches the private endpoint."; }
  rm -f "${policy_file}"
}

custom_image_sign() {
  custom_image_enabled || die "Set ANYSCALE_CUSTOM_IMAGE_ENABLED=true before signing the custom image."
  load_env
  require_cmd az
  require_cmd notation
  notation plugin ls 2>/dev/null | grep -q 'azure-kv' \
    || die "notation azure-kv plugin not installed. Re-run scripts/bootstrap-jump-host.sh on the jump host."

  local acr_name akv_name cert_name repo tag digest key_id image_ref acr_token
  acr_name="$(custom_image_acr_name)"
  akv_name="$(signing_key_vault_name)"
  cert_name="${ANYSCALE_SIGNING_CERT_NAME}"
  repo="${ANYSCALE_CUSTOM_IMAGE_REPOSITORY}"
  tag="${ANYSCALE_CUSTOM_IMAGE_TAG}"

  require_custom_image_acr_private_dns "${acr_name}"

  log "Resolving digest for ${acr_name}.azurecr.io/${repo}:${tag}..."
  digest="$(custom_image_resolve_digest "${acr_name}" "${repo}" "${tag}")" \
    || die "Could not resolve the digest for ${repo}:${tag} in ${acr_name}. Run custom-image prepare (build + push) first."
  [[ -n "${digest}" ]] || die "Empty digest for ${repo}:${tag} in ${acr_name}."

  ensure_signing_certificate "${akv_name}" "${cert_name}"

  log "Resolving signing key id from Key Vault ${akv_name} (cert ${cert_name})..."
  key_id="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az keyvault certificate show --vault-name "${akv_name}" --name "${cert_name}" \
      --query kid -o tsv --only-show-errors)" \
    || die "Could not read certificate ${cert_name} from Key Vault ${akv_name}. Ensure this principal has Key Vault Certificates Officer + Crypto User."
  [[ -n "${key_id}" ]] || die "Empty key id for cert ${cert_name} in ${akv_name}."

  image_ref="${acr_name}.azurecr.io/${repo}@${digest}"
  acr_token="$(custom_image_acr_token "${acr_name}" 2>&1)" \
    || die "Could not get an ACR access token for ${acr_name}. ACR output: ${acr_token}"
  log "Signing ${image_ref} with notation (cose, azure-kv, managedid)..."
  NOTATION_USERNAME=00000000-0000-0000-0000-000000000000 NOTATION_PASSWORD="${acr_token}" \
    run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    notation sign \
      --signature-format cose \
      --id "${key_id}" \
      --plugin azure-kv \
      --plugin-config credential_type=managedid \
      "${image_ref}"

  printf 'CUSTOM_IMAGE_SIGN_OK image_uri=%s digest=%s\n' "$(custom_image_uri)" "${digest}"
}

custom_image_verify() {
  custom_image_enabled || die "Set ANYSCALE_CUSTOM_IMAGE_ENABLED=true before verifying the custom image."
  load_env
  require_cmd az
  require_cmd notation

  local acr_name akv_name cert_name store_name subject repo tag digest cert_pem policy_file image_ref acr_token
  acr_name="$(custom_image_acr_name)"
  akv_name="$(signing_key_vault_name)"
  cert_name="${ANYSCALE_SIGNING_CERT_NAME}"
  store_name="${ANYSCALE_SIGNING_CERT_STORE_NAME}"
  subject="${ANYSCALE_SIGNING_CERT_SUBJECT}"
  repo="${ANYSCALE_CUSTOM_IMAGE_REPOSITORY}"
  tag="${ANYSCALE_CUSTOM_IMAGE_TAG}"

  require_custom_image_acr_private_dns "${acr_name}"

  digest="$(custom_image_resolve_digest "${acr_name}" "${repo}" "${tag}")" \
    || die "Could not resolve the digest for ${repo}:${tag} in ${acr_name}."
  [[ -n "${digest}" ]] || die "Empty digest for ${repo}:${tag} in ${acr_name}."

  mkdir -p "${CACHE_DIR}/tmp"
  cert_pem="$(mktemp "${CACHE_DIR}/tmp/signing-cert.XXXXXX")"
  rm -f "${cert_pem}"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az keyvault certificate download --vault-name "${akv_name}" --name "${cert_name}" \
      --file "${cert_pem}" --encoding PEM --only-show-errors \
    || { rm -f "${cert_pem}"; die "Could not download cert ${cert_name} from Key Vault ${akv_name}."; }
  notation cert add --type ca --store "${store_name}" "${cert_pem}" || true
  rm -f "${cert_pem}"

  policy_file="$(mktemp "${CACHE_DIR}/tmp/trustpolicy.XXXXXX")"
  cat > "${policy_file}" <<JSON
{
  "version": "1.0",
  "trustPolicies": [
    {
      "name": "anyscale-aks",
      "registryScopes": ["${acr_name}.azurecr.io/${repo}"],
      "signatureVerification": { "level": "strict" },
      "trustStores": ["ca:${store_name}"],
      "trustedIdentities": ["x509.subject:${subject}"]
    }
  ]
}
JSON
  notation policy import --force "${policy_file}"
  rm -f "${policy_file}"

  image_ref="${acr_name}.azurecr.io/${repo}@${digest}"
  acr_token="$(custom_image_acr_token "${acr_name}" 2>&1)" \
    || die "Could not get an ACR access token for ${acr_name}. ACR output: ${acr_token}"
  log "Verifying signature on ${image_ref}..."
  NOTATION_USERNAME=00000000-0000-0000-0000-000000000000 NOTATION_PASSWORD="${acr_token}" \
    run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    notation verify "${image_ref}"

  printf 'CUSTOM_IMAGE_VERIFY_OK image_uri=%s digest=%s\n' "$(custom_image_uri)" "${digest}"
}

# ORAS login against the private ACR using a short-lived ACR token. The token is
# only ever passed over stdin so it never appears in argv or logs.
custom_image_oras_login() {
  local acr_name="$1" acr_token="$2"
  printf '%s' "${acr_token}" | oras login "${acr_name}.azurecr.io" \
    --username 00000000-0000-0000-0000-000000000000 \
    --password-stdin >/dev/null
}

# Discover the digest of the application/spdx+json SBOM referrer attached to the
# image. Emits an empty string when no such referrer exists.
custom_image_sbom_referrer_digest() {
  local image_ref="$1"
  local digest attempt

  for attempt in {1..12}; do
    digest="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
      oras discover --artifact-type application/spdx+json --format json "${image_ref}" \
      | jq -r '(.referrers // .manifests // []) | sort_by(.annotations["org.opencontainers.image.created"] // "") | reverse | .[0].digest // empty')" || return $?
    if [[ -n "${digest}" ]]; then
      printf '%s\n' "${digest}"
      return 0
    fi
    sleep 5
  done

  printf ''
}

custom_image_sbom() {
  custom_image_enabled || die "Set ANYSCALE_CUSTOM_IMAGE_ENABLED=true before generating the custom image SBOM."
  load_env
  require_cmd az
  require_cmd jq
  require_cmd syft
  require_cmd oras

  local acr_name repo tag digest image_ref acr_token sbom_file referrer_digest sbom_ref
  local akv_name cert_name key_id sbom_signed
  acr_name="$(custom_image_acr_name)"
  repo="${ANYSCALE_CUSTOM_IMAGE_REPOSITORY}"
  tag="${ANYSCALE_CUSTOM_IMAGE_TAG}"

  require_custom_image_acr_private_dns "${acr_name}"

  log "Resolving digest for ${acr_name}.azurecr.io/${repo}:${tag}..."
  digest="$(custom_image_resolve_digest "${acr_name}" "${repo}" "${tag}")" \
    || die "Could not resolve the digest for ${repo}:${tag} in ${acr_name}. Run custom-image prepare (build + push) first."
  [[ -n "${digest}" ]] || die "Empty digest for ${repo}:${tag} in ${acr_name}."

  image_ref="${acr_name}.azurecr.io/${repo}@${digest}"
  acr_token="$(custom_image_acr_token "${acr_name}" 2>&1)" \
    || die "Could not get an ACR access token for ${acr_name}. ACR output: ${acr_token}"

  mkdir -p "${CACHE_DIR}/tmp"
  sbom_file="$(mktemp "${CACHE_DIR}/tmp/custom-image-sbom.XXXXXX.spdx.json")"

  log "Generating SPDX SBOM for ${image_ref} with syft..."
  SYFT_REGISTRY_AUTH_AUTHORITY="${acr_name}.azurecr.io" \
  SYFT_REGISTRY_AUTH_USERNAME=00000000-0000-0000-0000-000000000000 \
  SYFT_REGISTRY_AUTH_PASSWORD="${acr_token}" \
    run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
      syft scan "registry:${image_ref}" -o "spdx-json=${sbom_file}" \
    || { rm -f "${sbom_file}"; die "syft failed to generate the SBOM for ${image_ref}."; }

  log "Logging in to ${acr_name}.azurecr.io for ORAS..."
  custom_image_oras_login "${acr_name}" "${acr_token}"

  log "Attaching SBOM to ${image_ref} as an OCI referrer (application/spdx+json)..."
  (
    cd "$(dirname "${sbom_file}")"
    run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
      oras attach --artifact-type application/spdx+json \
        "${image_ref}" \
        "$(basename "${sbom_file}"):application/spdx+json"
  ) || { rm -f "${sbom_file}"; die "ORAS failed to attach the SBOM referrer to ${image_ref}."; }
  rm -f "${sbom_file}"

  referrer_digest="$(custom_image_sbom_referrer_digest "${image_ref}")" \
    || die "Could not discover the SBOM referrer for ${image_ref} after attach."
  [[ -n "${referrer_digest}" ]] || die "SBOM referrer not visible for ${image_ref} after attach."
  sbom_ref="${acr_name}.azurecr.io/${repo}@${referrer_digest}"

  sbom_signed=false
  if command -v notation >/dev/null 2>&1 && notation plugin ls 2>/dev/null | grep -q 'azure-kv'; then
    akv_name="$(signing_key_vault_name)"
    cert_name="${ANYSCALE_SIGNING_CERT_NAME}"
    ensure_signing_certificate "${akv_name}" "${cert_name}"
    log "Resolving signing key id from Key Vault ${akv_name} (cert ${cert_name})..."
    key_id="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
      az keyvault certificate show --vault-name "${akv_name}" --name "${cert_name}" \
        --query kid -o tsv --only-show-errors)" \
      || die "Could not read certificate ${cert_name} from Key Vault ${akv_name}. Ensure this principal has Key Vault Certificates Officer + Crypto User."
    [[ -n "${key_id}" ]] || die "Empty key id for cert ${cert_name} in ${akv_name}."
    log "Signing SBOM referrer ${sbom_ref} with notation (cose, azure-kv, managedid)..."
    NOTATION_USERNAME=00000000-0000-0000-0000-000000000000 NOTATION_PASSWORD="${acr_token}" \
      run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
      notation sign \
        --signature-format cose \
        --id "${key_id}" \
        --plugin azure-kv \
        --plugin-config credential_type=managedid \
        "${sbom_ref}"
    sbom_signed=true
  else
    warn "notation azure-kv plugin not available; attaching the SBOM referrer without a signature."
  fi

  printf 'CUSTOM_IMAGE_SBOM_OK image_uri=%s digest=%s sbom_referrer=%s signed=%s\n' \
    "$(custom_image_uri)" "${digest}" "${referrer_digest}" "${sbom_signed}"
}

custom_image_sbom_proof() {
  load_env
  require_cmd az
  require_cmd jq
  require_cmd oras
  require_cmd python3
  [[ -f "${ROOT_DIR}/workloads/proofs/custom_image_sbom_proof.py" ]] || die "Missing workloads/proofs/custom_image_sbom_proof.py"

  local acr_name repo tag digest image_ref acr_token referrer_digest sbom_ref pull_dir requirement
  acr_name="$(custom_image_acr_name)"
  repo="${ANYSCALE_CUSTOM_IMAGE_REPOSITORY}"
  tag="${ANYSCALE_CUSTOM_IMAGE_TAG}"
  requirement="${ANYSCALE_CUSTOM_IMAGE_REQUIREMENT}"

  require_custom_image_acr_private_dns "${acr_name}"

  digest="$(custom_image_resolve_digest "${acr_name}" "${repo}" "${tag}")" \
    || die "Could not resolve the digest for ${repo}:${tag} in ${acr_name}."
  [[ -n "${digest}" ]] || die "Empty digest for ${repo}:${tag} in ${acr_name}."

  image_ref="${acr_name}.azurecr.io/${repo}@${digest}"
  acr_token="$(custom_image_acr_token "${acr_name}" 2>&1)" \
    || die "Could not get an ACR access token for ${acr_name}. ACR output: ${acr_token}"

  custom_image_oras_login "${acr_name}" "${acr_token}"

  log "Discovering SBOM referrer (application/spdx+json) for ${image_ref}..."
  referrer_digest="$(custom_image_sbom_referrer_digest "${image_ref}")" \
    || die "Could not query referrers for ${image_ref}."
  [[ -n "${referrer_digest}" ]] || die "No application/spdx+json SBOM referrer found for ${image_ref}. Run custom-image sbom first."

  sbom_ref="${acr_name}.azurecr.io/${repo}@${referrer_digest}"
  mkdir -p "${CACHE_DIR}/tmp"
  pull_dir="$(mktemp -d "${CACHE_DIR}/tmp/custom-image-sbom-pull.XXXXXX")"
  log "Pulling SBOM referrer ${sbom_ref}..."
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    oras pull "${sbom_ref}" --output "${pull_dir}" \
    || { rm -rf "${pull_dir}"; die "ORAS failed to pull the SBOM referrer ${sbom_ref}."; }

  log "Verifying packaged dependency ${requirement} in the SBOM referrer..."
  ANYSCALE_CUSTOM_IMAGE_REQUIREMENT="${requirement}" \
    python3 "${ROOT_DIR}/workloads/proofs/custom_image_sbom_proof.py" "${pull_dir}" \
    || { rm -rf "${pull_dir}"; die "SBOM referrer for ${image_ref} did not contain ${requirement}."; }
  rm -rf "${pull_dir}"

  printf 'CUSTOM_IMAGE_SBOM_PROOF_OK image_uri=%s digest=%s sbom_referrer=%s requirement=%s\n' \
    "$(custom_image_uri)" "${digest}" "${referrer_digest}" "${requirement}"
}

image_integrity_preflight() {
  local strict="${1:-}"
  load_env
  require_cmd az

  local flag_state ext_ver
  flag_state="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az feature show --namespace Microsoft.ContainerService --name EnableImageIntegrityPreview \
      --query properties.state -o tsv --only-show-errors 2>/dev/null || echo Unknown)"
  if [[ "${flag_state}" != "Registered" ]]; then
    warn "Subscription feature EnableImageIntegrityPreview is '${flag_state}'."
    warn "Terraform manages this (azapi_resource.image_integrity_feature). If not yet applied, register it with:"
    warn "  az feature register --namespace Microsoft.ContainerService --name EnableImageIntegrityPreview"
    warn "  az provider register --namespace Microsoft.ContainerService"
    warn "Registration is eventually consistent (minutes)."
    [[ "${strict}" == "--strict" ]] && die "EnableImageIntegrityPreview not registered."
  fi

  ext_ver="$(az extension show --name aks-preview --query version -o tsv 2>/dev/null || echo 0.0.0)"
  if [[ "$(printf '%s\n%s\n' '0.5.96' "${ext_ver}" | sort -V | head -1)" != "0.5.96" ]]; then
    warn "aks-preview extension '${ext_ver}' is older than 0.5.96. Update with: az extension update --name aks-preview"
  fi

  printf 'IMAGE_INTEGRITY_PREFLIGHT_OK feature_state=%s aks_preview=%s\n' "${flag_state}" "${ext_ver}"
}

image_integrity_apply_ratify() {
  load_env
  require_cmd kubectl
  require_cmd envsubst

  local akv_name akv_uri ratify_client_id acr_login_server tenant_id crd_dir manifest rendered_manifest cert_pem
  tenant_id="${TF_VAR_azure_tenant_id:-${ARM_TENANT_ID:-}}"
  [[ -n "${tenant_id}" ]] || die "Azure tenant id unavailable (set TF_VAR_azure_tenant_id)."
  # kubelogin honors AZURE_TENANT_ID when present. Set it before any kube access
  # so stale caller environment values cannot poison authentication.
  export AZURE_TENANT_ID="${tenant_id}"

  ensure_cluster_access

  akv_name="$(signing_key_vault_name)"
  akv_uri="$(terraform output -raw key_vault_uri 2>/dev/null || true)"
  [[ -n "${akv_uri}" ]] || akv_uri="https://${akv_name}.vault.azure.net/"
  ratify_client_id="$(terraform output -raw ratify_client_id 2>/dev/null || true)"
  if [[ -z "${ratify_client_id}" ]]; then
    ratify_client_id="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
      az identity show --resource-group "$(resource_group_name)" \
        --name "id-ratify-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}" \
        --query clientId -o tsv --only-show-errors 2>/dev/null || true)"
  fi
  [[ -n "${ratify_client_id}" ]] || die "Could not resolve the Ratify workload identity client id."
  acr_login_server="$(terraform output -raw acr_login_server 2>/dev/null || true)"
  [[ -n "${acr_login_server}" ]] || acr_login_server="$(custom_image_acr_name).azurecr.io"

  mkdir -p "${CACHE_DIR}/tmp"
  cert_pem="$(mktemp "${CACHE_DIR}/tmp/ratify-cert.XXXXXX")"
  rm -f "${cert_pem}"
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az keyvault certificate download --vault-name "${akv_name}" --name "${ANYSCALE_SIGNING_CERT_NAME}" \
      --file "${cert_pem}" --encoding PEM --only-show-errors \
    || { rm -f "${cert_pem}"; die "Could not download public signing certificate ${ANYSCALE_SIGNING_CERT_NAME} from Key Vault ${akv_name}. Run from the in-VNet jump host or another host that reaches the private Key Vault endpoint."; }

  export ANYSCALE_AKV_URI="${akv_uri}"
  export ANYSCALE_RATIFY_CLIENT_ID="${ratify_client_id}"
  export ANYSCALE_ACR_LOGIN_SERVER="${acr_login_server}"
  export ANYSCALE_CUSTOM_IMAGE_REPOSITORY ANYSCALE_SIGNING_CERT_NAME ANYSCALE_SIGNING_CERT_SUBJECT
  ANYSCALE_SIGNING_CERT_PEM="$(awk 'NR == 1 { printf "%s", $0; next } { printf "\n      %s", $0 } END { printf "\n" }' "${cert_pem}")"
  export ANYSCALE_SIGNING_CERT_PEM
  rm -f "${cert_pem}"

  log "Waiting for the Ratify pod (gatekeeper-system) deployed by the Image Integrity policy..."
  run_with_timeout "${SETUP_TIMEOUT_K8S_ROLLOUT_SECONDS:-600}" \
    kubectl wait pod --namespace gatekeeper-system --selector app=ratify \
      --for=condition=Ready --timeout=300s \
    || die "Ratify pod not Ready. If Image Integrity was just enabled, the Azure Policy remediation may still be deploying it; re-run after it settles."

  # Earlier versions of this sample used a KeyManagementProvider. The managed
  # AKS Ratify verifier expects a CertificateStore for inline public certs.
  kubectl delete keymanagementprovider keymanagementprovider-akv --ignore-not-found >/dev/null 2>&1 || true

  crd_dir="${ROOT_DIR}/workloads/image-integrity"
  for manifest in certstore.yaml store.yaml verifier.yaml; do
    log "Applying Ratify CRD ${manifest}..."
    rendered_manifest="$(mktemp "${CACHE_DIR}/tmp/ratify-${manifest}.XXXXXX")"
    envsubst '$ANYSCALE_AKV_URI $AZURE_TENANT_ID $ANYSCALE_RATIFY_CLIENT_ID $ANYSCALE_SIGNING_CERT_NAME $ANYSCALE_SIGNING_CERT_PEM $ANYSCALE_ACR_LOGIN_SERVER $ANYSCALE_CUSTOM_IMAGE_REPOSITORY $ANYSCALE_SIGNING_CERT_SUBJECT' \
      < "${crd_dir}/${manifest}" > "${rendered_manifest}"
    [[ -s "${rendered_manifest}" ]] || die "Rendered Ratify manifest ${manifest} was empty."
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS:-180}" kubectl apply -f "${rendered_manifest}"
    rm -f "${rendered_manifest}"
  done

  printf 'IMAGE_INTEGRITY_RATIFY_OK\n'
}

workload_require_inputs() {
  load_env
  sync_anyscale_cli_env
  require_anyscale_cli_auth
  require_cmd jq
  require_cmd rsync
  require_env_var ANYSCALE_CLOUD_NAME
}

workload_require_workspace_proof_inputs() {
  workload_require_inputs
  [[ -f "${ROOT_DIR}/workloads/proofs/cpu_ray_proof.py" ]] || die "Missing workloads/proofs/cpu_ray_proof.py"
  [[ -f "${ROOT_DIR}/workloads/proofs/gpu_ray_proof.py" ]] || die "Missing workloads/proofs/gpu_ray_proof.py"
}

workload_require_pipeline_inputs() {
  workload_require_inputs
  require_cmd curl
  require_cmd lsof
  [[ -f "${ROOT_DIR}/workloads/proofs/build_train_serve_common.py" ]] || die "Missing workloads/proofs/build_train_serve_common.py"
  [[ -f "${ROOT_DIR}/workloads/proofs/anyscale_build_cpu_job_proof.py" ]] || die "Missing workloads/proofs/anyscale_build_cpu_job_proof.py"
  [[ -f "${ROOT_DIR}/workloads/proofs/anyscale_train_gpu_job_proof.py" ]] || die "Missing workloads/proofs/anyscale_train_gpu_job_proof.py"
  [[ -f "${ROOT_DIR}/workloads/proofs/anyscale_serve_gpu_proof.py" ]] || die "Missing workloads/proofs/anyscale_serve_gpu_proof.py"
}

workload_prepare_stage() {
  workload_require_inputs
  ensure_cluster_access
}

workload_workspace_name_for_compute_config() {
  local compute_config_name="$1"

  case "${compute_config_name}" in
    "${WORKLOAD_CPU_COMPUTE_CONFIG_NAME}")
      printf '%s\n' "${WORKLOAD_CPU_WORKSPACE_NAME}"
      ;;
    "${WORKLOAD_GPU_COMPUTE_CONFIG_NAME}")
      printf '%s\n' "${WORKLOAD_GPU_WORKSPACE_NAME}"
      ;;
    *)
      die "No workload workspace is mapped to compute config ${compute_config_name}."
      ;;
  esac
}

workload_worker_node_prefix_for_compute_config() {
  local compute_config_name="$1"

  case "${compute_config_name}" in
    "${WORKLOAD_CPU_COMPUTE_CONFIG_NAME}")
      printf '%s\n' 'aks-cpu-'
      ;;
    "${WORKLOAD_GPU_COMPUTE_CONFIG_NAME}")
      printf '%s\n' 'aks-gput4-'
      ;;
    *)
      die "No worker-node prefix is mapped to compute config ${compute_config_name}."
      ;;
  esac
}

copy_workload_proofs_to_pod() {
  local namespace="$1"
  local pod="$2"
  local remote_dir="$3"
  local proof_dir marker_path marker_present

  proof_dir="${ROOT_DIR}/workloads/proofs"
  marker_path="${remote_dir}/.workload-proofs-copied"

  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${pod}" -- \
      bash -lc "mkdir -p '${remote_dir}'"

  marker_present=false
  if run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${pod}" -- \
      bash -lc "test -f '${marker_path}'" >/dev/null 2>&1; then
    marker_present=true
  fi

  if [[ "${marker_present}" == true ]]; then
    log "Workload proof scripts already present on pod ${pod}:${remote_dir}; skipping copy."
    return 0
  fi

  log "Copying workload proof scripts to pod ${pod}:${remote_dir}"
  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl cp -n "${namespace}" -c ray \
      "${proof_dir}/." \
      "${pod}:${remote_dir}/"
  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${pod}" -- \
      bash -lc "touch '${marker_path}'"
}

prepare_workload_submission_dir() {
  local workspace_name="$1"
  local worker_node_prefix="$2"
  local remote_dir="$3"
  local cli_bin wait_log namespace head_pod

  ensure_cluster_access

  cli_bin="$(anyscale_cli_bin)"
  wait_log="${SETUP_RUN_DIR}/${workspace_name}.wait.log"
  namespace="${TF_VAR_anyscale_operator_namespace}"

  ensure_workload_workspace_running "${workspace_name}" "${cli_bin}" "${wait_log}"
  wait_for_workspace_runtime_stable "${workspace_name}" "${worker_node_prefix}" "${wait_log}"

  head_pod="$(workspace_head_pod_name "${workspace_name}")"

  copy_workload_proofs_to_pod "${namespace}" "${head_pod}" "${remote_dir}"

  WORKLOAD_LAST_HEAD_POD="${head_pod}"
}

workload_workspace_id() {
  local cli_bin="$1"
  local workspace_name="$2"

  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 get \
      --name "${workspace_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" \
      --json \
    | jq -r '.id // empty'
}

ensure_workload_workspace_running() {
  local workspace_name="$1"
  local cli_bin="$2"
  local wait_log="$3"
  local status_output workspace_status start_output

  if status_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 status \
      --name "${workspace_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
    workspace_status="$(normalize_anyscale_workspace_status "${status_output}")"
    [[ -n "${workspace_status}" ]] || workspace_status="UNKNOWN"
    printf '%s\n' "${status_output}" > "${wait_log}.status"

    case "${workspace_status}" in
      RUNNING)
        log "Workspace ${workspace_name} is already RUNNING; skipping start to avoid churn."
        printf '%s\n' "${workspace_status}" | tee "${wait_log}.start"
        printf '%s\n' "${workspace_status}" | tee -a "${wait_log}"
        return 0
        ;;
      STARTING)
        log "Workspace ${workspace_name} is already STARTING; waiting for it to become RUNNING."
        printf '%s\n' "${workspace_status}" | tee "${wait_log}.start"
        ;;
      CREATE_FAILED|FAILED|ERROR)
        die "Workspace ${workspace_name} is unhealthy with API status ${workspace_status}."
        ;;
      TERMINATED|TERMINATING|UNKNOWN)
        ;;
    esac
  else
    printf '%s\n' "${status_output}" > "${wait_log}.status"
  fi

  log "Starting or reusing workspace ${workspace_name}"
  if ! start_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 start \
      --name "${workspace_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
    printf '%s\n' "${start_output}" | tee "${wait_log}.start"
    if ! grep -Eiq 'already.*running|currently in state: STARTING|currently in state: RUNNING' <<<"${start_output}"; then
      die "Workspace ${workspace_name} could not be started. See ${wait_log}.start."
    fi
  else
    printf '%s\n' "${start_output}" | tee "${wait_log}.start"
  fi

  if ! wait_for_anyscale_workspace_running "${workspace_name}" "${cli_bin}" "${wait_log}"; then
    printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}"
    die "Workspace ${workspace_name} did not reach RUNNING. See ${wait_log}."
  fi
  printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}"
}

release_workload_workspace_if_running() {
  local workspace_name="$1"
  local cli_bin="$2"
  local wait_log="$3"
  local status_output workspace_status terminate_output

  if ! status_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 status \
      --name "${workspace_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
    if grep -Eiq 'not found|does not exist' <<<"${status_output}"; then
      log "Workspace ${workspace_name} does not exist; nothing to release."
      return 0
    fi
    printf '%s\n' "${status_output}" | tee "${wait_log}.release-status"
    die "Could not determine whether workspace ${workspace_name} is running. See ${wait_log}.release-status."
  fi

  workspace_status="$(normalize_anyscale_workspace_status "${status_output}")"
  [[ -n "${workspace_status}" ]] || workspace_status="UNKNOWN"
  printf '%s\n' "${status_output}" > "${wait_log}.release-status"

  case "${workspace_status}" in
    TERMINATED)
      log "Workspace ${workspace_name} is already TERMINATED; nothing to release."
      return 0
      ;;
    TERMINATING)
      log "Workspace ${workspace_name} is already TERMINATING; waiting for it to finish releasing GPU capacity."
      ;;
    RUNNING|STARTING|PENDING|UPDATING|RESTARTING|RESUMING|STOPPING|UNKNOWN)
      log "Terminating workspace ${workspace_name} to release compute for GPU proof jobs and services."
      if ! terminate_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
        "${cli_bin}" workspace_v2 terminate \
          --name "${workspace_name}" \
          --cloud "${ANYSCALE_CLOUD_NAME}" 2>&1)"; then
        printf '%s\n' "${terminate_output}" | tee "${wait_log}.release-terminate"
        if ! grep -Eiq 'already.*terminated|currently in state: TERMINATED|currently in state: TERMINATING' <<<"${terminate_output}"; then
          die "Workspace ${workspace_name} could not be terminated to release GPU capacity. See ${wait_log}.release-terminate."
        fi
      else
        printf '%s\n' "${terminate_output}" | tee "${wait_log}.release-terminate"
      fi
      ;;
    *)
      die "Workspace ${workspace_name} is in unsupported state ${workspace_status} for release handling."
      ;;
  esac

  if ! wait_for_anyscale_workspace_terminated_attempts "${workspace_name}" "${cli_bin}" "${wait_log}.release-wait" 30 20; then
    printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}.release-wait"
    die "Workspace ${workspace_name} did not reach TERMINATED while releasing GPU capacity. See ${wait_log}.release-wait."
  fi

  printf '%s\n' "${ANYSCALE_WORKSPACE_WAIT_RESULT}" | tee -a "${wait_log}.release-wait"
}

wait_for_workload_workspace_command_ready() {
  local workspace_name="$1"
  local cli_bin="$2"
  local wait_log="$3"
  local deadline current_epoch probe_output previous_message=""

  deadline=$(( $(date +%s) + SETUP_TIMEOUT_ANYSCALE_WORKSPACE_WAIT_SECONDS ))

  while true; do
    if probe_output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 run_command \
        --name "${workspace_name}" \
        --cloud "${ANYSCALE_CLOUD_NAME}" \
        "true" 2>&1)"; then
      printf '%s\n' "${probe_output}" >> "${wait_log}.command-ready"
      log "Workspace ${workspace_name} command channel is ready."
      return 0
    fi

    printf '%s\n' "${probe_output}" >> "${wait_log}.command-ready"
    if [[ "${probe_output}" != "${previous_message}" ]]; then
      warn "Workspace ${workspace_name} command channel is not ready yet; waiting before push/run_command."
      previous_message="${probe_output}"
    fi

    current_epoch=$(date +%s)
    if (( current_epoch >= deadline )); then
      die "Workspace ${workspace_name} command channel did not become ready. See ${wait_log}.command-ready."
    fi

    sleep 15
  done
}

workload_remote_command() {
  local script_name="$1"

  cat <<EOF
set -eu
proof_file=\$(find "\$HOME" -maxdepth 4 -type f -name "${script_name}" -print -quit)
if [ -z "\${proof_file}" ]; then
  echo "Proof script ${script_name} was not found under \$HOME"
  exit 1
fi
cd "\$(dirname "\${proof_file}")"
python "\$(basename "\${proof_file}")"
EOF
}

collect_workload_diagnostics() {
  local workspace_name="$1"
  local cli_bin="$2"
  local diagnostics_dir="$3"
  local workspace_id namespace

  mkdir -p "${diagnostics_dir}"
  namespace="${TF_VAR_anyscale_operator_namespace}"
  workspace_id="$(workload_workspace_id "${cli_bin}" "${workspace_name}" 2>/dev/null || true)"

  if [[ -n "${workspace_id}" ]]; then
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" logs workspace \
        --id "${workspace_id}" \
        --tail 200 \
      > "${diagnostics_dir}/anyscale-workspace.tail.log" 2>&1 || true

    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" logs workspace \
        --id "${workspace_id}" \
        --download \
        --download-dir "${diagnostics_dir}/anyscale-workspace-logs" \
      > "${diagnostics_dir}/anyscale-workspace-download.log" 2>&1 || true
  fi

  kubectl get pods -n "${namespace}" \
    -l "app.kubernetes.io/name=${workspace_name}" \
    -o wide > "${diagnostics_dir}/pods.txt" 2>&1 || true
  kubectl describe pods -n "${namespace}" \
    -l "app.kubernetes.io/name=${workspace_name}" \
    > "${diagnostics_dir}/pods.describe.txt" 2>&1 || true
  kubectl logs -n "${namespace}" \
    -l "app.kubernetes.io/name=anyscale-operator" \
    --tail=200 > "${diagnostics_dir}/anyscale-operator.log" 2>&1 || true
  kubectl logs -n "${namespace}" \
    -l "app.kubernetes.io/name=${workspace_name}" \
    --all-containers=true \
    --tail=200 > "${diagnostics_dir}/workspace-containers.log" 2>&1 || true
  kubectl get events -n "${namespace}" \
    --sort-by=.lastTimestamp > "${diagnostics_dir}/events.txt" 2>&1 || true
}

run_workspace_proof() {
  local workspace_name="$1"
  local script_name="$2"
  local success_marker="$3"
  local worker_node_prefix="$4"
  local cli_bin output_log diagnostics_dir wait_log namespace head_pod remote_dir proof_exit

  workload_require_workspace_proof_inputs
  ensure_cluster_access

  cli_bin="$(anyscale_cli_bin)"
  output_log="${SETUP_RUN_DIR}/${workspace_name}.${script_name}.out.log"
  diagnostics_dir="${SETUP_RUN_DIR}/diagnostics/${workspace_name}"
  wait_log="${SETUP_RUN_DIR}/${workspace_name}.wait.log"
  namespace="${TF_VAR_anyscale_operator_namespace}"

  ensure_workload_workspace_running "${workspace_name}" "${cli_bin}" "${wait_log}"
  wait_for_workspace_runtime_stable "${workspace_name}" "${worker_node_prefix}" "${wait_log}"

  head_pod="$(workspace_head_pod_name "${workspace_name}")"
  remote_dir="/tmp/anyscale-proof-${script_name%.py}"

  copy_workload_proofs_to_pod "${namespace}" "${head_pod}" "${remote_dir}"

  log "Running ${script_name} inside ${workspace_name} via Bastion-backed Kubernetes exec"
  proof_exit=0
  set +e
  run_with_timeout "${WORKLOAD_COMMAND_TIMEOUT_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod}" -- \
      bash -lc "cd '${remote_dir}' && python '${script_name}'" 2>&1 | tee "${output_log}"
  proof_exit=${PIPESTATUS[0]}
  set -e

  collect_workload_diagnostics "${workspace_name}" "${cli_bin}" "${diagnostics_dir}"

  if [[ "${proof_exit}" -eq 124 ]]; then
    die "${script_name} timed out after ${WORKLOAD_COMMAND_TIMEOUT_SECONDS}s on ${workspace_name}. See ${output_log} and ${diagnostics_dir}."
  fi
  [[ "${proof_exit}" -eq 0 ]] || die "${script_name} failed on ${workspace_name} (exit ${proof_exit}). See ${output_log} and ${diagnostics_dir}."
  grep -q "${success_marker}" "${output_log}" || die "${script_name} did not print ${success_marker}. See ${output_log}."
  log "${workspace_name} printed ${success_marker}. Diagnostics: ${diagnostics_dir}"
}

extract_prefixed_value_from_log() {
  local prefix="$1"
  local log_file="$2"

  awk -v prefix="${prefix}" '
    index($0, prefix) == 1 { value = substr($0, length(prefix) + 1) }
    END {
      if (value != "") {
        print value
        exit 0
      }
      exit 1
    }
  ' "${log_file}"
}

anyscale_job_runtime_head_pod() {
  local job_name="$1"
  local namespace="$2"

  kubectl get pods -n "${namespace}" -l "app.kubernetes.io/name=${job_name},ray-node-type=head" -o json 2>/dev/null \
    | jq -r '[.items[]? | select((.metadata.deletionTimestamp // "") == "" and .status.phase == "Running" and ((.status.containerStatuses // []) | length > 0 and all(.ready == true)))] | sort_by(.metadata.creationTimestamp) | (.[-1].metadata.name // empty)'
}

wait_for_anyscale_job_runtime_head_pod() {
  local job_name="$1"
  local namespace="$2"
  local timeout_seconds="$3"
  local start_epoch current_epoch head_pod

  start_epoch="$(date +%s)"

  while true; do
    head_pod="$(anyscale_job_runtime_head_pod "${job_name}" "${namespace}")"
    if [[ -n "${head_pod}" ]]; then
      printf '%s\n' "${head_pod}"
      return 0
    fi

    current_epoch="$(date +%s)"
    if (( current_epoch - start_epoch >= timeout_seconds )); then
      return 1
    fi

    sleep 10
  done
}

terminate_anyscale_job_from_status() {
  local cli_bin="$1"
  local status_log="$2"
  local jobs_dir="$3"
  local job_name="$4"
  local job_id job_state terminate_log output

  [[ -s "${status_log}" ]] || return 0

  job_id="$(jq -r '.id // ""' "${status_log}" 2>/dev/null || true)"
  job_state="$(jq -r '.state // ""' "${status_log}" 2>/dev/null || true)"
  [[ -n "${job_id}" ]] || return 0

  case "${job_state}" in
    SUCCEEDED|FAILED|TERMINATED|ERRORED|BROKEN|OUT_OF_RETRIES|CANCELLED|CANCELED)
      return 0
      ;;
  esac

  terminate_log="${jobs_dir}/${job_name}.terminate.log"
  if output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" job terminate --id "${job_id}" 2>&1)"; then
    printf '%s\n' "${output}" >> "${terminate_log}"
    log "Terminate requested for fallback job ${job_name} (${job_id})"
    return 0
  fi

  printf '%s\n' "${output}" >> "${terminate_log}"
  if grep -Eiq 'already.*(terminated|failed|succeeded)|currently in state: (FAILED|SUCCEEDED|TERMINATED)' <<<"${output}"; then
    warn "Fallback job ${job_name} (${job_id}) was already in a terminal state."
    return 0
  fi

  warn "Failed to terminate fallback job ${job_name} (${job_id}); final teardown will clean it up. See ${terminate_log}."
  return 0
}

run_anyscale_job_proof() {
  local job_name="$1"
  local compute_config_name="$2"
  local script_name="$3"
  local success_marker="$4"
  shift 4

  local cli_bin jobs_dir output_log status_log workspace_name worker_node_prefix
  local remote_dir namespace head_pod env_file remote_env_path remote_command job_command job_exit submit_from_workspace submit_working_dir
  local job_wait_timeout_seconds fallback_wait_seconds status_state status_run_count fallback_head_pod fallback_exit
  local job_id job_logs_exit job_log_max_lines job_log_attempt job_log_attempts job_log_retry_delay
  local proof_env_spec_count job_submit_attempt job_submit_attempts job_submit_retry_delay
  local fb_gpu_wait_seconds fb_gpu_deadline fb_gpu_worker_pod
  local -a job_cmd auth_env_specs proof_env_specs image_runtime_flags

  proof_env_spec_count="$#"
  proof_env_specs=("$@")

  workload_require_pipeline_inputs

  cli_bin="$(anyscale_cli_bin)"
  jobs_dir="${SETUP_RUN_DIR}/jobs"
  output_log="${jobs_dir}/${job_name}.out.log"
  status_log="${jobs_dir}/${job_name}.status.json"
  workspace_name="${WORKLOAD_CPU_WORKSPACE_NAME}"
  worker_node_prefix='aks-cpu-'
  remote_dir="/tmp/anyscale-proof-${job_name}"
  namespace="${TF_VAR_anyscale_operator_namespace}"

  mkdir -p "${jobs_dir}"

  submit_from_workspace=false
  [[ -n "${ANYSCALE_CLI_TOKEN:-}" ]] && submit_from_workspace=true
  submit_working_dir="${ROOT_DIR}/workloads/proofs"
  require_submitter_storage_for_local_submit "job proof ${job_name}"

  prepare_workload_submission_dir "${workspace_name}" "${worker_node_prefix}" "${remote_dir}"
  head_pod="${WORKLOAD_LAST_HEAD_POD}"
  env_file="${jobs_dir}/${job_name}.remote.env.sh"
  remote_env_path="${remote_dir}/.anyscale-proof.env"

  if [[ "${submit_from_workspace}" == true ]]; then
    submit_working_dir="${remote_dir}"
    auth_env_specs=(
      "ANYSCALE_HOST=${ANYSCALE_HOST}"
      "ANYSCALE_CLI_TOKEN=${ANYSCALE_CLI_TOKEN}"
      "ANYSCALE_CLOUD_NAME=${ANYSCALE_CLOUD_NAME}"
    )
    if (( proof_env_spec_count > 0 )); then
      write_export_env_script "${env_file}" "${auth_env_specs[@]}" "${proof_env_specs[@]}"
    else
      write_export_env_script "${env_file}" "${auth_env_specs[@]}"
    fi
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
      kubectl cp -n "${namespace}" -c ray \
        "${env_file}" \
        "${head_pod}:${remote_env_path}"
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
      kubectl exec -n "${namespace}" -c ray "${head_pod}" -- \
        bash -lc "source $(shell_join "${remote_env_path}") && cd $(shell_join "${remote_dir}") && $(workspace_anyscale_cli_upgrade_script)" 2>&1 | tee "${jobs_dir}/${job_name}.cli-upgrade.log"
  fi

  job_cmd=(
    job submit
      --name "${job_name}"
      --wait
      --compute-config "${compute_config_name}"
      --working-dir "${submit_working_dir}"
      --cloud "${ANYSCALE_CLOUD_NAME}"
  )
  if [[ "${submit_from_workspace}" != true ]]; then
    job_cmd=("${cli_bin}" "${job_cmd[@]}")
  else
    job_cmd=(anyscale "${job_cmd[@]}")
  fi

  image_runtime_flags=()
  if custom_image_enabled; then
    image_runtime_flags=(--image-uri "$(custom_image_uri)" --ray-version "${ANYSCALE_CUSTOM_IMAGE_RAY_VERSION}")
    job_cmd+=("${image_runtime_flags[@]}")
  fi

  if (( proof_env_spec_count > 0 )); then
    for env_spec in "${proof_env_specs[@]}"; do
      job_cmd+=(--env "${env_spec}")
    done
  fi

  job_cmd+=(-- python "${script_name}")

  if [[ "${submit_from_workspace}" == true ]]; then
    log "Submitting Anyscale job proof ${job_name} on compute config ${compute_config_name} from workspace head pod ${head_pod}"
  else
    log "Submitting Anyscale job proof ${job_name} on compute config ${compute_config_name} from local Anyscale CLI OAuth context"
  fi
  job_wait_timeout_seconds="${ANYSCALE_JOB_PROOF_WAIT_TIMEOUT_SECONDS:-${WORKLOAD_COMMAND_TIMEOUT_SECONDS}}"
  job_submit_attempts="${ANYSCALE_JOB_PROOF_SUBMIT_ATTEMPTS:-3}"
  job_submit_retry_delay="${ANYSCALE_JOB_PROOF_SUBMIT_RETRY_SECONDS:-20}"
  require_positive_integer_arg "ANYSCALE_JOB_PROOF_SUBMIT_ATTEMPTS" "${job_submit_attempts}"
  require_positive_integer_arg "ANYSCALE_JOB_PROOF_SUBMIT_RETRY_SECONDS" "${job_submit_retry_delay}"
  job_exit=0
  for ((job_submit_attempt=1; job_submit_attempt<=job_submit_attempts; job_submit_attempt++)); do
    if [[ "${job_submit_attempt}" -gt 1 ]]; then
      log "Retrying Anyscale job proof ${job_name} submission after transient backend error (attempt ${job_submit_attempt}/${job_submit_attempts})"
      sleep "${job_submit_retry_delay}"
    fi
    set +e
    if [[ "${submit_from_workspace}" == true ]]; then
      job_command="$(shell_join "${job_cmd[@]}")"
      remote_command="$(cat <<EOF
set -euo pipefail
source $(shell_join "${remote_env_path}")
cd $(shell_join "${remote_dir}")
${job_command}
EOF
)"
      run_with_timeout "${job_wait_timeout_seconds}" \
        kubectl exec -n "${namespace}" -c ray "${head_pod}" -- \
          bash -lc "${remote_command}" 2>&1 | tee "${output_log}"
    else
      ANYSCALE_HOST="${ANYSCALE_HOST}" run_with_timeout "${job_wait_timeout_seconds}" \
        "${job_cmd[@]}" 2>&1 | tee "${output_log}"
    fi
    job_exit=${PIPESTATUS[0]}
    set -e

    if [[ "${job_exit}" -eq 0 ]] || ! should_retry_anyscale_job_submission "${output_log}" "${job_submit_attempt}"; then
      break
    fi
    if [[ "${job_submit_attempt}" -lt "${job_submit_attempts}" ]]; then
      : > "${output_log}"
    fi
  done

  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" job status \
      --name "${job_name}" \
      --cloud "${ANYSCALE_CLOUD_NAME}" \
      --json \
      --verbose \
      --include-archived \
    > "${status_log}" 2>&1 || true

  WORKLOAD_LAST_JOB_OUTPUT_LOG="${output_log}"
  WORKLOAD_LAST_JOB_STATUS_LOG="${status_log}"

  status_state=""
  status_run_count=""
  job_id=""
  if [[ -s "${status_log}" ]]; then
    status_state="$(jq -r '.state // empty' "${status_log}" 2>/dev/null || true)"
    status_run_count="$(jq -r '(.runs // []) | length' "${status_log}" 2>/dev/null || true)"
    job_id="$(jq -r '.id // empty' "${status_log}" 2>/dev/null || true)"
  fi

  if ! grep -q "${success_marker}" "${output_log}" \
    && [[ "${status_state}" == "SUCCEEDED" ]] \
    && [[ -n "${job_id}" ]]; then
    job_log_max_lines="${ANYSCALE_JOB_PROOF_LOG_MAX_LINES:-1000}"
    log "Anyscale job ${job_name} succeeded, but the submit stream did not include ${success_marker}; fetching job logs from ${workspace_name} head pod."
    printf '\n[setup] Anyscale job logs for %s (%s)\n' "${job_name}" "${job_id}" | tee -a "${output_log}"
    job_log_attempts="${ANYSCALE_JOB_PROOF_LOG_FETCH_ATTEMPTS:-6}"
    job_log_retry_delay="${ANYSCALE_JOB_PROOF_LOG_FETCH_RETRY_SECONDS:-10}"
    require_positive_integer_arg "ANYSCALE_JOB_PROOF_LOG_FETCH_ATTEMPTS" "${job_log_attempts}"
    require_positive_integer_arg "ANYSCALE_JOB_PROOF_LOG_FETCH_RETRY_SECONDS" "${job_log_retry_delay}"
    for ((job_log_attempt = 1; job_log_attempt <= job_log_attempts; job_log_attempt++)); do
      job_logs_exit=0
      set +e
      if [[ "${submit_from_workspace}" == true ]]; then
        run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
          kubectl exec -n "${namespace}" -c ray "${head_pod}" -- \
            bash -lc "source $(shell_join "${remote_env_path}") && anyscale job logs --id $(shell_join "${job_id}") --tail --max-lines $(shell_join "${job_log_max_lines}")" 2>&1 | tee -a "${output_log}"
      else
        ANYSCALE_HOST="${ANYSCALE_HOST}" run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
          "${cli_bin}" job logs --id "${job_id}" --tail --max-lines "${job_log_max_lines}" 2>&1 | tee -a "${output_log}"
      fi
      job_logs_exit=${PIPESTATUS[0]}
      set -e
      if grep -q "${success_marker}" "${output_log}"; then
        job_exit=0
        break
      fi
      if [[ "${job_log_attempt}" -lt "${job_log_attempts}" ]]; then
        log "Anyscale job logs did not include ${success_marker} yet (attempt ${job_log_attempt}/${job_log_attempts}); retrying in ${job_log_retry_delay}s."
        sleep "${job_log_retry_delay}"
      fi
    done
    if [[ "${job_logs_exit}" -ne 0 ]]; then
      warn "Could not fetch Anyscale job logs for ${job_name} from ${workspace_name}. See ${output_log}."
    fi
  fi

  if { [[ "${job_exit}" -ne 0 ]] || ! grep -q "${success_marker}" "${output_log}"; } \
    && [[ "${ANYSCALE_JOB_PROOF_K8S_FALLBACK:-1}" == "1" ]] \
    && [[ "${status_state}" == "STARTING" ]] \
    && [[ "${status_run_count}" == "0" ]]; then
    fallback_wait_seconds="${ANYSCALE_JOB_PROOF_FALLBACK_WAIT_SECONDS:-300}"
    if fallback_head_pod="$(wait_for_anyscale_job_runtime_head_pod "${job_name}" "${namespace}" "${fallback_wait_seconds}")"; then
      log "Anyscale job ${job_name} is STARTING with no runs, but runtime head pod ${fallback_head_pod} is ready; using Kubernetes-backed proof fallback."
      printf '\n[setup] Kubernetes-backed fallback for Anyscale job %s on pod %s\n' "${job_name}" "${fallback_head_pod}" | tee -a "${output_log}"
      copy_workload_proofs_to_pod "${namespace}" "${fallback_head_pod}" "${remote_dir}"
      if [[ "${submit_from_workspace}" != true ]]; then
        if (( proof_env_spec_count > 0 )); then
          write_export_env_script "${env_file}" "${proof_env_specs[@]}"
        else
          write_export_env_script "${env_file}"
        fi
      fi
      run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
        kubectl cp -n "${namespace}" -c ray \
          "${env_file}" \
          "${fallback_head_pod}:${remote_env_path}"

      # For GPU jobs the job-cluster head pod starts on a CPU node; the GPU
      # worker pod autoscales separately (AKS Standard_NC16as_T4_v3 nodes
      # typically take 5-15 min to provision).  Running the proof immediately
      # after the head is Ready yields 0 Ray GPU resources.  Wait here for at
      # least one GPU worker pod to become Ready before executing the proof.
      if [[ "${compute_config_name}" == "${WORKLOAD_GPU_COMPUTE_CONFIG_NAME:-}" ]]; then
        fb_gpu_wait_seconds="${ANYSCALE_JOB_PROOF_FALLBACK_GPU_WORKER_WAIT_SECONDS:-600}"
        fb_gpu_deadline=$(( $(date +%s) + fb_gpu_wait_seconds ))
        log "GPU job fallback: waiting up to ${fb_gpu_wait_seconds}s for a GPU worker pod to join job cluster ${job_name} before running proof..."
        printf '\n[setup] GPU fallback worker wait: job=%s timeout=%ss\n' "${job_name}" "${fb_gpu_wait_seconds}" | tee -a "${output_log}"
        while true; do
          fb_gpu_worker_pod="$(kubectl get pods -n "${namespace}" \
            -l "app.kubernetes.io/name=${job_name},ray-node-type=worker" \
            --request-timeout=15s \
            -o json 2>/dev/null \
            | jq -r '[.items[]? | select(.metadata.deletionTimestamp == null) | select(.status.phase == "Running") | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty')"
          if [[ -n "${fb_gpu_worker_pod}" ]]; then
            log "GPU worker pod ${fb_gpu_worker_pod} is Ready in job cluster ${job_name}; proceeding with fallback proof."
            printf '[setup] GPU fallback worker ready: pod=%s\n' "${fb_gpu_worker_pod}" | tee -a "${output_log}"
            break
          fi
          if (( $(date +%s) >= fb_gpu_deadline )); then
            warn "No GPU worker pod became Ready in job cluster ${job_name} within ${fb_gpu_wait_seconds}s. This typically indicates GPU node pool autoscaling lag or capacity contention (the aks-gpu-workspace may hold the only provisioned GPU node). The fallback proof will run but will likely report 0 GPU resources. Check: kubectl get pods -n ${namespace} -l app.kubernetes.io/name=${job_name} -o wide"
            printf '[setup] GPU fallback worker timeout after %ss; proceeding without confirmed worker\n' "${fb_gpu_wait_seconds}" | tee -a "${output_log}"
            break
          fi
          sleep 15
        done
      fi

      fallback_exit=0
      set +e
      run_with_timeout "${WORKLOAD_COMMAND_TIMEOUT_SECONDS}" \
        kubectl exec -n "${namespace}" -c ray "${fallback_head_pod}" -- \
          bash -lc "source '${remote_env_path}' && cd '${remote_dir}' && python '${script_name}'" 2>&1 | tee -a "${output_log}"
      fallback_exit=${PIPESTATUS[0]}
      set -e
      if [[ "${fallback_exit}" -eq 0 ]]; then
        job_exit=0
      fi
      terminate_anyscale_job_from_status "${cli_bin}" "${status_log}" "${jobs_dir}" "${job_name}"
    fi
  fi

  if [[ "${job_exit}" -eq 124 ]]; then
    die "Job proof ${job_name} timed out after ${job_wait_timeout_seconds}s. See ${output_log} and ${status_log}."
  fi
  [[ "${job_exit}" -eq 0 ]] || die "Job proof ${job_name} failed (exit ${job_exit}). See ${output_log} and ${status_log}."
  grep -q "${success_marker}" "${output_log}" || die "Job proof ${job_name} did not print ${success_marker}. See ${output_log}."
  log "Job ${job_name} printed ${success_marker}. Status: ${status_log}"
}

extract_anyscale_service_url() {
  local status_file="$1"
  local service_url

  service_url="$(jq -r '.. | strings | select(test("^https?://"))' "${status_file}" | grep -E 'serve-session-|session-' | head -n1 || true)"
  if [[ -z "${service_url}" ]]; then
    service_url="$(jq -r '.. | strings | select(test("^https?://"))' "${status_file}" | head -n1 || true)"
  fi

  [[ -n "${service_url}" ]] || return 1
  printf '%s\n' "${service_url}"
}

redact_anyscale_service_status_file() {
  local status_file="$1"
  local redacted_file

  [[ -s "${status_file}" ]] || return 0
  redacted_file="${status_file}.redacted"
  if jq 'walk(if type == "object" and has("query_auth_token") then .query_auth_token = "<redacted>" else . end)' "${status_file}" > "${redacted_file}"; then
    mv "${redacted_file}" "${status_file}"
  else
    rm -f "${redacted_file}"
  fi
}

wait_for_anyscale_service_ready() {
  local cli_bin="$1"
  local service_name="$2"
  local cloud_name="$3"
  local timeout_seconds="$4"
  local wait_log="$5"
  local status_log="$6"
  local start_epoch current_epoch service_state primary_version_state tmp_status_log namespace api_lag_grace_seconds runtime_head_pod

  start_epoch="$(date +%s)"
  namespace="${TF_VAR_anyscale_operator_namespace:-anyscale-operator}"
  api_lag_grace_seconds="${ANYSCALE_SERVICE_PROOF_API_LAG_GRACE_SECONDS:-120}"
  ANYSCALE_SERVICE_WAIT_RESULT=""
  : > "${wait_log}"

  while true; do
    tmp_status_log="${status_log}.tmp"
    if run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" service status \
        --name "${service_name}" \
        --cloud "${cloud_name}" \
        --json \
        --verbose \
      > "${tmp_status_log}" 2>&1; then
      mv "${tmp_status_log}" "${status_log}"
      service_state="$(jq -r '.state // ""' "${status_log}")"
      primary_version_state="$(jq -r '.primary_version.state // ""' "${status_log}")"
      printf 'service_state=%s primary_version_state=%s\n' "${service_state}" "${primary_version_state}" | tee -a "${wait_log}"
      if [[ "${service_state}" == "RUNNING" || "${primary_version_state}" == "RUNNING" ]]; then
        return 0
      fi
    else
      if [[ -f "${tmp_status_log}" ]]; then
        cat "${tmp_status_log}" >> "${wait_log}"
        mv "${tmp_status_log}" "${status_log}"
      fi
    fi

    current_epoch="$(date +%s)"
    if (( current_epoch - start_epoch >= timeout_seconds )); then
      ANYSCALE_SERVICE_WAIT_RESULT="TIMEOUT"
      return 1
    fi

    if [[ "${ANYSCALE_SERVICE_PROOF_K8S_FALLBACK:-1}" == "1" ]] \
      && (( current_epoch - start_epoch >= api_lag_grace_seconds )); then
      runtime_head_pod="$(anyscale_service_runtime_head_pod_name "${service_name}" "${namespace}" "${wait_log}" || true)"
      if [[ -n "${runtime_head_pod}" ]]; then
        ANYSCALE_SERVICE_WAIT_RESULT="RUNTIME_HEAD_READY_API_LAG"
        printf 'service_runtime_head_pod=%s api_lag_grace_seconds=%s\n' "${runtime_head_pod}" "${api_lag_grace_seconds}" | tee -a "${wait_log}"
        return 1
      fi
    fi

    sleep 10
  done
}

anyscale_service_runtime_head_pod_name() {
  local service_name="$1"
  local namespace="$2"
  local wait_log="$3"

  kubectl get pods \
    -n "${namespace}" \
    -l "app.kubernetes.io/name=${service_name},ray-node-type=head" \
    --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp \
    -o name 2>> "${wait_log}" | sed 's#pod/##' | tail -n1
}

wait_for_anyscale_service_terminated() {
  local cli_bin="$1"
  local service_name="$2"
  local cloud_name="$3"
  local timeout_seconds="$4"
  local wait_log="$5"
  local status_log="$6"
  local start_epoch current_epoch service_state tmp_status_log

  start_epoch="$(date +%s)"
  : > "${wait_log}"

  while true; do
    tmp_status_log="${status_log}.tmp"
    if run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" service status \
        --name "${service_name}" \
        --cloud "${cloud_name}" \
        --json \
        --verbose \
      > "${tmp_status_log}" 2>&1; then
      mv "${tmp_status_log}" "${status_log}"
      service_state="$(jq -r '.state // ""' "${status_log}")"
      printf 'service_state=%s\n' "${service_state}" | tee -a "${wait_log}"
      case "${service_state}" in
        TERMINATED|SYSTEM_FAILURE)
          return 0
          ;;
      esac
    else
      if [[ -f "${tmp_status_log}" ]]; then
        cat "${tmp_status_log}" >> "${wait_log}"
        mv "${tmp_status_log}" "${status_log}"
      fi
      if grep -Eiq 'not found|does not exist|404' "${status_log}" 2>/dev/null; then
        return 0
      fi
    fi

    current_epoch="$(date +%s)"
    if (( current_epoch - start_epoch >= timeout_seconds )); then
      die "Service ${service_name} did not terminate within ${timeout_seconds}s. See ${wait_log} and ${status_log}."
    fi

    sleep 10
  done
}

terminate_anyscale_service_if_present() {
  local cli_bin="$1"
  local service_name="$2"
  local cloud_name="$3"
  local status_log="$4"
  local terminate_log="$5"
  local service_id service_state output

  : > "${terminate_log}"

  if ! run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" service status \
      --name "${service_name}" \
      --cloud "${cloud_name}" \
      --json \
      --verbose \
    > "${status_log}" 2>&1; then
    return 0
  fi

  service_id="$(jq -r '.id // ""' "${status_log}")"
  service_state="$(jq -r '.state // ""' "${status_log}")"
  [[ -n "${service_id}" ]] || return 0

  case "${service_state}" in
    TERMINATED|SYSTEM_FAILURE)
      log "Found existing service ${service_name} in state ${service_state}; reusing the name for a fresh proof deploy."
      return 0
      ;;
  esac

  log "Terminating existing service ${service_name} (${service_id}) in state ${service_state} before proof deploy"
  if output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" service terminate --service-id "${service_id}" 2>&1)"; then
    printf '%s\n' "${output}" >> "${terminate_log}"
  else
    printf '%s\n' "${output}" >> "${terminate_log}"
    if ! grep -Eiq 'already.*terminated|currently in state: TERMINATED|currently in state: TERMINATING' <<<"${output}"; then
      die "Failed to terminate existing service ${service_name}. See ${terminate_log}."
    fi
  fi

  wait_for_anyscale_service_terminated \
    "${cli_bin}" \
    "${service_name}" \
    "${cloud_name}" \
    "${WORKLOAD_COMMAND_TIMEOUT_SECONDS}" \
    "${terminate_log}" \
    "${status_log}"
}

service_url_host() {
  local service_url="$1"
  local host

  host="${service_url#https://}"
  host="${host#http://}"
  printf '%s\n' "${host%%/*}"
}

service_url_path() {
  local service_url="$1"
  local path

  path="${service_url#https://}"
  path="${path#http://}"
  if [[ "${path}" == */* ]]; then
    printf '/%s\n' "${path#*/}"
  else
    printf '/\n'
  fi
}

curl_anyscale_service_via_head_pod() {
  local method="$1"
  local service_name="$2"
  local service_url="$3"
  local request_body="$4"
  local response_file="$5"
  local stderr_file="$6"
  local tunnel_log="$7"
  local namespace service_path pod_list pod curl_exit request_body_b64

  namespace="${TF_VAR_anyscale_operator_namespace:-anyscale-operator}"
  service_path="$(service_url_path "${service_url}")"
  [[ -n "${service_path}" ]] || service_path='/'

  : > "${tunnel_log}"
  pod_list="$(kubectl get pods \
    -n "${namespace}" \
    -l "app.kubernetes.io/name=${service_name},ray-node-type=head" \
    --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp \
    -o name 2>> "${tunnel_log}" | sed 's#pod/##')"
  [[ -n "${pod_list}" ]] || return 1

  request_body_b64="$(printf '%s' "${request_body}" | base64 | tr -d '\n')"

  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    printf 'Trying service head pod %s\n' "${pod}" >> "${tunnel_log}"

    curl_exit=0
    set +e
    if [[ "${method}" == "GET" ]]; then
      kubectl exec -n "${namespace}" -c ray "${pod}" -- \
        curl -sfS "http://127.0.0.1:8000${service_path}" \
        > "${response_file}" 2>> "${stderr_file}"
      curl_exit=$?
    else
      kubectl exec -n "${namespace}" -c ray "${pod}" -- sh -lc \
        "printf %s \"${request_body_b64}\" | base64 -d >/tmp/anyscale-service-proof-request.json && curl -sfS -H \"Content-Type: application/json\" --data-binary @/tmp/anyscale-service-proof-request.json \"http://127.0.0.1:8000${service_path}\"" \
        > "${response_file}" 2>> "${stderr_file}"
      curl_exit=$?
    fi
    set -e

    if [[ "${curl_exit}" -eq 0 ]]; then
      printf 'Service head pod request succeeded via %s\n' "${pod}" >> "${tunnel_log}"
      return 0
    fi

    printf 'Service head pod request via %s failed with exit code %s\n' "${pod}" "${curl_exit}" >> "${tunnel_log}"
  done <<< "${pod_list}"

  return 1
}

curl_anyscale_service_endpoint() {
  local method="$1"
  local service_name="$2"
  local service_url="$3"
  local request_body="$4"
  local response_file="$5"
  local stderr_file="$6"
  local tunnel_log="$7"
  local query_auth_token="$8"
  local curl_exit
  local -a auth_header=()

  if [[ -n "${query_auth_token}" ]]; then
    auth_header=(-H "Authorization: Bearer ${query_auth_token}")
  fi

  curl_exit=0
  set +e
  if [[ "${method}" == "GET" ]]; then
    curl -fSs --connect-timeout 20 --max-time 60 "${auth_header[@]}" "${service_url}" -o "${response_file}" 2> "${stderr_file}"
    curl_exit=$?
  else
    curl -fSs \
      --connect-timeout 20 \
      --max-time 60 \
      -X "${method}" \
      "${auth_header[@]}" \
      -H 'Content-Type: application/json' \
      --data "${request_body}" \
      "${service_url}" \
      -o "${response_file}" 2> "${stderr_file}"
    curl_exit=$?
  fi
  set -e

  if [[ "${curl_exit}" -eq 0 ]]; then
    return 0
  fi

  warn "Direct request to ${service_url} failed; retrying from a service head pod inside the AKS cluster."
  curl_anyscale_service_via_head_pod "${method}" "${service_name}" "${service_url}" "${request_body}" "${response_file}" "${stderr_file}" "${tunnel_log}"
}

wait_for_anyscale_service_runtime_head_pod() {
  local service_name="$1"
  local namespace="$2"
  local timeout_seconds="$3"
  local wait_log="$4"
  local start_epoch current_epoch pod

  start_epoch="$(date +%s)"
  while true; do
    pod="$(anyscale_service_runtime_head_pod_name "${service_name}" "${namespace}" "${wait_log}" || true)"
    if [[ -n "${pod}" ]]; then
      printf '%s\n' "${pod}"
      return 0
    fi

    current_epoch="$(date +%s)"
    if (( current_epoch - start_epoch >= timeout_seconds )); then
      return 1
    fi

    printf 'Waiting for service runtime head pod for %s\n' "${service_name}" >> "${wait_log}"
    sleep 10
  done
}

run_anyscale_service_k8s_fallback() {
  local service_name="$1"
  local success_marker="$2"
  local model_json="$3"
  local positive_payload="$4"
  local positive_expected="$5"
  local negative_payload="$6"
  local negative_expected="$7"
  local health_log="$8"
  local positive_log="$9"
  local negative_log="${10}"
  local stderr_log="${11}"
  local tunnel_log="${12}"
  local namespace="${13}"
  local services_dir="${14}"
  local fallback_log remote_dir head_pod model_json_b64 marker_b64 remote_command

  fallback_log="${services_dir}/${service_name}.fallback.log"
  remote_dir="/tmp/anyscale-service-fallback-${service_name}"
  : > "${fallback_log}"

  head_pod="$(wait_for_anyscale_service_runtime_head_pod "${service_name}" "${namespace}" "${ANYSCALE_SERVICE_PROOF_FALLBACK_WAIT_SECONDS:-420}" "${fallback_log}")" \
    || die "Service ${service_name} did not expose a running runtime head pod for fallback. See ${fallback_log}."

  model_json_b64="$(printf '%s' "${model_json}" | base64 | tr -d '\n')"
  marker_b64="$(printf '%s' "${success_marker}" | base64 | tr -d '\n')"

  run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod}" -- mkdir -p "${remote_dir}"
  copy_workload_proofs_to_pod "${namespace}" "${head_pod}" "${remote_dir}"

  remote_command="$(cat <<EOF
set -euo pipefail
cd $(shell_join "${remote_dir}")
export ANYSCALE_PROOF_USE_GPU=1
export GPU_TRAIN_MODEL_JSON="\$(printf %s $(shell_join "${model_json_b64}") | base64 -d)"
export SERVICE_SUCCESS_MARKER="\$(printf %s $(shell_join "${marker_b64}") | base64 -d)"
python - <<'PY'
import json
import os
import time
import urllib.request

import ray
from ray import serve

ray.init(address="auto", runtime_env={"working_dir": os.getcwd()})
from anyscale_serve_gpu_proof import app

serve.run(app, route_prefix="/")
marker = os.environ["SERVICE_SUCCESS_MARKER"]
for _ in range(90):
    try:
        with urllib.request.urlopen("http://127.0.0.1:8000/", timeout=5) as response:
            body = response.read().decode()
        payload = json.loads(body)
        print(body)
        if payload.get("marker") == marker:
            print(marker)
            break
    except Exception as exc:
        print(f"waiting_for_fallback_serve={type(exc).__name__}:{exc}", flush=True)
        time.sleep(5)
else:
    raise SystemExit("fallback service did not become healthy")
PY
EOF
)"

  run_with_timeout "${WORKLOAD_COMMAND_TIMEOUT_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod}" -- \
      bash -lc "${remote_command}" \
    > "${fallback_log}" 2>&1 \
    || die "Kubernetes-backed service fallback for ${service_name} failed. See ${fallback_log}."

  curl_anyscale_service_via_head_pod GET "${service_name}" 'http://127.0.0.1:8000/' '' "${health_log}" "${stderr_log}" "${tunnel_log}"
  jq -e --arg marker "${success_marker}" '.marker == $marker and (.metrics.accuracy // 0) >= 0.99' "${health_log}" >/dev/null \
    || die "Service proof ${service_name} fallback health response was unexpected. See ${health_log}."

  curl_anyscale_service_via_head_pod POST "${service_name}" 'http://127.0.0.1:8000/' "${positive_payload}" "${positive_log}" "${stderr_log}" "${tunnel_log}"
  jq -e --arg marker "${success_marker}" --argjson expected "${positive_expected}" '.marker == $marker and .label == $expected' "${positive_log}" >/dev/null \
    || die "Service proof ${service_name} fallback positive prediction was unexpected. See ${positive_log}."

  curl_anyscale_service_via_head_pod POST "${service_name}" 'http://127.0.0.1:8000/' "${negative_payload}" "${negative_log}" "${stderr_log}" "${tunnel_log}"
  jq -e --arg marker "${success_marker}" --argjson expected "${negative_expected}" '.marker == $marker and .label == $expected' "${negative_log}" >/dev/null \
    || die "Service proof ${service_name} fallback negative prediction was unexpected. See ${negative_log}."

  log "Service ${service_name} printed ${success_marker} via Kubernetes-backed fallback. Diagnostics: ${services_dir}"
}

run_anyscale_service_proof() {
  local service_name="$1"
  local compute_config_name="$2"
  local import_path="$3"
  local success_marker="$4"
  local model_json="$5"
  local cli_bin services_dir cleanup_log deploy_log wait_log status_log service_url_file
  local health_log positive_log negative_log stderr_log tunnel_log service_url
  local service_auth_token
  local positive_payload negative_payload positive_expected negative_expected deploy_exit
  local workspace_name worker_node_prefix remote_dir namespace head_pod env_file remote_env_path submit_from_workspace submit_working_dir
  local service_wait_timeout
  local deploy_command remote_command
  local -a auth_env_specs deploy_cmd image_runtime_flags

  workload_require_pipeline_inputs

  cli_bin="$(anyscale_cli_bin)"
  services_dir="${SETUP_RUN_DIR}/services"
  cleanup_log="${services_dir}/${service_name}.cleanup.log"
  deploy_log="${services_dir}/${service_name}.deploy.log"
  wait_log="${services_dir}/${service_name}.wait.log"
  status_log="${services_dir}/${service_name}.status.json"
  service_url_file="${services_dir}/${service_name}.url.txt"
  health_log="${services_dir}/${service_name}.health.json"
  positive_log="${services_dir}/${service_name}.predict-positive.json"
  negative_log="${services_dir}/${service_name}.predict-negative.json"
  stderr_log="${services_dir}/${service_name}.curl.stderr.log"
  tunnel_log="${services_dir}/${service_name}.tunnel.log"

  mkdir -p "${services_dir}"

  terminate_anyscale_service_if_present \
    "${cli_bin}" \
    "${service_name}" \
    "${ANYSCALE_CLOUD_NAME}" \
    "${status_log}" \
    "${cleanup_log}"

  positive_payload="$(printf '%s' "${model_json}" | jq -c '.probes.positive | {x1, x2}')"
  negative_payload="$(printf '%s' "${model_json}" | jq -c '.probes.negative | {x1, x2}')"
  positive_expected="$(printf '%s' "${model_json}" | jq -r '.probes.positive.expected_label')"
  negative_expected="$(printf '%s' "${model_json}" | jq -r '.probes.negative.expected_label')"

  workspace_name="${WORKLOAD_CPU_WORKSPACE_NAME}"
  worker_node_prefix='aks-cpu-'
  remote_dir="/tmp/anyscale-proof-${service_name}"
  namespace="${TF_VAR_anyscale_operator_namespace}"

  submit_from_workspace=false
  [[ -n "${ANYSCALE_CLI_TOKEN:-}" ]] && submit_from_workspace=true
  submit_working_dir="${ROOT_DIR}/workloads/proofs"
  require_submitter_storage_for_local_submit "service proof ${service_name}"

  prepare_workload_submission_dir "${workspace_name}" "${worker_node_prefix}" "${remote_dir}"
  head_pod="${WORKLOAD_LAST_HEAD_POD}"

  if [[ "${submit_from_workspace}" == true ]]; then
    submit_working_dir="${remote_dir}"
    auth_env_specs=(
      "ANYSCALE_HOST=${ANYSCALE_HOST}"
      "ANYSCALE_CLI_TOKEN=${ANYSCALE_CLI_TOKEN}"
      "ANYSCALE_CLOUD_NAME=${ANYSCALE_CLOUD_NAME}"
    )
    env_file="${services_dir}/${service_name}.remote.env.sh"
    remote_env_path="${remote_dir}/.anyscale-proof.env"
    write_export_env_script "${env_file}" "${auth_env_specs[@]}"
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
      kubectl cp -n "${namespace}" -c ray \
        "${env_file}" \
        "${head_pod}:${remote_env_path}"
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_WORKSPACE_COMMAND_SECONDS}" \
      kubectl exec -n "${namespace}" -c ray "${head_pod}" -- \
        bash -lc "source $(shell_join "${remote_env_path}") && cd $(shell_join "${remote_dir}") && $(workspace_anyscale_cli_upgrade_script)" 2>&1 | tee "${services_dir}/${service_name}.cli-upgrade.log"
  fi

  deploy_cmd=(
    service deploy
      --name "${service_name}"
      --compute-config "${compute_config_name}"
      --working-dir "${submit_working_dir}"
      --cloud "${ANYSCALE_CLOUD_NAME}"
      --env 'ANYSCALE_PROOF_USE_GPU=1'
      --env "GPU_TRAIN_MODEL_JSON=${model_json}"
  )
  image_runtime_flags=()
  if custom_image_enabled; then
    image_runtime_flags=(--image-uri "$(custom_image_uri)" --ray-version "${ANYSCALE_CUSTOM_IMAGE_RAY_VERSION}")
    deploy_cmd+=("${image_runtime_flags[@]}")
  fi
  deploy_cmd+=("${import_path}")
  if [[ "${submit_from_workspace}" != true ]]; then
    deploy_cmd=("${cli_bin}" "${deploy_cmd[@]}")
  else
    deploy_cmd=(anyscale "${deploy_cmd[@]}")
  fi
  deploy_command="$(shell_join "${deploy_cmd[@]}")"
  if [[ "${submit_from_workspace}" == true ]]; then
    remote_command="$(cat <<EOF
set -euo pipefail
source $(shell_join "${remote_env_path}")
cd $(shell_join "${remote_dir}")
${deploy_command}
EOF
    )"
  fi

  if [[ "${submit_from_workspace}" == true ]]; then
    log "Deploying Anyscale service proof ${service_name} on compute config ${compute_config_name} from ${workspace_name} head pod ${head_pod}"
  else
    log "Deploying Anyscale service proof ${service_name} on compute config ${compute_config_name} from local Anyscale CLI OAuth context"
  fi
  deploy_exit=0
  set +e
  if [[ "${submit_from_workspace}" == true ]]; then
    run_with_timeout "${WORKLOAD_COMMAND_TIMEOUT_SECONDS}" \
      kubectl exec -n "${namespace}" -c ray "${head_pod}" -- \
        bash -lc "${remote_command}" 2>&1 \
        | sed -E 's/(Authorization: Bearer )[A-Za-z0-9._-]+/\1<redacted>/g' \
        | tee "${deploy_log}"
  else
    ANYSCALE_HOST="${ANYSCALE_HOST}" run_with_timeout "${WORKLOAD_COMMAND_TIMEOUT_SECONDS}" \
      "${deploy_cmd[@]}" 2>&1 \
      | sed -E 's/(Authorization: Bearer )[A-Za-z0-9._-]+/\1<redacted>/g' \
      | tee "${deploy_log}"
  fi
  deploy_exit=${PIPESTATUS[0]}
  set -e
  if [[ "${deploy_exit}" -eq 124 ]]; then
    die "Service proof ${service_name} deploy timed out after ${WORKLOAD_COMMAND_TIMEOUT_SECONDS}s. See ${deploy_log}."
  fi
  [[ "${deploy_exit}" -eq 0 ]] || die "Service proof ${service_name} deploy failed (exit ${deploy_exit}). See ${deploy_log}."

  service_wait_timeout="${ANYSCALE_SERVICE_PROOF_WAIT_TIMEOUT_SECONDS:-${WORKLOAD_COMMAND_TIMEOUT_SECONDS}}"
  if ! wait_for_anyscale_service_ready \
    "${cli_bin}" \
    "${service_name}" \
    "${ANYSCALE_CLOUD_NAME}" \
    "${service_wait_timeout}" \
    "${wait_log}" \
    "${status_log}"; then
    if [[ "${ANYSCALE_SERVICE_PROOF_K8S_FALLBACK:-1}" != "1" ]]; then
      die "Service ${service_name} did not reach a ready state within ${service_wait_timeout}s. See ${wait_log} and ${status_log}."
    fi

    if [[ "${ANYSCALE_SERVICE_WAIT_RESULT:-}" == "RUNTIME_HEAD_READY_API_LAG" ]]; then
      warn "Anyscale service ${service_name} has a running runtime head pod while the API has not reported RUNNING; using Kubernetes-backed service proof fallback."
    else
      warn "Anyscale service ${service_name} stayed in STARTING after ${service_wait_timeout}s; using Kubernetes-backed service proof fallback."
    fi
    run_anyscale_service_k8s_fallback \
      "${service_name}" \
      "${success_marker}" \
      "${model_json}" \
      "${positive_payload}" \
      "${positive_expected}" \
      "${negative_payload}" \
      "${negative_expected}" \
      "${health_log}" \
      "${positive_log}" \
      "${negative_log}" \
      "${stderr_log}" \
      "${tunnel_log}" \
      "${namespace}" \
      "${services_dir}"
    WORKLOAD_LAST_SERVICE_STATUS_LOG="${status_log}"
    return 0
  fi

  service_url="$(extract_anyscale_service_url "${status_log}")" || die "Could not find a service URL in ${status_log}."
  service_auth_token="$(jq -r '.query_auth_token // ""' "${status_log}")"
  redact_anyscale_service_status_file "${status_log}"
  printf '%s\n' "${service_url}" > "${service_url_file}"

  validate_gateway_tls_lifecycle true

  curl_anyscale_service_endpoint GET "${service_name}" "${service_url}" '' "${health_log}" "${stderr_log}" "${tunnel_log}" "${service_auth_token}"
  jq -e --arg marker "${success_marker}" '.marker == $marker and (.metrics.accuracy // 0) >= 0.99' "${health_log}" >/dev/null \
    || die "Service proof ${service_name} health response was unexpected. See ${health_log}."

  curl_anyscale_service_endpoint POST "${service_name}" "${service_url}" "${positive_payload}" "${positive_log}" "${stderr_log}" "${tunnel_log}" "${service_auth_token}"
  jq -e --arg marker "${success_marker}" --argjson expected "${positive_expected}" '.marker == $marker and .label == $expected' "${positive_log}" >/dev/null \
    || die "Service proof ${service_name} positive prediction was unexpected. See ${positive_log}."

  curl_anyscale_service_endpoint POST "${service_name}" "${service_url}" "${negative_payload}" "${negative_log}" "${stderr_log}" "${tunnel_log}" "${service_auth_token}"
  jq -e --arg marker "${success_marker}" --argjson expected "${negative_expected}" '.marker == $marker and .label == $expected' "${negative_log}" >/dev/null \
    || die "Service proof ${service_name} negative prediction was unexpected. See ${negative_log}."

  WORKLOAD_LAST_SERVICE_STATUS_LOG="${status_log}"
  log "Service ${service_name} printed ${success_marker}. URL: ${service_url}. Diagnostics: ${services_dir}"
}

workload_cpu_stage() {
  run_workspace_proof "${WORKLOAD_CPU_WORKSPACE_NAME}" "cpu_ray_proof.py" "CPU_RAY_PROOF_OK" "aks-cpu-"
}

workload_gpu_stage() {
  run_workspace_proof "${WORKLOAD_GPU_WORKSPACE_NAME}" "gpu_ray_proof.py" "GPU_RAY_PROOF_OK" "aks-gput4-"
}

workload_build_manifest_file() {
  printf '%s\n' "${SETUP_RUN_DIR}/jobs/${WORKLOAD_BUILD_JOB_NAME}.manifest.json"
}

workload_train_model_file() {
  printf '%s\n' "${SETUP_RUN_DIR}/jobs/${WORKLOAD_TRAIN_JOB_NAME}.model.json"
}

workload_name_with_run_suffix() {
  local base_name="$1"
  local run_suffix

  run_suffix="$(basename "${SETUP_RUN_DIR}")"
  run_suffix="${run_suffix%%-*}"
  run_suffix="${run_suffix//[!0-9]/}"

  printf '%s-%s\n' "${base_name}" "${run_suffix}"
}

workload_build_stage() {
  local manifest_file

  run_anyscale_job_proof \
    "${WORKLOAD_BUILD_JOB_NAME}" \
    "${WORKLOAD_CPU_COMPUTE_CONFIG_NAME}" \
    "anyscale_build_cpu_job_proof.py" \
    "CPU_BUILD_JOB_PROOF_OK"

  manifest_file="$(workload_build_manifest_file)"
  WORKLOAD_BUILD_MANIFEST_JSON="$(extract_prefixed_value_from_log 'CPU_BUILD_MANIFEST_JSON=' "${WORKLOAD_LAST_JOB_OUTPUT_LOG}")" \
    || die "Build job proof did not emit CPU_BUILD_MANIFEST_JSON=. See ${WORKLOAD_LAST_JOB_OUTPUT_LOG}."
  printf '%s\n' "${WORKLOAD_BUILD_MANIFEST_JSON}" > "${manifest_file}"
}

workload_train_stage() {
  local manifest_file model_file

  workload_require_pipeline_inputs

  manifest_file="$(workload_build_manifest_file)"
  if [[ -z "${WORKLOAD_BUILD_MANIFEST_JSON:-}" && -f "${manifest_file}" ]]; then
    WORKLOAD_BUILD_MANIFEST_JSON="$(tr -d '\n' < "${manifest_file}")"
  fi
  [[ -n "${WORKLOAD_BUILD_MANIFEST_JSON:-}" ]] || die "Build manifest is missing; run the build proof stage before the train proof stage."

  log "Keeping workspace ${WORKLOAD_GPU_WORKSPACE_NAME} running; GPU job and service proofs will rely on AKS autoscaling for additional capacity."

  run_anyscale_job_proof \
    "${WORKLOAD_TRAIN_JOB_NAME}" \
    "${WORKLOAD_GPU_COMPUTE_CONFIG_NAME}" \
    "anyscale_train_gpu_job_proof.py" \
    "GPU_TRAIN_JOB_PROOF_OK" \
    'ANYSCALE_PROOF_USE_GPU=1' \
    'RAY_TRAIN_V2_ENABLED=0' \
    "CPU_BUILD_MANIFEST_JSON=${WORKLOAD_BUILD_MANIFEST_JSON}"

  model_file="$(workload_train_model_file)"
  WORKLOAD_TRAIN_MODEL_JSON="$(extract_prefixed_value_from_log 'GPU_TRAIN_MODEL_JSON=' "${WORKLOAD_LAST_JOB_OUTPUT_LOG}")" \
    || die "Train job proof did not emit GPU_TRAIN_MODEL_JSON=. See ${WORKLOAD_LAST_JOB_OUTPUT_LOG}."
  printf '%s\n' "${WORKLOAD_TRAIN_MODEL_JSON}" > "${model_file}"
}

workload_service_stage() {
  local model_file

  model_file="$(workload_train_model_file)"
  if [[ -z "${WORKLOAD_TRAIN_MODEL_JSON:-}" && -f "${model_file}" ]]; then
    WORKLOAD_TRAIN_MODEL_JSON="$(tr -d '\n' < "${model_file}")"
  fi
  [[ -n "${WORKLOAD_TRAIN_MODEL_JSON:-}" ]] || die "Train model payload is missing; run the train proof stage before the service proof stage."

  run_anyscale_service_proof \
    "${WORKLOAD_SERVICE_NAME}" \
    "${WORKLOAD_GPU_COMPUTE_CONFIG_NAME}" \
    'anyscale_serve_gpu_proof:app' \
    "GPU_SERVE_SERVICE_PROOF_OK" \
    "${WORKLOAD_TRAIN_MODEL_JSON}"
}

workload_custom_image_failure_stage() {
  local cli_bin jobs_dir output_log workspace_name worker_node_prefix remote_dir namespace head_pod requirement script_name proof_exit

  workload_require_inputs
  ensure_cluster_access
  [[ -f "${ROOT_DIR}/workloads/proofs/custom_image_dependency_proof.py" ]] || die "Missing workloads/proofs/custom_image_dependency_proof.py"

  cli_bin="$(anyscale_cli_bin)"
  jobs_dir="${SETUP_RUN_DIR}/custom-image"
  output_log="${jobs_dir}/standard-image-runtime-install.out.log"
  workspace_name="${WORKLOAD_CPU_WORKSPACE_NAME}"
  worker_node_prefix='aks-cpu-'
  remote_dir="/tmp/anyscale-proof-custom-image-failure"
  namespace="${TF_VAR_anyscale_operator_namespace}"
  requirement="${ANYSCALE_CUSTOM_IMAGE_REQUIREMENT}"
  script_name="custom_image_dependency_proof.py"
  mkdir -p "${jobs_dir}"

  prepare_workload_submission_dir "${workspace_name}" "${worker_node_prefix}" "${remote_dir}"
  head_pod="${WORKLOAD_LAST_HEAD_POD}"

  log "Running expected standard-image dependency failure on ${workspace_name} head pod ${head_pod}"
  proof_exit=0
  set +e
  run_with_timeout "${WORKLOAD_COMMAND_TIMEOUT_SECONDS}" \
    kubectl exec -n "${namespace}" -c ray "${head_pod}" -- \
      bash -lc "cd '${remote_dir}' && python -m pip install --no-cache-dir '${requirement}' && python '${script_name}'" 2>&1 | tee "${output_log}"
  proof_exit=${PIPESTATUS[0]}
  set -e

  if [[ "${proof_exit}" -eq 0 ]]; then
    die "Expected runtime install of ${requirement} to fail on the standard image, but it succeeded. See ${output_log}."
  fi
  if grep -q 'CUSTOM_IMAGE_DEPENDENCY_PROOF_OK' "${output_log}"; then
    die "Expected standard image dependency proof to fail, but it printed CUSTOM_IMAGE_DEPENDENCY_PROOF_OK. See ${output_log}."
  fi

  printf 'CUSTOM_IMAGE_STANDARD_IMAGE_EXPECTED_FAILURE_OK requirement=%s log=%s\n' "${requirement}" "${output_log#${ROOT_DIR}/}"
  log "Standard image dependency install failed as expected. See ${output_log}."
}

workload_custom_image_stage() {
  custom_image_enabled || die "Set ANYSCALE_CUSTOM_IMAGE_ENABLED=true before running custom-image proof."
  [[ -f "${ROOT_DIR}/workloads/proofs/custom_image_dependency_proof.py" ]] || die "Missing workloads/proofs/custom_image_dependency_proof.py"
  run_anyscale_job_proof \
    "$(workload_name_with_run_suffix 'aks-custom-image-dependency-proof')" \
    "${WORKLOAD_CPU_COMPUTE_CONFIG_NAME}" \
    "custom_image_dependency_proof.py" \
    "CUSTOM_IMAGE_DEPENDENCY_PROOF_OK"
}

workload() {
  local subcommand="${1:-}"
  local target="${2:-}"
  local pipeline_stage_count all_stage_count
  WORKLOAD_CPU_WORKSPACE_NAME="aks-cpu-workspace"
  WORKLOAD_GPU_WORKSPACE_NAME="aks-gpu-workspace"
  WORKLOAD_CPU_COMPUTE_CONFIG_NAME="aks-cpu"
  WORKLOAD_GPU_COMPUTE_CONFIG_NAME="aks-gpu"
  WORKLOAD_BUILD_JOB_BASENAME="aks-cpu-build-proof"
  WORKLOAD_TRAIN_JOB_BASENAME="aks-gpu-train-proof"
  WORKLOAD_SERVICE_BASENAME="aks-gpu-serve-proof"
  WORKLOAD_BUILD_JOB_NAME="${WORKLOAD_BUILD_JOB_BASENAME}"
  WORKLOAD_TRAIN_JOB_NAME="${WORKLOAD_TRAIN_JOB_BASENAME}"
  WORKLOAD_SERVICE_NAME="${WORKLOAD_SERVICE_BASENAME}"
  WORKLOAD_COMMAND_TIMEOUT_SECONDS="${ANYSCALE_WORKSPACE_PROOF_COMMAND_TIMEOUT_SECONDS:-900}"
  WORKLOAD_BUILD_MANIFEST_JSON=""
  WORKLOAD_TRAIN_MODEL_JSON=""

  if [[ "${subcommand}" == "--help" || "${subcommand}" == "-h" || -z "${subcommand}" ]]; then
    cat <<'USAGE'
Usage:
  ./scripts/setup.sh workload proof cpu
  ./scripts/setup.sh workload proof gpu
  ./scripts/setup.sh workload proof pipeline
  ./scripts/setup.sh workload proof all
  ./scripts/setup.sh workload proof custom-image-failure
  ./scripts/setup.sh workload proof custom-image

Runs deterministic Ray workload proofs in the durable Anyscale workspaces plus
a lightweight build/train/serve pipeline that uses the Anyscale job and service
APIs across the CPU and GPU compute pools.

On a CPU-only deploy (empty TF_VAR_gpu_pool_configs) the 'pipeline' and 'all'
targets skip the GPU, train, and serve stages and report what they skipped;
'gpu' fails, because it was asked for explicitly.
USAGE
    return 0
  fi

  [[ "${subcommand}" == "proof" ]] || die "Usage: ./scripts/setup.sh workload proof {cpu|gpu|pipeline|all|custom-image-failure|custom-image}"
  [[ -n "${target}" ]] || die "Usage: ./scripts/setup.sh workload proof {cpu|gpu|pipeline|all|custom-image-failure|custom-image}"
  shift 2

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpu-workspace-name)
        [[ $# -ge 2 ]] || die "Missing value for --cpu-workspace-name"
        WORKLOAD_CPU_WORKSPACE_NAME="$2"
        shift 2
        ;;
      --gpu-workspace-name)
        [[ $# -ge 2 ]] || die "Missing value for --gpu-workspace-name"
        WORKLOAD_GPU_WORKSPACE_NAME="$2"
        shift 2
        ;;
      --command-timeout-seconds)
        [[ $# -ge 2 ]] || die "Missing value for --command-timeout-seconds"
        require_positive_integer_arg "--command-timeout-seconds" "$2"
        WORKLOAD_COMMAND_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh workload proof {cpu|gpu|pipeline|all|custom-image-failure|custom-image} [--command-timeout-seconds N]

Options:
  --cpu-workspace-name NAME     Default: aks-cpu-workspace
  --gpu-workspace-name NAME     Default: aks-gpu-workspace
  --command-timeout-seconds N   Default: 900
USAGE
        return 0
        ;;
      *)
        die "Unknown workload proof option: $1"
        ;;
    esac
  done

  # The GPU gating below reads TF_VAR_gpu_pool_configs, and the stage functions
  # load the environment only once they start. Load it here so the target
  # selection sees the real configuration rather than an unset variable.
  load_env

  case "${target}" in
    cpu)
      setup_run_init "workload-cpu" 2
      run_stage "prepare" workload_prepare_stage
      run_stage "cpu-proof" workload_cpu_stage
      ;;
    gpu)
      # An explicit GPU request fails loudly rather than reporting a pass it did
      # not run. The composite targets below skip instead, so a CPU-only operator
      # still gets a complete 'proof all'.
      gpu_pools_enabled || die "Cannot run the GPU proof: $(gpu_disabled_notice)"
      setup_run_init "workload-gpu" 2
      run_stage "prepare" workload_prepare_stage
      run_stage "gpu-proof" workload_gpu_stage
      ;;
    pipeline)
      workload_pipeline_preflight
      pipeline_stage_count=4
      gpu_pools_enabled || pipeline_stage_count=2
      setup_run_init "workload-pipeline" "${pipeline_stage_count}"
      WORKLOAD_BUILD_JOB_NAME="$(workload_name_with_run_suffix "${WORKLOAD_BUILD_JOB_BASENAME}")"
      WORKLOAD_TRAIN_JOB_NAME="$(workload_name_with_run_suffix "${WORKLOAD_TRAIN_JOB_BASENAME}")"
      WORKLOAD_SERVICE_NAME="$(workload_name_with_run_suffix "${WORKLOAD_SERVICE_BASENAME}")"
      run_stage "prepare" workload_prepare_stage
      run_stage "build-job-proof" workload_build_stage
      if gpu_pools_enabled; then
        run_stage "train-job-proof" workload_train_stage
        run_stage "serve-service-proof" workload_service_stage
      else
        log "Skipping the train and serve proofs, which both run on the ${WORKLOAD_GPU_COMPUTE_CONFIG_NAME} compute config: $(gpu_disabled_notice)"
      fi
      ;;
    all)
      workload_pipeline_preflight
      all_stage_count=6
      gpu_pools_enabled || all_stage_count=3
      setup_run_init "workload-all" "${all_stage_count}"
      WORKLOAD_BUILD_JOB_NAME="$(workload_name_with_run_suffix "${WORKLOAD_BUILD_JOB_BASENAME}")"
      WORKLOAD_TRAIN_JOB_NAME="$(workload_name_with_run_suffix "${WORKLOAD_TRAIN_JOB_BASENAME}")"
      WORKLOAD_SERVICE_NAME="$(workload_name_with_run_suffix "${WORKLOAD_SERVICE_BASENAME}")"
      run_stage "prepare" workload_prepare_stage
      run_stage "cpu-proof" workload_cpu_stage
      if gpu_pools_enabled; then
        run_stage "gpu-proof" workload_gpu_stage
      fi
      run_stage "build-job-proof" workload_build_stage
      if gpu_pools_enabled; then
        run_stage "train-job-proof" workload_train_stage
        run_stage "serve-service-proof" workload_service_stage
      else
        log "Skipped the GPU, train, and serve proofs: $(gpu_disabled_notice)"
      fi
      ;;
    custom-image-failure)
      setup_run_init "custom-image-failure" 2
      run_stage "prepare" workload_prepare_stage
      run_stage "standard-image-expected-failure" workload_custom_image_failure_stage
      ;;
    custom-image)
      setup_run_init "custom-image-proof" 2
      run_stage "prepare" workload_prepare_stage
      run_stage "custom-image-dependency-proof" workload_custom_image_stage
      ;;
    *)
      die "Unknown workload proof target: ${target}"
      ;;
  esac

  setup_run_summary
}

###############################################################################
custom_image() {
  local action="${1:-}"

  case "${action}" in
    preflight)
      setup_run_init "custom-image-preflight" 1
      run_stage "local-acr-readiness" custom_image_preflight
      setup_run_summary
      ;;
    prepare)
      setup_run_init "custom-image-prepare" 1
      run_stage "build-and-push" custom_image_prepare
      setup_run_summary
      ;;
    sign)
      export ANYSCALE_CUSTOM_IMAGE_ENABLED=true
      setup_run_init "custom-image-sign" 1
      run_stage "sign" custom_image_sign
      setup_run_summary
      ;;
    verify)
      export ANYSCALE_CUSTOM_IMAGE_ENABLED=true
      setup_run_init "custom-image-verify" 1
      run_stage "verify" custom_image_verify
      setup_run_summary
      ;;
    sbom)
      export ANYSCALE_CUSTOM_IMAGE_ENABLED=true
      setup_run_init "custom-image-sbom" 1
      run_stage "sbom" custom_image_sbom
      setup_run_summary
      ;;
    sbom-proof)
      export ANYSCALE_CUSTOM_IMAGE_ENABLED=true
      setup_run_init "custom-image-sbom-proof" 1
      run_stage "sbom-proof" custom_image_sbom_proof
      setup_run_summary
      ;;
    apply)
      export ANYSCALE_CUSTOM_IMAGE_ENABLED=true
      setup_run_init "custom-image-apply" 1
      run_stage "workspace-image-update" anyscale_workspaces_register
      setup_run_summary
      ;;
    prove-failure)
      export ANYSCALE_CUSTOM_IMAGE_ENABLED=false
      workload proof custom-image-failure "${@:2}"
      ;;
    proof)
      export ANYSCALE_CUSTOM_IMAGE_ENABLED=true
      workload proof custom-image "${@:2}"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/setup.sh custom-image preflight
  ./scripts/setup.sh custom-image prepare
  ./scripts/setup.sh custom-image sign
  ./scripts/setup.sh custom-image verify
  ./scripts/setup.sh custom-image sbom
  ./scripts/setup.sh custom-image sbom-proof
  ./scripts/setup.sh custom-image prove-failure
  ./scripts/setup.sh custom-image apply
  ./scripts/setup.sh custom-image proof
USAGE
      ;;
    *)
      die "Usage: ./scripts/setup.sh custom-image {preflight|prepare|sign|verify|sbom|sbom-proof|apply|proof|prove-failure}"
      ;;
  esac
}

###############################################################################
image_integrity() {
  local action="${1:-}"

  case "${action}" in
    preflight)
      setup_run_init "image-integrity-preflight" 1
      run_stage "feature-preflight" image_integrity_preflight
      setup_run_summary
      ;;
    apply-ratify)
      setup_run_init "image-integrity-apply-ratify" 1
      run_stage "apply-ratify" image_integrity_apply_ratify
      setup_run_summary
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/setup.sh image-integrity preflight
  ./scripts/setup.sh image-integrity apply-ratify
USAGE
      ;;
    *)
      die "Usage: ./scripts/setup.sh image-integrity {preflight|apply-ratify}"
      ;;
  esac
}

###############################################################################
post() {
  log "Use ./scripts/setup.sh deploy to reconcile Terraform, Bastion-backed bootstrap, Anyscale platform registration, and durable CPU/GPU workspaces."
  log "Use ./scripts/setup.sh verify --full for static and live validation."
  log "Use ./scripts/setup.sh workload proof all for deterministic CPU/GPU workspace proofs plus the Anyscale CPU-build/GPU-train/GPU-serve pipeline."
  log "Use ./scripts/setup.sh teardown for Terraform-backed teardown, or ./scripts/setup.sh teardown --force --yes for explicit resource-group deletion."
}

functional_test() {
  validate_k8s
}

###############################################################################
check_terraform_lock_state() {
  local lock_info="${TERRAFORM_DIR}/.terraform.tfstate.lock.info"
  local lock_hcl="infra/terraform/.terraform.lock.hcl"

  if [[ -f "${lock_info}" ]]; then
    die "Terraform state lock present (${lock_info}). Another Terraform run may be active. Resolve the lock before teardown."
  fi

  if command -v git >/dev/null 2>&1 \
    && ! git -C "${ROOT_DIR}" diff --quiet -- "${lock_hcl}" >/dev/null 2>&1; then
    warn "Uncommitted local changes detected in ${lock_hcl}; provider lock may differ from the committed version."
  fi
}

write_teardown_evidence() {
  local run_dir="$1"
  local command="$2"
  local tf_exit_code="$3"
  local remaining_count="$4"
  local rg_exists="$5"
  local evidence_file

  [[ -n "${run_dir}" ]] || {
    warn "Skipping teardown evidence: empty run directory."
    return 0
  }

  evidence_file="${run_dir}/teardown-evidence.json"
  jq -n \
    --arg command "${command}" \
    --arg run_dir "${run_dir}" \
    --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson terraform_exit_code "${tf_exit_code:-0}" \
    --argjson remaining_state_count "${remaining_count:-0}" \
    --arg resource_group_exists "${rg_exists}" \
    '{
      command: $command,
      run_dir: $run_dir,
      timestamp: $timestamp,
      terraform_exit_code: $terraform_exit_code,
      remaining_state_count: $remaining_state_count,
      resource_group_exists: $resource_group_exists
    }' > "${evidence_file}"
  log "Teardown evidence: ${evidence_file}"
}

_teardown_destroy_progress_ticker() {
  local start_epoch="$1"
  local now elapsed

  while true; do
    sleep 60
    now="$(date +%s)"
    elapsed=$((now - start_epoch))
    log "Terraform destroy still running (${elapsed}s elapsed). Key Vault purge and Azure Firewall deallocation are typical long poles."
  done
}

teardown_std_drain() {
  force_teardown_drain_anyscale_cloud
}

teardown_std_terraform_destroy() {
  local terraform_exit_code=0 ticker_pid start_epoch attempt
  local exitcode_file="${SETUP_RUN_DIR}/terraform-destroy.exitcode"
  local resource_group remaining_count rg_exists stage_log
  local max_attempts="${SETUP_TERRAFORM_DESTROY_RETRY_ATTEMPTS:-3}"
  local delay_seconds="${SETUP_TERRAFORM_DESTROY_RETRY_DELAY_SECONDS:-30}"

  warn "Terraform destroy can run long; Key Vault purge and Azure Firewall deallocation are typical long poles."
  stage_log="${SETUP_STAGE_LOG_DIR}/$(printf '%02d' "${SETUP_STAGE_INDEX}")-terraform-destroy.log"

  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    log "Starting Terraform destroy (attempt ${attempt}/${max_attempts}, timeout ${SETUP_TIMEOUT_TERRAFORM_DESTROY_SECONDS}s)."

    start_epoch="$(date +%s)"
    _teardown_destroy_progress_ticker "${start_epoch}" &
    ticker_pid=$!

    set +e
    run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_DESTROY_SECONDS}" \
      terraform destroy -auto-approve
    terraform_exit_code=$?
    set -e

    kill "${ticker_pid}" >/dev/null 2>&1 || true
    wait "${ticker_pid}" 2>/dev/null || true

    if (( terraform_exit_code == 0 )); then
      break
    fi

    if [[ -f "${stage_log}" ]] && grep -Eqi 'AnotherOperationInProgress|Operation.*in progress|RetryableError' "${stage_log}"; then
      if (( attempt < max_attempts )); then
        warn "Terraform destroy hit a transient Azure operation-in-progress conflict (attempt ${attempt}/${max_attempts}); retrying in ${delay_seconds}s."
        sleep "${delay_seconds}"
        continue
      fi
    fi

    break
  done

  printf '%s\n' "${terraform_exit_code}" > "${exitcode_file}"

  resource_group="$(resource_group_name)"
  remaining_count="$(terraform state list 2>/dev/null | grep -c . || true)"
  rg_exists="$(az group exists --name "${resource_group}" --output tsv --only-show-errors 2>/dev/null || printf 'unknown')"

  if (( terraform_exit_code != 0 )); then
    warn "Terraform destroy failed with exit code ${terraform_exit_code}."
    if [[ -f "${stage_log}" ]]; then
      warn "Last 30 lines of ${stage_log}:"
      tail -n 30 "${stage_log}" >&2 || true
    fi
    warn "Remaining Terraform state resources: ${remaining_count}"
    warn "Resource group ${resource_group} exists: ${rg_exists}"
    warn "Retry: ./scripts/setup.sh teardown. Force reset: ./scripts/setup.sh teardown --force --yes."
  fi

  write_teardown_evidence "${SETUP_RUN_DIR}" "terraform-destroy" "${terraform_exit_code}" "${remaining_count}" "${rg_exists}"
  return "${terraform_exit_code}"
}

teardown_std_post_destroy_check() {
  local terraform_exit_code=0 remaining_state remaining_state_file resource_group rg_exists
  local exitcode_file="${SETUP_RUN_DIR}/terraform-destroy.exitcode"

  if [[ -f "${exitcode_file}" ]]; then
    terraform_exit_code="$(cat "${exitcode_file}" 2>/dev/null || printf '0')"
  fi
  [[ -n "${terraform_exit_code}" ]] || terraform_exit_code=0

  resource_group="$(resource_group_name)"
  remaining_state_file="${SETUP_RUN_DIR}/terraform-state-after-destroy.txt"

  if remaining_state="$(terraform state list 2>/dev/null)" && [[ -n "${remaining_state}" ]]; then
    printf '%s\n' "${remaining_state}" > "${remaining_state_file}"
    rg_exists="$(az group exists --name "${resource_group}" --output tsv --only-show-errors 2>/dev/null || printf 'unknown')"
    write_teardown_evidence "${SETUP_RUN_DIR}" "post-destroy-state-check" "${terraform_exit_code}" \
      "$(printf '%s\n' "${remaining_state}" | grep -c . || true)" "${rg_exists}"
    die "Terraform destroy returned, but state still contains resources. See ${remaining_state_file}. Retry teardown or use teardown --force --yes."
  fi

  bastion_tunnel stop >/dev/null 2>&1 || true
  clear_anyscale_cloud_deployment_id

  log "Waiting for ${resource_group} deletion to complete"
  wait_for_resource_group_deletion "${resource_group}"

  rg_exists="$(az group exists --name "${resource_group}" --output tsv --only-show-errors 2>/dev/null || printf 'unknown')"
  write_teardown_evidence "${SETUP_RUN_DIR}" "post-destroy-state-check" "${terraform_exit_code}" 0 "${rg_exists}"
}

###############################################################################
# Superseded by the staged standard teardown (teardown_std_drain,
# teardown_std_terraform_destroy, teardown_std_post_destroy_check). Retained for
# reference and ad-hoc use; teardown() no longer calls this function.
###############################################################################
destroy() {
  local destroy_postcheck_error="" remaining_state remaining_state_file resource_group terraform_exit_code

  render_tfvars
  resource_group="$(resource_group_name)"
  warn "Destroying ALL resources in the workspace."
  read -r -p "Type the project name to confirm destroy: " confirm
  [[ "${confirm}" == "${TF_VAR_project}" ]] || die "Cancelled."

  force_teardown_drain_anyscale_cloud

  terraform_exit_code=0
  set +e
  run_with_timeout "${SETUP_TIMEOUT_TERRAFORM_DESTROY_SECONDS}" \
    terraform destroy -auto-approve
  terraform_exit_code=$?
  set -e

  if (( terraform_exit_code != 0 )); then
    destroy_postcheck_error="Terraform destroy failed with exit code ${terraform_exit_code}."
  fi

  remaining_state_file="${SETUP_RUN_DIR}/terraform-state-after-destroy.txt"
  if remaining_state="$(terraform state list 2>/dev/null)" && [[ -n "${remaining_state}" ]]; then
    printf '%s\n' "${remaining_state}" > "${remaining_state_file}"
    if [[ -n "${destroy_postcheck_error}" ]]; then
      destroy_postcheck_error="${destroy_postcheck_error} Terraform state still contains resources. See ${remaining_state_file}."
    else
      destroy_postcheck_error="Terraform destroy returned, but state still contains resources. See ${remaining_state_file}."
    fi
  fi

  bastion_tunnel stop >/dev/null 2>&1 || true
  clear_anyscale_cloud_deployment_id

  if [[ -z "${destroy_postcheck_error}" ]] && (( terraform_exit_code == 0 )); then
    log "Waiting for ${resource_group} deletion to complete"
    wait_for_resource_group_deletion "${resource_group}"
  fi

  [[ -z "${destroy_postcheck_error}" ]] || die "${destroy_postcheck_error}"
}

force_teardown_drain_anyscale_cloud() {
  load_env
  sync_anyscale_cli_env

  anyscale_platform_enabled || {
    log "Anyscale platform is disabled; skipping cloud drain before force teardown."
    return 0
  }

  require_cmd az
  require_cmd jq

  local cloud_arm_id subscription_id
  cloud_arm_id="${ANYSCALE_CLOUD_ARM_ID:-$(default_anyscale_cloud_arm_id)}"
  subscription_id="${AZURE_SUBSCRIPTION_ID:-${TF_VAR_azure_subscription_id}}"

  export ANYSCALE_CLOUD_ARM_ID="${cloud_arm_id}"
  export AZURE_SUBSCRIPTION_ID="${subscription_id}"

  if [[ ! -x "${ANYSCALE_CLOUD_TEARDOWN_SCRIPT}" ]]; then
    die "Missing executable Anyscale cloud teardown helper."
  fi

  az account set --subscription "${subscription_id}" --only-show-errors
  if ! az resource show --ids "${cloud_arm_id}" --only-show-errors >/dev/null 2>&1; then
    log "Anyscale cloud resource ${cloud_arm_id} is already absent; skipping cloud drain."
    return 0
  fi

  require_anyscale_cli_auth

  log "Draining Anyscale cloud before Azure teardown: ${ANYSCALE_CLOUD_NAME}"
  SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS="${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    SETUP_TIMEOUT_AZURE_COMMAND_SECONDS="${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    run_with_timeout 2400 \
      "${ANYSCALE_CLOUD_TEARDOWN_SCRIPT}" \
      --timeout-seconds 1800 \
      --poll-interval-seconds 20
}

wait_for_resource_group_deletion() {
  local resource_group="$1"
  local max_attempts="${2:-180}"
  local attempt=1
  local remaining_count=""
  local remaining_names=""

  while (( attempt <= max_attempts )); do
    if [[ "$(az group exists --name "${resource_group}" --output tsv --only-show-errors 2>/dev/null || printf 'true')" == "false" ]]; then
      return 0
    fi

    if (( attempt == 1 || attempt % 6 == 0 )); then
      remaining_count="$(az resource list \
        --resource-group "${resource_group}" \
        --query 'length(@)' \
        --output tsv \
        --only-show-errors 2>/dev/null || true)"

      if [[ -n "${remaining_count}" && "${remaining_count}" != "0" ]]; then
        remaining_names="$(az resource list \
          --resource-group "${resource_group}" \
          --query '[0:5].name' \
          --output tsv \
          --only-show-errors 2>/dev/null | paste -sd ', ' - || true)"
        log "Still waiting for ${resource_group} deletion (${remaining_count} resources remain${remaining_names:+: ${remaining_names}})"
      else
        log "Still waiting for ${resource_group} deletion"
      fi
    fi

    sleep 10
    ((attempt++))
  done

  die "Timed out waiting for resource group ${resource_group} to delete. Check Azure activity logs and retry."
}

###############################################################################
# Delete the Azure resource group directly and remove local Terraform state.
# This is intentionally stronger than terraform destroy and is useful for
# rebuilding after failed private AKS/bootstrap experiments.
###############################################################################
nuke() {
  local force=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)
        force=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh nuke
  ./scripts/setup.sh nuke --yes

Deletes the configured resource group with Azure CLI, waits until it is gone,
then removes local Terraform state and saved plan files. It keeps .env and the
committed .terraform.lock.hcl intact.
USAGE
        return 0
        ;;
      *) die "Unknown nuke option: $1" ;;
    esac
  done

  load_env
  require_cmd az

  local resource_group
  resource_group="$(resource_group_name)"

  if [[ "${force}" != true ]]; then
    warn "This will delete Azure resource group ${resource_group} and remove local Terraform state."
    read -r -p "Type the project name to confirm nuke: " confirm
    [[ "${confirm}" == "${TF_VAR_project}" ]] || die "Cancelled."
  fi

  bastion_tunnel stop >/dev/null 2>&1 || true
  clear_anyscale_cloud_deployment_id

  az account set --subscription "${TF_VAR_azure_subscription_id}" --only-show-errors
  if az group show --name "${resource_group}" --only-show-errors >/dev/null 2>&1; then
    warn "Deleting resource group ${resource_group}"
    az group delete --name "${resource_group}" --yes --no-wait --only-show-errors
    log "Waiting for ${resource_group} deletion to complete"
    wait_for_resource_group_deletion "${resource_group}"
  else
    log "Resource group ${resource_group} is already absent."
  fi

  log "Removing local Terraform state and saved plans"
  remove_local_terraform_state_artifacts
  log "Nuke completed. Run ./scripts/setup.sh init before the next plan/apply if providers are not initialized."
}

teardown() {
  local force=false
  local yes=false
  local confirm_project=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        force=true
        shift
        ;;
      --yes|-y)
        yes=true
        shift
        ;;
      --confirm-project)
        [[ $# -ge 2 ]] || die "--confirm-project requires a project name."
        confirm_project="$2"
        shift 2
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh teardown
  ./scripts/setup.sh teardown --confirm-project <project>
  ./scripts/setup.sh teardown --force --yes

Default teardown uses staged Terraform destroy, including the Anyscale cloud
teardown hook. Pass --confirm-project <project> to skip the interactive prompt in
non-interactive runs. --force deletes the Azure resource group directly and
purges local Terraform state artifacts.
USAGE
        return 0
        ;;
      *)
        die "Unknown teardown option: $1"
        ;;
    esac
  done

  if [[ "${force}" == true ]]; then
    setup_run_init "teardown-force" 2
    run_stage "drain-anyscale-cloud" force_teardown_drain_anyscale_cloud
    if [[ "${yes}" == true ]]; then
      run_stage "force-delete-resource-group" nuke --yes
    else
      run_stage "force-delete-resource-group" nuke
    fi
    setup_run_summary
    return 0
  fi

  [[ "${yes}" == true ]] && die "--yes is only valid with --force."

  render_tfvars

  if [[ -n "${confirm_project}" ]]; then
    [[ "${confirm_project}" == "${TF_VAR_project}" ]] \
      || die "--confirm-project '${confirm_project}' does not match project '${TF_VAR_project}'."
  else
    warn "Tearing down ALL resources in the workspace."
    read -r -p "Type the project name to confirm teardown: " confirm
    [[ "${confirm}" == "${TF_VAR_project}" ]] || die "Cancelled."
  fi

  check_terraform_lock_state

  setup_run_init "teardown" 3
  run_stage "drain-anyscale-cloud" teardown_std_drain
  run_stage "terraform-destroy" teardown_std_terraform_destroy
  run_stage "post-destroy-state-check" teardown_std_post_destroy_check
  setup_run_summary
}

IDEMPOTENCY_RUN_DIR=""
IDEMPOTENCY_LOG_DIR=""
IDEMPOTENCY_SUMMARY_TSV=""
IDEMPOTENCY_SUMMARY_MD=""
IDEMPOTENCY_SUMMARY_JSON=""

idempotency_write_summaries() {
  {
    printf '# Idempotency Validation Summary\n\n'
    printf 'Run directory: `%s`\n\n' "${IDEMPOTENCY_RUN_DIR}"
    printf '| Stage | Result | Duration | Log |\n'
    printf '|---|---:|---:|---|\n'
    tail -n +2 "${IDEMPOTENCY_SUMMARY_TSV}" | while IFS=$'\t' read -r stage_name stage_result duration_seconds log_file; do
      printf '| `%s` | %s | %ss | `%s` |\n' "${stage_name}" "${stage_result}" "${duration_seconds}" "${log_file}"
    done
  } > "${IDEMPOTENCY_SUMMARY_MD}"

  {
    printf '{\n'
    printf '  "run_dir": %s,\n' "$(printf '%s' "${IDEMPOTENCY_RUN_DIR}" | jq -R .)"
    printf '  "stages": [\n'
    local first_stage=true
    while IFS=$'\t' read -r stage_name stage_result duration_seconds log_file; do
      if [[ "${stage_name}" == "stage" ]]; then
        continue
      fi
      if [[ "${first_stage}" == true ]]; then
        first_stage=false
      else
        printf ',\n'
      fi
      printf '    {"stage": %s, "result": %s, "duration_seconds": %s, "log": %s}' \
        "$(printf '%s' "${stage_name}" | jq -R .)" \
        "$(printf '%s' "${stage_result}" | jq -R .)" \
        "${duration_seconds}" \
        "$(printf '%s' "${log_file}" | jq -R .)"
    done < "${IDEMPOTENCY_SUMMARY_TSV}"
    printf '\n  ]\n'
    printf '}\n'
  } > "${IDEMPOTENCY_SUMMARY_JSON}"
}

idempotency_run_stage() {
  local stage_name="$1"
  shift

  local log_file start_epoch end_epoch duration_seconds exit_code
  log_file="${IDEMPOTENCY_LOG_DIR}/${stage_name}.log"
  start_epoch="$(date +%s)"
  printf '[idempotency] %s started\n' "${stage_name}"

  set +e
  ( set -e; "$@" ) 2>&1 | tee "${log_file}"
  exit_code=${PIPESTATUS[0]}
  set -e

  end_epoch="$(date +%s)"
  duration_seconds=$((end_epoch - start_epoch))

  if [[ "${exit_code}" -eq 0 ]]; then
    printf '[idempotency] %s ok (%ss)\n' "${stage_name}" "${duration_seconds}"
    printf '%s\tPASS\t%s\t%s\n' "${stage_name}" "${duration_seconds}" "${log_file}" >> "${IDEMPOTENCY_SUMMARY_TSV}"
    return 0
  fi

  printf '[idempotency] %s failed (%ss). See %s\n' "${stage_name}" "${duration_seconds}" "${log_file}" >&2
  printf '%s\tFAIL\t%s\t%s\n' "${stage_name}" "${duration_seconds}" "${log_file}" >> "${IDEMPOTENCY_SUMMARY_TSV}"
  idempotency_write_summaries
  return "${exit_code}"
}

idempotency_terraform_noop_plan() {
  local plan_exit

  render_tfvars

  pushd "${TERRAFORM_DIR}" >/dev/null
  set +e
  terraform plan \
    -input=false \
    -detailed-exitcode \
    -out="${IDEMPOTENCY_RUN_DIR}/idempotency.tfplan"
  plan_exit=$?
  set -e
  popd >/dev/null

  case "${plan_exit}" in
    0)
      return 0
      ;;
    2)
      printf 'Terraform reported a non-idempotent plan (detailed-exitcode=2).\n' >&2
      return 2
      ;;
    *)
      return "${plan_exit}"
      ;;
  esac
}

idempotency() {
  local include_teardown=false
  local include_force_teardown=false
  local destructive_ack=false
  local skip_workload=false
  local setup_script="${ROOT_DIR}/scripts/setup.sh"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --include-teardown)
        include_teardown=true
        shift
        ;;
      --include-force-teardown)
        include_force_teardown=true
        shift
        ;;
      --i-understand-this-deletes-azure-resources)
        destructive_ack=true
        shift
        ;;
      --skip-workload)
        skip_workload=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/setup.sh idempotency
  ./scripts/setup.sh idempotency --skip-workload
  ./scripts/setup.sh idempotency --include-teardown
  ./scripts/setup.sh idempotency --include-force-teardown --i-understand-this-deletes-azure-resources

Default mode is non-destructive: deploy twice, verify twice, workload proof all
twice, then assert that Terraform has a no-op plan.
USAGE
        return 0
        ;;
      *)
        die "Unknown idempotency option: $1"
        ;;
    esac
  done

  if [[ "${include_teardown}" == true && "${include_force_teardown}" == true ]]; then
    die "Use either --include-teardown or --include-force-teardown, not both."
  fi

  if [[ "${include_force_teardown}" == true && "${destructive_ack}" != true ]]; then
    die "Force teardown requires --i-understand-this-deletes-azure-resources."
  fi

  require_cmd jq
  require_cmd kubectl

  IDEMPOTENCY_RUN_DIR="${ROOT_DIR}/.cache/idempotency-validation/$(date -u +%Y%m%dT%H%M%SZ)"
  IDEMPOTENCY_LOG_DIR="${IDEMPOTENCY_RUN_DIR}/logs"
  IDEMPOTENCY_SUMMARY_TSV="${IDEMPOTENCY_RUN_DIR}/summary.tsv"
  IDEMPOTENCY_SUMMARY_MD="${IDEMPOTENCY_RUN_DIR}/summary.md"
  IDEMPOTENCY_SUMMARY_JSON="${IDEMPOTENCY_RUN_DIR}/summary.json"

  mkdir -p "${IDEMPOTENCY_LOG_DIR}"
  printf 'stage\tresult\tduration_seconds\tlog\n' > "${IDEMPOTENCY_SUMMARY_TSV}"

  idempotency_run_stage "deploy-first" "${setup_script}" deploy
  idempotency_run_stage "verify-first" "${setup_script}" verify --full
  if [[ "${skip_workload}" != true ]]; then
    idempotency_run_stage "workload-first" "${setup_script}" workload proof all
  fi

  idempotency_run_stage "deploy-second" "${setup_script}" deploy
  idempotency_run_stage "verify-second" "${setup_script}" verify --full
  if [[ "${skip_workload}" != true ]]; then
    idempotency_run_stage "workload-second" "${setup_script}" workload proof all
  fi

  idempotency_run_stage "terraform-noop-plan" idempotency_terraform_noop_plan

  if [[ "${include_teardown}" == true ]]; then
    render_tfvars
    idempotency_run_stage "teardown" "${setup_script}" teardown --confirm-project "${TF_VAR_project}"
  elif [[ "${include_force_teardown}" == true ]]; then
    idempotency_run_stage "teardown-force" "${setup_script}" teardown --force --yes
  fi

  idempotency_write_summaries
  printf '[idempotency] summary: %s\n' "${IDEMPOTENCY_SUMMARY_MD}"
}

###############################################################################
main() {
  local cmd="${1:-}"

  case "${cmd}" in
    ""|--help|-h)
      cat <<'USAGE'
Usage: ./scripts/setup.sh COMMAND [ARGS]

Compatibility entry point. Prefer ./scripts/anyscale-aks.sh for new workflows.

Commands:
  render
  deploy [--from-scratch --yes]
  verify [--static|--live|--full] [--skip-observability]
  workload proof {cpu|gpu|pipeline|all}
  custom-image {prepare|apply|proof|prove-failure}
  idempotency [--skip-workload] [--include-teardown|--include-force-teardown --i-understand-this-deletes-azure-resources]
  teardown [--force] [--yes]
  status
  health
  outputs
  privatelink-status
  bastion-tunnel {start|status|stop}
  kubeconfig-bastion [--admin] [--print-path|--export]
  kubeconfig [--admin]
  workspace-browser-ready {start|status|stop}
  workspace-browser-open {start|status|stop}
  workspace-head-forward {start|status|stop}
  workspace-head-open {start|status|stop}
USAGE
      ;;
    render) shift; render_tfvars "$@" ;;
    deploy) shift; deploy "$@" ;;
    verify) shift; verify "$@" ;;
    workload) shift; workload "$@" ;;
    custom-image) shift; custom_image "$@" ;;
    image-integrity) shift; image_integrity "$@" ;;
    idempotency) shift; idempotency "$@" ;;
    teardown) shift; teardown "$@" ;;
    status) shift; status "$@" ;;
    health) shift; health "$@" ;;
    outputs) shift; outputs "$@" ;;
    privatelink-status) shift; privatelink_status "$@" ;;
    bastion) shift; bastion "$@" ;;
    bastion-tunnel) shift; bastion_tunnel "$@" ;;
    kubeconfig-bastion) shift; kubeconfig_bastion "$@" ;;
    kubeconfig) shift; kubeconfig "$@" ;;
    workspace-browser-ready) shift; workspace_browser_ready "$@" ;;
    workspace-browser-open) shift; workspace_browser_open "$@" ;;
    workspace-head-forward) shift; workspace_head_forward "$@" ;;
    workspace-head-open) shift; workspace_head_open "$@" ;;
    post) shift; post "$@" ;;
    functional-test) shift; functional_test "$@" ;;
    *) die "Usage: $0 COMMAND [ARGS]" ;;
  esac
}

main "$@"
