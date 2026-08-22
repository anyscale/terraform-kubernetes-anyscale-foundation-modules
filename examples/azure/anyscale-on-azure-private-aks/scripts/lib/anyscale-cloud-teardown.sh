#!/usr/bin/env bash
# Drain Anyscale runtime objects before deleting the Azure cloud resource.
# This helper is used by teardown flows to make Azure cleanup more predictable.
# It writes local diagnostics under .cache for review after failures.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
CACHE_DIR="${ROOT_DIR}/.cache"

LOG_INFO_PREFIX="anyscale-cloud-teardown"
LOG_WARN_PREFIX="anyscale-cloud-teardown"
LOG_ERROR_PREFIX="anyscale-cloud-teardown"

# shellcheck source=./log.sh
source "${ROOT_DIR}/scripts/lib/log.sh"
# shellcheck source=./timeout.sh
source "${ROOT_DIR}/scripts/lib/timeout.sh"

DEFAULT_ANYSCALE_HOST="https://console.azure.anyscale.com"
DEFAULT_TIMEOUT_SECONDS=900
DEFAULT_POLL_INTERVAL_SECONDS=20
SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS="${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS:-180}"
SETUP_TIMEOUT_AZURE_COMMAND_SECONDS="${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS:-180}"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/lib/anyscale-cloud-teardown.sh [--timeout-seconds 900] [--poll-interval-seconds 20]

Internal helper for the established Anyscale-on-Azure destroy flow. The script
drains the current cloud's jobs, services, workspaces, and backing cluster
sessions before issuing the ARM delete for the Anyscale.Platform/clouds
resource.
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_env_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Required environment variable is missing: ${name}"
}

normalize_json_array_output() {
  local payload="$1"

  if [[ -z "${payload//[[:space:]]/}" ]]; then
    printf '[]\n'
    return 0
  fi

  printf '%s\n' "${payload}"
}

anyscale_cli_bin() {
  printf '%s\n' "${ROOT_DIR}/.venv/bin/anyscale"
}

anyscale_cli_auth_available() {
  local cli_bin
  [[ -n "${ANYSCALE_CLI_TOKEN:-}" ]] && return 0
  cli_bin="$(anyscale_cli_bin)"
  ANYSCALE_HOST="${ANYSCALE_HOST:-${DEFAULT_ANYSCALE_HOST}}" \
    "${cli_bin}" cloud list --max-items 1 --page-size 1 --no-interactive --json >/dev/null 2>&1
}

require_anyscale_cli_auth() {
  if anyscale_cli_auth_available; then
    return 0
  fi

  warn "Could not pre-confirm Anyscale CLI credentials. Continuing; if Anyscale commands fail, run: ANYSCALE_HOST=${DEFAULT_ANYSCALE_HOST} ${ROOT_DIR}/.venv/bin/anyscale login"
}

anyscale_python_bin() {
  printf '%s\n' "${ROOT_DIR}/.venv/bin/python"
}

load_env_defaults() {
  local existing_anyscale_host="${ANYSCALE_HOST:-}"
  local existing_anyscale_cloud_name="${ANYSCALE_CLOUD_NAME:-}"
  local existing_anyscale_cloud_arm_id="${ANYSCALE_CLOUD_ARM_ID:-}"
  local existing_subscription_id="${AZURE_SUBSCRIPTION_ID:-}"

  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    set +a
  fi

  [[ -n "${existing_anyscale_host}" ]] && export ANYSCALE_HOST="${existing_anyscale_host}"
  [[ -n "${existing_anyscale_cloud_name}" ]] && export ANYSCALE_CLOUD_NAME="${existing_anyscale_cloud_name}"
  [[ -n "${existing_anyscale_cloud_arm_id}" ]] && export ANYSCALE_CLOUD_ARM_ID="${existing_anyscale_cloud_arm_id}"
  [[ -n "${existing_subscription_id}" ]] && export AZURE_SUBSCRIPTION_ID="${existing_subscription_id}"

  if [[ -z "${ANYSCALE_CLI_TOKEN:-}" ]]; then
    unset ANYSCALE_CLI_TOKEN
  fi
  if [[ -z "${TF_VAR_anyscale_cli_token:-}" ]]; then
    unset TF_VAR_anyscale_cli_token
  fi

  if [[ -z "${ANYSCALE_HOST:-}" || "${ANYSCALE_HOST}" == "https://console.anyscale.com" ]]; then
    export ANYSCALE_HOST="${DEFAULT_ANYSCALE_HOST}"
  fi
}

list_clouds_json() {
  local cli_bin="$1"

  normalize_json_array_output "$({
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" cloud list -j --no-interactive --max-items 200
  })"
}

list_workspaces_json() {
  local cli_bin="$1"

  normalize_json_array_output "$({
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" workspace_v2 list \
        -j \
        --no-interactive \
        --include-archived \
        --max-items 500 \
        --cloud "${ANYSCALE_CLOUD_NAME}"
  })"
}

list_services_json() {
  local cli_bin="$1"

  normalize_json_array_output "$({
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" service list \
        --cloud "${ANYSCALE_CLOUD_NAME}" \
        --include-archived \
        -j \
        --no-interactive \
        --max-items 500
  })" | jq 'walk(if type == "object" and has("query_auth_token") then .query_auth_token = "<redacted>" else . end)'
}

list_jobs_json() {
  local cli_bin="$1"

  normalize_json_array_output "$({
    run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
      "${cli_bin}" job list \
        --v2 \
        --cloud "${ANYSCALE_CLOUD_NAME}" \
        --include-all-users \
        --include-archived \
        -j \
        --no-interactive \
        --max-items 500
  })"
}

cloud_exists_in_arm() {
  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az resource show --ids "${ANYSCALE_CLOUD_ARM_ID}" --only-show-errors >/dev/null 2>&1
}

arm_resource_exists() {
  local resource_id="$1"

  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az rest --method get --url "https://management.azure.com${resource_id}?api-version=2026-02-01-preview" --only-show-errors >/dev/null 2>&1
}

list_arm_child_ids() {
  local parent_id="$1"
  local child_type="$2"

  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az rest \
      --method get \
      --url "https://management.azure.com${parent_id}/${child_type}?api-version=2026-02-01-preview" \
      --query 'value[].id' \
      -o tsv \
      --only-show-errors 2>/dev/null || true
}

delete_arm_resource() {
  local resource_id="$1"
  local label="$2"
  # When tolerate_protected is "true", a persistent provider-protected response is
  # treated as non-fatal. The Anyscale resource provider protects several child
  # resources from direct ARM delete: the auto-created "default" project returns
  # 403/Bad Gateway, and compute configs return OperationNotAllowed ("deletion of
  # compute configs is not supported"). These are removed when the parent cloud is
  # deleted, so the child-cleanup pass must not abort on those responses.
  local tolerate_protected="${3:-false}"
  local output

  DELETE_ARM_RESOURCE_STATUS=""
  if ! arm_resource_exists "${resource_id}"; then
    DELETE_ARM_RESOURCE_STATUS="absent"
    return 0
  fi

  if output="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az rest --method delete --url "https://management.azure.com${resource_id}?api-version=2026-02-01-preview" --only-show-errors 2>&1)"; then
    DELETE_ARM_RESOURCE_STATUS="deleted"
    log "Azure delete requested for ${label} ${resource_id}"
    return 0
  fi

  printf '%s\n' "${output}"
  if grep -Eiq 'not found|404' <<<"${output}"; then
    DELETE_ARM_RESOURCE_STATUS="missing"
    warn "Azure reported ${label} ${resource_id} was already absent during delete."
    return 0
  fi

  if [[ "${tolerate_protected}" == "true" ]] && grep -Eiq 'forbidden|403|bad gateway|502|operationnotallowed|not supported|not allowed' <<<"${output}"; then
    DELETE_ARM_RESOURCE_STATUS="protected-tolerated"
    warn "Azure refused to delete ${label} ${resource_id} (provider-protected: 403/Bad Gateway/OperationNotAllowed). This resource is removed with the parent cloud; continuing."
    return 0
  fi

  die "Azure refused to delete ${label} ${resource_id}."
}

delete_arm_child_collection() {
  local parent_id="$1"
  local child_type="$2"
  local label="$3"
  local tolerate_protected="${4:-false}"
  local ids id remaining attempt max_attempts delete_count missing_count tolerated_count

  ids="$(list_arm_child_ids "${parent_id}" "${child_type}")"
  if [[ -z "${ids//[[:space:]]/}" ]]; then
    log "No ARM ${label} children found under ${parent_id}."
    return 0
  fi

  delete_count=0
  missing_count=0
  tolerated_count=0
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    delete_arm_resource "${id}" "${label}" "${tolerate_protected}"
    delete_count=$((delete_count + 1))
    if [[ "${DELETE_ARM_RESOURCE_STATUS}" == "missing" || "${DELETE_ARM_RESOURCE_STATUS}" == "absent" ]]; then
      missing_count=$((missing_count + 1))
    fi
    if [[ "${DELETE_ARM_RESOURCE_STATUS}" == "protected-tolerated" ]]; then
      tolerated_count=$((tolerated_count + 1))
    fi
  done <<<"${ids}"

  if [[ "${label}" == "project service" && "${delete_count}" -gt 0 && "${delete_count}" == "${missing_count}" ]]; then
    warn "ARM ${label} collection under ${parent_id} only contained stale rows that could not be deleted because the provider returned 404. Continuing to parent cleanup."
    return 0
  fi

  # Provider-protected children (e.g. compute configs) cannot be deleted directly
  # and persist until the parent cloud is removed, so do not wait for them to
  # disappear here.
  if [[ "${tolerate_protected}" == "true" && "${tolerated_count}" -gt 0 ]]; then
    warn "ARM ${label} children under ${parent_id} are provider-protected and remain until the parent cloud delete. Continuing to parent cleanup."
    return 0
  fi

  max_attempts=30
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    remaining="$(list_arm_child_ids "${parent_id}" "${child_type}")"
    if [[ -z "${remaining//[[:space:]]/}" ]]; then
      log "All ARM ${label} children under ${parent_id} were deleted."
      return 0
    fi
    sleep 10
  done

  printf '%s\n' "${remaining}"
  die "Timed out waiting for ARM ${label} children under ${parent_id} to delete."
}

delete_cloud_arm_children() {
  local project_ids project_id

  project_ids="$(list_arm_child_ids "${ANYSCALE_CLOUD_ARM_ID}" "projects")"
  while IFS= read -r project_id; do
    [[ -n "${project_id}" ]] || continue
    delete_arm_child_collection "${project_id}" "jobs" "project job"
    delete_arm_child_collection "${project_id}" "services" "project service"
    delete_arm_child_collection "${project_id}" "workspaces" "project workspace"
    # The auto-created "default" project is provider-protected: a direct ARM
    # delete returns 403/Bad Gateway even after its children are cleared. Tolerate
    # that response and let the parent-cloud delete remove it.
    if [[ "${project_id}" == *"/projects/default" ]]; then
      delete_arm_resource "${project_id}" "project" "true"
    else
      delete_arm_resource "${project_id}" "project"
    fi
  done <<<"${project_ids}"

  # Compute configs and container images are provider-protected metadata children
  # (the RP returns OperationNotAllowed/403 on direct delete); they are removed
  # with the parent cloud, so tolerate those responses here.
  delete_arm_child_collection "${ANYSCALE_CLOUD_ARM_ID}" "computeConfigs" "compute config" "true"
  delete_arm_child_collection "${ANYSCALE_CLOUD_ARM_ID}" "containerImages" "container image" "true"
  delete_arm_child_collection "${ANYSCALE_CLOUD_ARM_ID}" "cloudResources" "cloud resource"
}

default_cloud_resource_arm_id() {
  printf '%s/cloudResources/default\n' "${ANYSCALE_CLOUD_ARM_ID}"
}

default_cloud_resource_exists_in_arm() {
  local cloud_resource_arm_id
  cloud_resource_arm_id="$(default_cloud_resource_arm_id)"

  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az resource show --ids "${cloud_resource_arm_id}" --only-show-errors >/dev/null 2>&1
}

terminate_workspace() {
  local cli_bin="$1"
  local workspace_id="$2"
  local workspace_name="$3"
  local workspace_state="$4"
  local terminate_log="$5"
  local output

  if [[ "${workspace_state}" == "TERMINATED" ]]; then
    return 0
  fi

  if output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" workspace_v2 terminate --id "${workspace_id}" 2>&1)"; then
    printf '%s\n' "${output}" >> "${terminate_log}"
    log "Terminate requested for workspace ${workspace_name} (${workspace_id})"
    return 0
  fi

  printf '%s\n' "${output}" >> "${terminate_log}"
  if grep -Eiq 'already.*terminated|currently in state: TERMINATED|currently in state: TERMINATING' <<<"${output}"; then
    warn "Workspace ${workspace_name} (${workspace_id}) was already terminating or terminated."
    return 0
  fi

  warn "Workspace terminate request failed for ${workspace_name} (${workspace_id}); continuing to direct cluster termination and final state checks."
  return 0
}

terminate_service() {
  local cli_bin="$1"
  local service_id="$2"
  local service_name="$3"
  local service_state="$4"
  local terminate_log="$5"
  local output

  case "${service_state}" in
    TERMINATED|SYSTEM_FAILURE)
      return 0
      ;;
  esac

  if output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" service terminate --service-id "${service_id}" 2>&1)"; then
    printf '%s\n' "${output}" >> "${terminate_log}"
    log "Terminate requested for service ${service_name} (${service_id})"
    return 0
  fi

  printf '%s\n' "${output}" >> "${terminate_log}"
  if grep -Eiq 'already.*terminated|currently in state: TERMINATED|currently in state: TERMINATING' <<<"${output}"; then
    warn "Service ${service_name} (${service_id}) was already terminating or terminated."
    return 0
  fi

  warn "Service terminate request failed for ${service_name} (${service_id}); the final ARM delete will decide whether teardown can continue."
  return 0
}

terminate_job() {
  local cli_bin="$1"
  local job_id="$2"
  local job_name="$3"
  local job_state="$4"
  local terminate_log="$5"
  local output

  case "${job_state}" in
    SUCCEEDED|FAILED|TERMINATED|ERRORED|BROKEN|OUT_OF_RETRIES|CANCELLED|CANCELED)
      return 0
      ;;
  esac

  if output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${cli_bin}" job terminate --id "${job_id}" 2>&1)"; then
    printf '%s\n' "${output}" >> "${terminate_log}"
    log "Terminate requested for job ${job_name} (${job_id})"
    return 0
  fi

  printf '%s\n' "${output}" >> "${terminate_log}"
  if grep -Eiq 'already.*(terminated|failed|succeeded)|currently in state: (FAILED|SUCCEEDED|TERMINATED)' <<<"${output}"; then
    warn "Job ${job_name} (${job_id}) was already in a terminal state."
    return 0
  fi

  warn "Job terminate request failed for ${job_name} (${job_id}); the final ARM delete will decide whether teardown can continue."
  return 0
}

terminate_cluster_directly() {
  local python_bin="$1"
  local cluster_id="$2"
  local project_id="$3"
  local cluster_log="$4"
  local output

  [[ -n "${cluster_id}" && "${cluster_id}" != "null" ]] || return 0
  [[ -n "${project_id}" && "${project_id}" != "null" ]] || return 0

  if output="$(run_with_timeout "${SETUP_TIMEOUT_ANYSCALE_COMMAND_SECONDS}" \
    "${python_bin}" - "${cluster_id}" "${project_id}" 2>&1 <<'PY'
import sys

from anyscale.controllers.cluster_controller import ClusterController

cluster_id = sys.argv[1]
project_id = sys.argv[2]

ClusterController().terminate(
    cluster_name=None,
    cluster_id=cluster_id,
    project_id=project_id,
    project_name=None,
    cloud_id=None,
    cloud_name=None,
)

print(f"terminate requested for {cluster_id}")
PY
  )"; then
    printf '%s\n' "${output}" >> "${cluster_log}"
    log "Direct cluster terminate requested for ${cluster_id}"
    return 0
  fi

  printf '%s\n' "${output}" >> "${cluster_log}"
  warn "Direct cluster terminate request failed for ${cluster_id}; the final ARM delete will decide whether teardown can continue."
}

wait_for_cloud_workloads_drained() {
  local cli_bin="$1"
  local cloud_id="$2"
  local cloud_name="$3"
  local timeout_seconds="$4"
  local poll_interval_seconds="$5"
  local run_dir="$6"
  local deadline current_epoch workspaces_json services_json jobs_json
  local remaining_workspaces remaining_services remaining_jobs remaining_count summary

  deadline=$(( $(date +%s) + timeout_seconds ))

  while true; do
    workspaces_json="$(list_workspaces_json "${cli_bin}")"
    printf '%s\n' "${workspaces_json}" > "${run_dir}/workspaces.latest.json"
    services_json="$(list_services_json "${cli_bin}")"
    printf '%s\n' "${services_json}" > "${run_dir}/services.latest.json"
    jobs_json="$(list_jobs_json "${cli_bin}")"
    printf '%s\n' "${jobs_json}" > "${run_dir}/jobs.latest.json"

    remaining_workspaces="$(jq -c --arg cloud_id "${cloud_id}" '[.[] | select(.cloud_id == $cloud_id and (.state | ascii_upcase) != "TERMINATED")]' <<<"${workspaces_json}")"
    remaining_services="$(jq -c '[.[] | select(((.current_state // .state // .status // "") | ascii_upcase) as $state | ($state != "TERMINATED" and $state != "SYSTEM_FAILURE"))]' <<<"${services_json}")"
    remaining_jobs="$(jq -c '[.[] | select(((.state // .current_state // .status // "") | ascii_upcase) as $state | ($state != "SUCCEEDED" and $state != "FAILED" and $state != "TERMINATED" and $state != "ERRORED" and $state != "BROKEN" and $state != "OUT_OF_RETRIES" and $state != "CANCELLED" and $state != "CANCELED"))]' <<<"${jobs_json}")"
    remaining_count="$(( $(jq 'length' <<<"${remaining_workspaces}") + $(jq 'length' <<<"${remaining_services}") + $(jq 'length' <<<"${remaining_jobs}") ))"

    if [[ "${remaining_count}" == "0" ]]; then
      log "All current-cloud jobs, services, and workspaces reached terminal states before ARM delete."
      return 0
    fi

    summary="$({
      jq -r '.[] | "- workspace \(.name) (\(.id)) state=\(.state) cluster=\(.cluster_id // "n/a")"' <<<"${remaining_workspaces}"
      jq -r '.[] | "- service \(.name) (\(.id)) state=\(.current_state // .state // .status // "UNKNOWN") project=\(.project_id // "n/a")"' <<<"${remaining_services}"
      jq -r '.[] | "- job \(.name // .id) (\(.id)) state=\(.state // .current_state // .status // "UNKNOWN") project=\(.project_id // "n/a")"' <<<"${remaining_jobs}"
    } | sed '/^$/d')"
    warn "Waiting for current cloud workloads on ${cloud_name} to reach terminal states:"
    printf '%s\n' "${summary}"
    printf '%s\n' "${summary}" > "${run_dir}/workloads.remaining.txt"

    current_epoch="$(date +%s)"
    if (( current_epoch >= deadline )); then
      die "Timed out waiting for current cloud jobs, services, and workspaces to terminate. Inspect ${run_dir}/jobs.latest.json, ${run_dir}/services.latest.json, ${run_dir}/workspaces.latest.json, and ${run_dir}/workloads.remaining.txt before retrying destroy."
    fi

    sleep "${poll_interval_seconds}"
  done
}

delete_cloud_in_arm() {
  local run_dir="$1"
  local delete_log="${run_dir}/arm-delete.log"
  local output attempt max_attempts cloud_resource_arm_id

  cloud_resource_arm_id="$(default_cloud_resource_arm_id)"

  if default_cloud_resource_exists_in_arm; then
    if output="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
      az resource delete --ids "${cloud_resource_arm_id}" --only-show-errors 2>&1)"; then
      printf '%s\n' "${output}" > "${run_dir}/arm-delete-cloud-resource.log"
    else
      printf '%s\n' "${output}" > "${run_dir}/arm-delete-cloud-resource.log"
      die "Azure refused to delete nested cloud resource ${cloud_resource_arm_id}. See ${run_dir}/arm-delete-cloud-resource.log."
    fi

    max_attempts=30
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
      if ! default_cloud_resource_exists_in_arm; then
        log "Azure nested cloud resource ${cloud_resource_arm_id} was deleted before parent cloud removal."
        break
      fi
      sleep 10
    done

    if default_cloud_resource_exists_in_arm; then
      die "Azure accepted the delete for nested cloud resource ${cloud_resource_arm_id}, but it still exists after waiting. See ${run_dir}/arm-delete-cloud-resource.log."
    fi
  fi

  if ! cloud_exists_in_arm; then
    log "Azure resource ${ANYSCALE_CLOUD_ARM_ID} is already absent."
    return 0
  fi

  delete_cloud_arm_children

  if output="$(run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az resource delete --ids "${ANYSCALE_CLOUD_ARM_ID}" --only-show-errors 2>&1)"; then
    printf '%s\n' "${output}" > "${delete_log}"
  else
    printf '%s\n' "${output}" > "${delete_log}"
    die "Azure still refused to delete ${ANYSCALE_CLOUD_ARM_ID}. This helper runs before AKS teardown, so a failure here means the Anyscale control plane is still blocking cloud removal. See ${delete_log}."
  fi

  max_attempts=30
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ! cloud_exists_in_arm; then
      log "Azure resource ${ANYSCALE_CLOUD_ARM_ID} was deleted before Terraform continued."
      return 0
    fi
    sleep 10
  done

  die "Azure accepted the delete for ${ANYSCALE_CLOUD_ARM_ID}, but the resource still exists after waiting. See ${delete_log}."
}

main() {
  local timeout_seconds="${DEFAULT_TIMEOUT_SECONDS}"
  local poll_interval_seconds="${DEFAULT_POLL_INTERVAL_SECONDS}"
  local cli_bin python_bin run_id run_dir
  local clouds_json cloud_id services_json jobs_json workspaces_json
  local current_cloud_services current_cloud_jobs current_cloud_workspaces
  local service_count job_count workspace_count
  local service_json service_id service_name service_state
  local job_json job_id job_name job_state
  local workspace_json workspace_id workspace_name workspace_state cluster_id project_id

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout-seconds)
        timeout_seconds="$2"
        shift 2
        ;;
      --poll-interval-seconds)
        poll_interval_seconds="$2"
        shift 2
        ;;
      --help|-h)
        usage
        return 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  [[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || die "--timeout-seconds must be a positive integer."
  [[ "${poll_interval_seconds}" =~ ^[1-9][0-9]*$ ]] || die "--poll-interval-seconds must be a positive integer."

  load_env_defaults

  export ANYSCALE_HOST="${ANYSCALE_HOST:-${DEFAULT_ANYSCALE_HOST}}"

  require_cmd az
  require_cmd jq
  cli_bin="$(anyscale_cli_bin)"
  python_bin="$(anyscale_python_bin)"
  [[ -x "${cli_bin}" ]] || die "Missing repo-local Anyscale CLI: ${cli_bin}"
  [[ -x "${python_bin}" ]] || die "Missing repo-local Python: ${python_bin}"

  require_anyscale_cli_auth
  require_env_var ANYSCALE_CLOUD_NAME
  require_env_var ANYSCALE_CLOUD_ARM_ID
  require_env_var AZURE_SUBSCRIPTION_ID

  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  run_dir="${CACHE_DIR}/anyscale-cloud-teardown-${run_id}"
  mkdir -p "${run_dir}"

  log "Running Anyscale cloud teardown helper for ${ANYSCALE_CLOUD_NAME}"
  log "Artifacts will be written to ${run_dir}"

  run_with_timeout "${SETUP_TIMEOUT_AZURE_COMMAND_SECONDS}" \
    az account set --subscription "${AZURE_SUBSCRIPTION_ID}" --only-show-errors

  clouds_json="$(list_clouds_json "${cli_bin}")"
  printf '%s\n' "${clouds_json}" > "${run_dir}/clouds.json"
  cloud_id="$(jq -r --arg cloud_name "${ANYSCALE_CLOUD_NAME}" 'map(select(.name == $cloud_name)) | .[0].id // empty' <<<"${clouds_json}")"

  if [[ -z "${cloud_id}" ]]; then
    warn "Current cloud ${ANYSCALE_CLOUD_NAME} is not visible in the Anyscale cloud list. Falling back to direct ARM delete."
    delete_cloud_in_arm "${run_dir}"
    return 0
  fi

  log "Mapped ${ANYSCALE_CLOUD_NAME} to Anyscale cloud id ${cloud_id}"

  services_json="$(list_services_json "${cli_bin}")"
  printf '%s\n' "${services_json}" > "${run_dir}/services.before.json"
  current_cloud_services="${services_json}"
  service_count="$(jq 'length' <<<"${current_cloud_services}")"

  if [[ "${service_count}" == "0" ]]; then
    log "No current-cloud services were found for ${ANYSCALE_CLOUD_NAME}."
  else
    while IFS= read -r service_json; do
      [[ -n "${service_json}" ]] || continue
      service_id="$(jq -r '.id' <<<"${service_json}")"
      service_name="$(jq -r '.name' <<<"${service_json}")"
      service_state="$(jq -r '(.current_state // .state // .status // "UNKNOWN") | ascii_upcase' <<<"${service_json}")"

      terminate_service "${cli_bin}" "${service_id}" "${service_name}" "${service_state}" "${run_dir}/service-terminate.log"
    done < <(jq -c '.[]' <<<"${current_cloud_services}")
  fi

  jobs_json="$(list_jobs_json "${cli_bin}")"
  printf '%s\n' "${jobs_json}" > "${run_dir}/jobs.before.json"
  current_cloud_jobs="${jobs_json}"
  job_count="$(jq 'length' <<<"${current_cloud_jobs}")"

  if [[ "${job_count}" == "0" ]]; then
    log "No current-cloud jobs were found for ${ANYSCALE_CLOUD_NAME}."
  else
    while IFS= read -r job_json; do
      [[ -n "${job_json}" ]] || continue
      job_id="$(jq -r '.id' <<<"${job_json}")"
      job_name="$(jq -r '.name // .id' <<<"${job_json}")"
      job_state="$(jq -r '(.state // .current_state // .status // "UNKNOWN") | ascii_upcase' <<<"${job_json}")"

      terminate_job "${cli_bin}" "${job_id}" "${job_name}" "${job_state}" "${run_dir}/job-terminate.log"
    done < <(jq -c '.[]' <<<"${current_cloud_jobs}")
  fi

  workspaces_json="$(list_workspaces_json "${cli_bin}")"
  printf '%s\n' "${workspaces_json}" > "${run_dir}/workspaces.before.json"
  current_cloud_workspaces="$(jq -c --arg cloud_id "${cloud_id}" '[.[] | select(.cloud_id == $cloud_id)]' <<<"${workspaces_json}")"
  workspace_count="$(jq 'length' <<<"${current_cloud_workspaces}")"

  if [[ "${workspace_count}" == "0" ]]; then
    log "No current-cloud workspaces were found for ${cloud_id}."
  else
    while IFS= read -r workspace_json; do
      [[ -n "${workspace_json}" ]] || continue
      workspace_id="$(jq -r '.id' <<<"${workspace_json}")"
      workspace_name="$(jq -r '.name' <<<"${workspace_json}")"
      workspace_state="$(jq -r '.state' <<<"${workspace_json}")"
      cluster_id="$(jq -r '.cluster_id // empty' <<<"${workspace_json}")"
      project_id="$(jq -r '.project_id // empty' <<<"${workspace_json}")"

      terminate_workspace "${cli_bin}" "${workspace_id}" "${workspace_name}" "${workspace_state}" "${run_dir}/workspace-terminate.log"
      terminate_cluster_directly "${python_bin}" "${cluster_id}" "${project_id}" "${run_dir}/cluster-terminate.log"
    done < <(jq -c '.[]' <<<"${current_cloud_workspaces}")
  fi

  wait_for_cloud_workloads_drained "${cli_bin}" "${cloud_id}" "${ANYSCALE_CLOUD_NAME}" "${timeout_seconds}" "${poll_interval_seconds}" "${run_dir}"
  delete_cloud_in_arm "${run_dir}"

  if services_json="$(list_services_json "${cli_bin}" 2>/dev/null)"; then
    :
  else
    services_json='[]'
  fi
  printf '%s\n' "${services_json}" > "${run_dir}/services.after.json"
  if jobs_json="$(list_jobs_json "${cli_bin}" 2>/dev/null)"; then
    :
  else
    jobs_json='[]'
  fi
  printf '%s\n' "${jobs_json}" > "${run_dir}/jobs.after.json"
  workspaces_json="$(list_workspaces_json "${cli_bin}")"
  printf '%s\n' "${workspaces_json}" > "${run_dir}/workspaces.after.json"
  log "Anyscale cloud teardown helper completed successfully."
}

main "$@"