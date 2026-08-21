#!/usr/bin/env bash
# Public command dispatcher for the Anyscale-on-AKS sample.
# Keep this file focused on routing, help text, and read-only local checks.
# Core deploy, proof, and teardown behavior is delegated to setup.sh during the refactor.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/setup.sh"
DIAGNOSE_WORKSPACE_ARTIFACTS_SCRIPT="${SCRIPT_DIR}/utility/diagnose-workspace-artifacts.py"
TIMEOUT_SELF_TEST_SCRIPT="${SCRIPT_DIR}/utility/test-timeouts.sh"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"
MODULE_1_SCRIPT="${SCRIPT_DIR}/modules/module-1-foundation.sh"
MODULE_2_SCRIPT="${SCRIPT_DIR}/modules/module-2-jump-host.sh"
MODULE_3_SCRIPT="${SCRIPT_DIR}/modules/module-3-workload.sh"
MODULE_4_SCRIPT="${SCRIPT_DIR}/modules/module-4-custom-image.sh"
MODULE_5_SCRIPT="${SCRIPT_DIR}/modules/module-5-image-integrity.sh"
RESULTS_FILE="${ROOT_DIR}/RESULTS.md"

# shellcheck source=lib/vm-position.sh
source "${SCRIPT_DIR}/lib/vm-position.sh"

usage() {
  cat <<'USAGE'
Usage: ./scripts/anyscale-aks.sh COMMAND [ARGS]

Start here:
  init [--location LOCATION] [--project NAME] [--environment ENV]
       [--gpu|--no-gpu] [--force]
      Create .env from .env-template, filling subscription, tenant, region, and
      owner tags from your signed-in Azure context, and generate the jump-host
      SSH key if you do not have one. Enables GPU pools only when the
      subscription has T4 quota in the region. Run 'az login' first.

Learning modules (recommended):
  module 1 {sizes|plan|apply|connect|verify|browser ...}
      Build the foundation (network, Bastion, jump hosts, DNS, egress).

  module 2 {bootstrap|sync|doctor|verify|browser verify}
      Prepare the Linux jump host and verify the optional Windows browser host.

  module 3 {deploy|verify|proof ...|browser validate|teardown}
      Deploy, verify, prove, and tear down the lab workload.

  module 4 {prove-failure|preflight|prepare|sign|verify|sbom|sbom-proof|apply|proof}
      Prove the custom-image requirement, then build, sign, and prove the
      private-ACR image.

  module 5 {preflight|apply-ratify}
      Enable and verify AKS Image Integrity (audit-only signature verification).

Compatibility commands:
  deploy [--from-scratch --yes]
      Build or reconcile Azure infrastructure, AKS bootstrap, Anyscale platform,
      compute configs, and durable workspaces.

  verify [--static|--live|--full] [--skip-observability]
      Run static and/or live validation.

  proof {cpu|gpu|pipeline|all}
      Run deterministic workload proofs. This is the public alias for the
      existing workload proof runner.

  custom-image {preflight|prepare|sign|verify|sbom|sbom-proof|apply|proof|prove-failure}
      Build/push the local custom image with Podman, update workspaces, and
      prove the packaged dependency scenario.

  image-integrity {preflight|apply-ratify}
      Check the Image Integrity prerequisites and apply the Ratify verification
      config. Audit-only: unsigned images are flagged, not blocked.

  workload proof {cpu|gpu|pipeline|all}
      Compatibility spelling for proof commands.

  teardown [--force --yes] [--confirm-project <name>]
      Tear down with staged Terraform destroy, or use --force for a
      resource-group reset. Pass --confirm-project <name> to skip the
      interactive project-name confirmation in non-interactive runs.

  e2e [--custom-image] [--skip-verify] [--skip-proof] [--include-browser-precheck] [--teardown|--force-teardown --yes]
      Compose deploy, verify, proof all, and optional cleanup. Run it from the
      workstation or from the in-VNet jump host; the harness probes DNS each run
      to decide how to reach private endpoints. --custom-image adds the Module 4
      build and dependency proof; it does not sign or verify the image (see
      module 4 sign / module 4 verify).

  render
      Regenerate infra/terraform/terraform.auto.tfvars.json from .env without
      applying anything.

  status
      Read-only local/Azure/Terraform status summary.

  doctor
      Check local tool and auth readiness without deploying.

  privatelink-status
      Check the real connection state of the optional Anyscale control-plane
      Private Link path (module.anyscale_privatelink) and, if reachable,
      resolve its DNS records from inside the cluster. A successful
      `deploy` alone does not prove this path works -- Anyscale must approve
      the cross-tenant connection first.

  tunnel {start|status|stop} [--port PORT]
      Manage the Bastion-backed AKS API tunnel.

  browser {open|ready|status|stop} [ARGS]
      Manage Bastion-backed workspace browser helpers.

  head {open|status|stop} [ARGS]
      Manage direct workspace head-node browser helpers.

  kubeconfig {write|print|export} [--admin]
      Write or print the Bastion-backed kubeconfig.

  diagnose workspace-artifacts [ARGS]
      Capture Anyscale workspace artifact and storage-log diagnostics.

  diagrams export
      Export docs/Architecture-Diagram.drawio to docs/Architecture-Diagram.svg.

  self-test {timeouts|idempotency} [ARGS]
      Run harness self-tests.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

dependency_hint() {
  case "$1" in
    git) printf 'Install Git: https://git-scm.com/downloads or `brew install git`.\n' ;;
    az) printf 'Install Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli or `brew install azure-cli`.\n' ;;
    terraform) printf 'Install Terraform: https://developer.hashicorp.com/terraform/install.\n' ;;
    kubectl) printf 'Install kubectl: https://kubernetes.io/docs/tasks/tools/ or `az aks install-cli`.\n' ;;
    kubelogin) printf 'Install kubelogin: https://azure.github.io/kubelogin/ or `brew install Azure/kubelogin/kubelogin`.\n' ;;
    helm) printf 'Install Helm: https://helm.sh/docs/intro/install/ or `brew install helm`.\n' ;;
    jq) printf 'Install jq: https://jqlang.github.io/jq/download/ or `brew install jq`.\n' ;;
    rsync) printf 'Install rsync: https://rsync.samba.org/ or `brew install rsync`.\n' ;;
    python3) printf 'Install Python 3: https://www.python.org/downloads/ or `brew install python`.\n' ;;
    uv) printf 'Install uv: https://docs.astral.sh/uv/getting-started/installation/ or `brew install uv`.\n' ;;
    curl) printf 'Install curl: https://curl.se/download.html or `brew install curl` if your system image does not include it.\n' ;;
    lsof) printf 'Install lsof or use a system image that includes it; macOS includes `/usr/sbin/lsof`.\n' ;;
    ssh-keygen) printf 'Install OpenSSH client tools; most systems ship ssh-keygen with the `openssh-client` package.\n' ;;
    shellcheck) printf 'Install ShellCheck: https://www.shellcheck.net/ or `brew install shellcheck`. Optional lint tool.\n' ;;
    anyscale) printf 'Install the Anyscale CLI in the repo venv: `uv venv .venv && UV_CACHE_DIR="$PWD/.cache/uv-cache" uv pip install --python .venv/bin/python anyscale`.\n' ;;
    drawio) printf 'Install diagrams.net/draw.io desktop app or CLI: https://www.diagrams.net/. Required only for diagram export.\n' ;;
    podman) printf 'Install Podman yourself before custom-image prepare. On macOS: `brew install podman`, then create/start a Podman machine manually.\n' ;;
    syft) printf 'Install Syft on the jump host (handled by scripts/bootstrap-jump-host.sh): https://github.com/anchore/syft. Required only for custom-image sbom.\n' ;;
    oras) printf 'Install ORAS on the jump host (handled by scripts/bootstrap-jump-host.sh): https://oras.land/. Required only for custom-image sbom/sbom-proof.\n' ;;
    *) printf 'Install `%s` and make sure it is on PATH.\n' "$1" ;;
  esac
}

has_drawio_cli() {
  resolve_drawio_cli >/dev/null 2>&1
}

resolve_drawio_cli() {
  local candidate
  for candidate in drawio draw.io diagramsnet diagrams.net; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      command -v "${candidate}"
      return 0
    fi
  done

  local mac_app="/Applications/draw.io.app/Contents/MacOS/draw.io"
  if [[ -x "${mac_app}" ]]; then
    printf '%s\n' "${mac_app}"
    return 0
  fi

  return 1
}

check_commands() {
  local context="$1"
  shift

  local dependency missing_count=0
  local -a missing_dependencies=()

  for dependency in "$@"; do
    if [[ "${dependency}" == "anyscale" ]]; then
      [[ -x "${ROOT_DIR}/.venv/bin/anyscale" ]] && continue
    elif command -v "${dependency}" >/dev/null 2>&1; then
      continue
    fi

    missing_dependencies+=("${dependency}")
    ((missing_count += 1))
  done

  if (( missing_count == 0 )); then
    return 0
  fi

  printf 'Missing required dependencies for %s:\n' "${context}" >&2
  for dependency in "${missing_dependencies[@]}"; do
    printf '  - %s: ' "${dependency}" >&2
    dependency_hint "${dependency}" >&2
  done
  printf '\nRun `./scripts/anyscale-aks.sh doctor` for a full local readiness report.\n' >&2
  return 1
}

check_drawio_dependency() {
  local context="$1"

  if has_drawio_cli; then
    return 0
  fi

  printf 'Missing required dependency for %s:\n' "${context}" >&2
  printf '  - drawio: ' >&2
  dependency_hint drawio >&2
  return 1
}

# The proof/workload/custom-image stages read deployment facts from Terraform
# outputs when local state exists, and fall back to TF_VAR_*-derived names or az
# lookups when it does not (the usual case on an in-VNet runner that only holds a
# repo checkout). So require the terraform binary based on whether this machine
# actually has state to read — not on where the command is running.
local_terraform_state_present() {
  [[ -f "${TERRAFORM_DIR}/terraform.tfstate" ]]
}

check_dependencies_for() {
  local context="$1"
  shift

  source_env_if_present

  local terraform_dep=""
  local_terraform_state_present && terraform_dep="terraform"

  case "${context}" in
    deploy|verify|teardown|idempotency)
      check_commands "${context}" git az terraform kubectl kubelogin helm jq rsync python3 uv anyscale curl lsof
      ;;
    proof|workload)
      check_commands "${context}" az ${terraform_dep} kubectl kubelogin helm jq rsync python3 uv anyscale curl lsof
      ;;
    custom-image)
      local custom_image_base_commands
      custom_image_base_commands="az ${terraform_dep} jq"
      case "${1:-}" in
        preflight|prepare|proof)
          check_commands "${context} ${1:-}" ${custom_image_base_commands} kubectl kubelogin helm rsync python3 uv anyscale curl lsof podman
          ;;
        sign|verify)
          check_commands "${context} ${1:-}" ${custom_image_base_commands} podman notation
          ;;
        sbom)
          check_commands "${context} ${1:-}" ${custom_image_base_commands} syft oras
          ;;
        sbom-proof)
          check_commands "${context} ${1:-}" ${custom_image_base_commands} oras python3
          ;;
        apply|prove-failure)
          check_commands "${context} ${1:-}" ${custom_image_base_commands} kubectl kubelogin helm rsync python3 uv anyscale curl lsof
          ;;
        *)
          check_commands "${context}" ${custom_image_base_commands} podman
          ;;
      esac
      ;;
    image-integrity)
      case "${1:-}" in
        apply-ratify)
          check_commands "${context} ${1:-}" az terraform kubectl kubelogin jq envsubst
          ;;
        *)
          check_commands "${context}" az
          ;;
      esac
      ;;
    e2e)
      check_commands "${context}" git az terraform kubectl kubelogin helm jq rsync python3 uv anyscale curl lsof
      ;;
    tunnel|browser|head|kubeconfig)
      check_commands "${context}" az kubectl kubelogin jq python3 curl lsof
      ;;
    diagrams)
      check_drawio_dependency "${context}"
      ;;
    diagnose)
      check_commands "${context}" az terraform jq python3 anyscale
      ;;
    self-test)
      check_commands "${context}" bash
      ;;
    *)
      return 0
      ;;
  esac
}

is_help_request() {
  [[ $# -eq 0 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]
}

run_setup() {
  "${SETUP_SCRIPT}" "$@"
}

source_env_if_present() {
  local preserve_anyscale_cli_token="${ANYSCALE_CLI_TOKEN:-}"
  local preserve_tf_var_anyscale_cli_token="${TF_VAR_anyscale_cli_token:-}"
  local preserve_anyscale_host="${ANYSCALE_HOST:-}"
  local preserve_anyscale_cloud_name="${ANYSCALE_CLOUD_NAME:-}"
  local preserve_anyscale_cloud_deployment_id="${ANYSCALE_CLOUD_DEPLOYMENT_ID:-}"

  if [[ -f "${ROOT_DIR}/.env" ]]; then
    set +u
    set -a
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/.env"
    set +a
    set -u
  fi

  if [[ -n "${preserve_anyscale_cli_token}" ]]; then
    ANYSCALE_CLI_TOKEN="${preserve_anyscale_cli_token}"
    export ANYSCALE_CLI_TOKEN
  fi
  if [[ -n "${preserve_tf_var_anyscale_cli_token}" ]]; then
    TF_VAR_anyscale_cli_token="${preserve_tf_var_anyscale_cli_token}"
    export TF_VAR_anyscale_cli_token
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
}

resource_group_name() {
  printf 'rg-%s-%s-%s\n' \
    "${TF_VAR_project:-unknown}" \
    "${TF_VAR_environment:-unknown}" \
    "${TF_VAR_region_short:-unknown}"
}

latest_run_summary() {
  local latest_run=""

  latest_run="$(find "${ROOT_DIR}/.cache/aks-anyscale-sample-harness/runs" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name '*-*' \
    -print 2>/dev/null | sort | tail -n 1 || true)"

  if [[ -n "${latest_run}" && -f "${latest_run}/summary.md" ]]; then
    printf '%s\n' "${latest_run#${ROOT_DIR}/}"
    return 0
  fi

  return 1
}

terraform_state_status() {
  local terraform_dir="${1:-${TERRAFORM_DIR}}"

  if [[ -f "${terraform_dir}/terraform.tfstate" ]]; then
    printf 'present\n'
  elif find "${terraform_dir}/terraform.tfstate.d" -type f -print -quit 2>/dev/null | grep -q .; then
    printf 'workspace-state-present\n'
  else
    printf 'absent\n'
  fi
}

# ---------------------------------------------------------------------------
# init — create .env from the template and fill in what the machine can answer.
# ---------------------------------------------------------------------------

# Short region tokens go into every resource name (rg-<project>-<env>-<short>),
# so derive them from a reviewed table rather than by truncating the location.
# An unlisted region is not an error the harness should guess its way through:
# init asks for --region-short instead.
region_short_for_location() {
  case "$1" in
    westus) printf 'wus' ;;
    westus2) printf 'wus2' ;;
    westus3) printf 'wus3' ;;
    eastus) printf 'eus' ;;
    eastus2) printf 'eus2' ;;
    centralus) printf 'cus' ;;
    northcentralus) printf 'ncus' ;;
    southcentralus) printf 'scus' ;;
    westcentralus) printf 'wcus' ;;
    canadacentral) printf 'cac' ;;
    canadaeast) printf 'cae' ;;
    northeurope) printf 'neu' ;;
    westeurope) printf 'weu' ;;
    uksouth) printf 'uks' ;;
    ukwest) printf 'ukw' ;;
    francecentral) printf 'frc' ;;
    germanywestcentral) printf 'gwc' ;;
    swedencentral) printf 'sdc' ;;
    switzerlandnorth) printf 'szn' ;;
    norwayeast) printf 'nwe' ;;
    italynorth) printf 'itn' ;;
    polandcentral) printf 'plc' ;;
    spaincentral) printf 'spc' ;;
    eastasia) printf 'ea' ;;
    southeastasia) printf 'sea' ;;
    japaneast) printf 'jpe' ;;
    japanwest) printf 'jpw' ;;
    koreacentral) printf 'krc' ;;
    australiaeast) printf 'aue' ;;
    australiasoutheast) printf 'ause' ;;
    centralindia) printf 'cin' ;;
    southindia) printf 'sin' ;;
    uaenorth) printf 'uaen' ;;
    brazilsouth) printf 'brs' ;;
    southafricanorth) printf 'san' ;;
    *) return 1 ;;
  esac
}

# vCPU limit for the T4 GPU family in a region, or empty when the quota API
# cannot answer. An unreadable quota is not evidence of no quota, so callers
# treat empty as "leave the GPU pool alone" rather than as zero.
t4_quota_limit() {
  az vm list-usage --location "$1" --only-show-errors -o json 2>/dev/null \
    | jq -r 'map(select((.name.value // "") | test("NCAS.*T4"; "i"))) | first | .limit // empty' 2>/dev/null
}

# One Standard_NC16as_T4_v3 node. Below this the default pool cannot place even
# its warm node, so the deploy would fail late, after AKS is already built.
T4_VCPUS_PER_NODE=16

# Rewrite KEY=... in .env, or append it when the template does not carry the key.
# Values go through the environment so quoting in the value never has to be
# escaped into an awk program.
env_file_set() {
  local key="$1" value="$2" quote="${3:-\"}" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/anyscale-init.XXXXXX")"
  ANYSCALE_INIT_KEY="${key}" ANYSCALE_INIT_VALUE="${value}" ANYSCALE_INIT_QUOTE="${quote}" \
    awk '
      BEGIN {
        key = ENVIRON["ANYSCALE_INIT_KEY"]
        value = ENVIRON["ANYSCALE_INIT_VALUE"]
        quote = ENVIRON["ANYSCALE_INIT_QUOTE"]
        replaced = 0
      }
      !replaced && index($0, key "=") == 1 {
        print key "=" quote value quote
        replaced = 1
        next
      }
      { print }
      END { if (!replaced) print key "=" quote value quote }
    ' "${ROOT_DIR}/.env" >"${tmp}"
  mv "${tmp}" "${ROOT_DIR}/.env"
}

init() {
  local location=""
  local region_short=""
  local project="anyscale"
  local environment="dev"
  local subscription=""
  local tenant=""
  local force=false
  local gpu_mode="auto"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gpu) gpu_mode="on"; shift ;;
      --no-gpu) gpu_mode="off"; shift ;;
      --location) shift; [[ $# -gt 0 ]] || die "--location requires a value."; location="$1"; shift ;;
      --location=*) location="${1#*=}"; shift ;;
      --region-short) shift; [[ $# -gt 0 ]] || die "--region-short requires a value."; region_short="$1"; shift ;;
      --region-short=*) region_short="${1#*=}"; shift ;;
      --project) shift; [[ $# -gt 0 ]] || die "--project requires a value."; project="$1"; shift ;;
      --project=*) project="${1#*=}"; shift ;;
      --environment) shift; [[ $# -gt 0 ]] || die "--environment requires a value."; environment="$1"; shift ;;
      --environment=*) environment="${1#*=}"; shift ;;
      --subscription) shift; [[ $# -gt 0 ]] || die "--subscription requires a value."; subscription="$1"; shift ;;
      --subscription=*) subscription="${1#*=}"; shift ;;
      --tenant) shift; [[ $# -gt 0 ]] || die "--tenant requires a value."; tenant="$1"; shift ;;
      --tenant=*) tenant="${1#*=}"; shift ;;
      --force) force=true; shift ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh init [--location LOCATION] [--region-short SHORT]
      [--project NAME] [--environment ENV] [--subscription ID] [--tenant ID]
      [--gpu|--no-gpu] [--force]

Creates .env from .env-template and fills in what this machine can answer:
subscription and tenant from your signed-in Azure context, a short region token
derived from the location, owner tags, and an ed25519 SSH key for the jump host
if you do not already have one.

GPU pools are enabled when the subscription has T4 quota in the target region
and disabled when it does not, so a missing quota never blocks the deploy. A
CPU-only run still builds the entire private landing zone and proves it; only
the GPU, train, and serve stages are skipped. Force either way with --gpu or
--no-gpu, or edit TF_VAR_gpu_pool_configs in .env afterwards.

Everything else in .env-template already carries a reviewed default, so the
normal flow is:

  az login
  ./scripts/anyscale-aks.sh init
  ./scripts/anyscale-aks.sh deploy

Defaults: --location westus3 (the validated baseline), --project anyscale,
--environment dev. Refuses to overwrite an existing .env unless --force, which
backs the old file up first.
USAGE
        return 0
        ;;
      *) die "Unknown init option: $1" ;;
    esac
  done

  [[ -f "${ROOT_DIR}/.env-template" ]] || die "Missing ${ROOT_DIR}/.env-template."
  check_commands init az jq ssh-keygen

  if [[ -f "${ROOT_DIR}/.env" && "${force}" != true ]]; then
    die ".env already exists. Edit it directly, or re-run with --force to replace it (the current file is backed up first)."
  fi

  local az_args=(--only-show-errors -o tsv)
  [[ -n "${subscription}" ]] && az_args+=(--subscription "${subscription}")
  if ! az account show "${az_args[@]}" --query id >/dev/null 2>&1; then
    if [[ -n "${subscription}" ]]; then
      die "Azure CLI cannot read subscription '${subscription}'. Run 'az login', then confirm the id with 'az account list -o table'."
    fi
    die "Azure CLI is not signed in. Run 'az login' first, then re-run init."
  fi

  local resolved_subscription resolved_tenant signed_in_user
  resolved_subscription="$(az account show "${az_args[@]}" --query id)"
  resolved_tenant="$(az account show "${az_args[@]}" --query tenantId)"
  signed_in_user="$(az account show "${az_args[@]}" --query user.name 2>/dev/null || true)"
  [[ -n "${tenant}" ]] && resolved_tenant="${tenant}"
  [[ -n "${resolved_subscription}" ]] || die "Could not read a subscription id from 'az account show'."
  [[ -n "${resolved_tenant}" ]] || die "Could not read a tenant id from 'az account show'. Pass --tenant."
  [[ -n "${signed_in_user}" ]] || signed_in_user="unknown"

  [[ -n "${location}" ]] || location="westus3"
  if [[ -z "${region_short}" ]]; then
    region_short="$(region_short_for_location "${location}")" \
      || die "No short name on file for region '${location}'. Re-run with --region-short (a 3-4 character token used in every resource name, for example 'wus3')."
  fi

  local gpu_enabled=true
  local gpu_summary=""
  case "${gpu_mode}" in
    on)
      gpu_summary="enabled by --gpu (quota not checked)"
      ;;
    off)
      gpu_enabled=false
      gpu_summary="disabled by --no-gpu"
      ;;
    *)
      local t4_limit
      t4_limit="$(t4_quota_limit "${location}")"
      if [[ -z "${t4_limit}" ]]; then
        gpu_summary="enabled (could not read T4 quota for ${location}; leaving the default pool in place)"
      elif (( t4_limit >= T4_VCPUS_PER_NODE )); then
        gpu_summary="enabled (T4 quota ${t4_limit} vCPUs in ${location})"
      else
        gpu_enabled=false
        gpu_summary="disabled (T4 quota is ${t4_limit} vCPUs in ${location}; one node needs ${T4_VCPUS_PER_NODE})"
      fi
      ;;
  esac

  if [[ -f "${ROOT_DIR}/.env" ]]; then
    local backup="${ROOT_DIR}/.env.backup.$(date -u '+%Y%m%dT%H%M%SZ')"
    cp "${ROOT_DIR}/.env" "${backup}"
    printf 'Backed up existing .env to %s\n' "${backup}"
  fi

  cp "${ROOT_DIR}/.env-template" "${ROOT_DIR}/.env"
  chmod 600 "${ROOT_DIR}/.env"

  env_file_set ARM_SUBSCRIPTION_ID "${resolved_subscription}"
  env_file_set ARM_TENANT_ID "${resolved_tenant}"
  env_file_set TF_VAR_azure_subscription_id "${resolved_subscription}"
  env_file_set TF_VAR_azure_tenant_id "${resolved_tenant}"
  env_file_set TF_VAR_project "${project}"
  env_file_set TF_VAR_environment "${environment}"
  env_file_set TF_VAR_azure_location "${location}"
  env_file_set TF_VAR_region_short "${region_short}"

  local tags
  tags="$(jq -cn \
    --arg project "${project}" \
    --arg environment "${environment}" \
    --arg owner "${signed_in_user}" \
    '{Project: $project, Environment: $environment, ManagedBy: "terraform", Owner: $owner}')"
  env_file_set TF_VAR_tags "${tags}" "'"

  if [[ "${gpu_enabled}" != true ]]; then
    env_file_set TF_VAR_gpu_pool_configs '{}' "'"
  fi

  local ssh_key="${SSH_PRIVATE_KEY_PATH:-${HOME}/.ssh/id_ed25519}"
  env_file_set SSH_PRIVATE_KEY_PATH "${ssh_key}"
  if [[ ! -f "${ssh_key}" ]]; then
    mkdir -p "$(dirname "${ssh_key}")"
    chmod 700 "$(dirname "${ssh_key}")" 2>/dev/null || true
    ssh-keygen -t ed25519 -N '' -C "anyscale-aks-sample" -f "${ssh_key}" >/dev/null
    printf 'Generated a new SSH key pair at %s (the jump host trusts the .pub half).\n' "${ssh_key}"
  elif [[ ! -f "${ssh_key}.pub" ]]; then
    ssh-keygen -y -f "${ssh_key}" >"${ssh_key}.pub"
    printf 'Recreated the missing public half at %s.pub\n' "${ssh_key}"
  fi

  cat <<EOF

Wrote ${ROOT_DIR}/.env (mode 600, git-ignored):
  subscription   ${resolved_subscription}
  tenant         ${resolved_tenant}
  location       ${location} (region_short ${region_short})
  project/env    ${project} / ${environment}
  ssh key        ${ssh_key}
  gpu pools      ${gpu_summary}

Every other setting keeps its reviewed default from .env-template. Review them
before a real deploy — especially the VNet address plan (TF_VAR_vnet_address_space,
TF_VAR_subnet_cidrs) if 10.50.0.0/16 collides with your network.
EOF

  if [[ "${gpu_enabled}" != true ]]; then
    cat <<EOF

TF_VAR_gpu_pool_configs is set to {} for that reason. The deploy still builds the
whole private landing zone — private AKS, firewall egress, private storage and
ACR, Gateway and TLS — and 'proof all' still runs the CPU and build proofs. The
GPU, train, and serve proofs are skipped and reported as skipped.

To turn GPUs on later: request Standard NCASv3_T4 Family quota in ${location},
restore the TF_VAR_gpu_pool_configs line from .env-template, and re-run deploy.
EOF
  fi

  cat <<EOF

Next:
  1. ./scripts/anyscale-aks.sh doctor
  2. uv venv .venv && UV_CACHE_DIR="\$PWD/.cache/uv-cache" uv pip install --python .venv/bin/python anyscale
  3. ANYSCALE_HOST=https://console.azure.anyscale.com .venv/bin/anyscale login
  4. ./scripts/anyscale-aks.sh deploy
EOF
}

status() {
  local resource_group=""
  local group_exists="unknown"
  local state_status="absent"
  local latest_summary=""

  source_env_if_present
  resource_group="$(resource_group_name)"

  if command -v az >/dev/null 2>&1 && [[ "${resource_group}" != *unknown* ]]; then
    group_exists="$(az group exists --name "${resource_group}" --output tsv --only-show-errors 2>/dev/null || printf 'unknown')"
  fi

  state_status="$(terraform_state_status "${TERRAFORM_DIR}")"

  printf 'project=%s\n' "${TF_VAR_project:-unknown}"
  printf 'environment=%s\n' "${TF_VAR_environment:-unknown}"
  printf 'location=%s\n' "${TF_VAR_azure_location:-unknown}"
  printf 'resource_group=%s\n' "${resource_group}"
  printf 'resource_group_exists=%s\n' "${group_exists}"
  printf 'terraform_state=%s\n' "${state_status}"

  if latest_summary="$(latest_run_summary)"; then
    printf 'latest_run_summary=%s/summary.md\n' "${latest_summary}"
  else
    printf 'latest_run_summary=none\n'
  fi
}

results_overall_status() {
  if [[ "${RESULTS_DEPLOY_STATUS}" == "FAIL" \
    || "${RESULTS_VERIFY_STATUS}" == "FAIL" \
    || "${RESULTS_CUSTOM_IMAGE_STATUS}" == "FAIL" \
    || "${RESULTS_PROOF_STATUS}" == "FAIL" \
    || "${RESULTS_TEARDOWN_STATUS}" == "FAIL" ]]; then
    printf 'FAIL\n'
  elif [[ "${RESULTS_DEPLOY_STATUS}" == "RUNNING" || "${RESULTS_DEPLOY_STATUS}" == "PENDING" \
    || "${RESULTS_VERIFY_STATUS}" == "RUNNING" || "${RESULTS_VERIFY_STATUS}" == "PENDING" \
    || "${RESULTS_CUSTOM_IMAGE_STATUS}" == "RUNNING" || "${RESULTS_CUSTOM_IMAGE_STATUS}" == "PENDING" \
    || "${RESULTS_PROOF_STATUS}" == "RUNNING" || "${RESULTS_PROOF_STATUS}" == "PENDING" \
    || "${RESULTS_TEARDOWN_STATUS}" == "RUNNING" || "${RESULTS_TEARDOWN_STATUS}" == "PENDING" ]]; then
    printf 'RUNNING\n'
  elif [[ "${RESULTS_DEPLOY_STATUS}" == "SKIP" \
    && "${RESULTS_VERIFY_STATUS}" == "SKIP" \
    && "${RESULTS_CUSTOM_IMAGE_STATUS}" == "SKIP" \
    && "${RESULTS_PROOF_STATUS}" == "SKIP" \
    && "${RESULTS_TEARDOWN_STATUS}" == "SKIP" ]]; then
    printf 'SKIP\n'
  else
    printf 'PASS\n'
  fi
}

results_evidence_lines() {
  local roots=()
  local latest_summary latest_run_dir
  local evidence_file evidence_tmp

  [[ -n "${RESULTS_RUN_DIR:-}" && -d "${RESULTS_RUN_DIR}" ]] && roots+=("${RESULTS_RUN_DIR}")
  if latest_summary="$(latest_run_summary 2>/dev/null)"; then
    latest_run_dir="${ROOT_DIR}/${latest_summary}"
    [[ -d "${latest_run_dir}" ]] && roots+=("${latest_run_dir}")
  fi

  if (( ${#roots[@]} == 0 )); then
    printf '_No evidence files have been written yet._\n'
    return 0
  fi

  evidence_tmp="$(mktemp "${TMPDIR:-/tmp}/anyscale-results-evidence.XXXXXX")"
  while IFS= read -r evidence_file; do
    [[ -n "${evidence_file}" ]] || continue
    grep -HnE 'CUSTOM_IMAGE_[A-Z_]+|IMAGE_INTEGRITY_[A-Z_]+|CPU_RAY_PROOF_OK|GPU_RAY_PROOF_OK|CPU_BUILD_JOB_PROOF_OK|GPU_TRAIN_JOB_PROOF_OK|GPU_SERVE_SERVICE_PROOF_OK|Job .* printed .*PROOF_OK|Service .* printed .*PROOF_OK|"state"[[:space:]]*:[[:space:]]*"SUCCEEDED"|service_state=RUNNING|primary_version_state=RUNNING|Workspace .* RUNNING' "${evidence_file}" 2>/dev/null >> "${evidence_tmp}" || true
  done < <(find "${roots[@]}" -type f \( -name '*.log' -o -name '*.json' -o -name 'summary.md' -o -name '*.txt' \) -print 2>/dev/null)

  if [[ -s "${evidence_tmp}" ]]; then
    sed "s#${ROOT_DIR}/##" "${evidence_tmp}" \
      | awk 'NF && !seen[$0]++ {print "- `" $0 "`"}' \
      | sed -n '1,80p'
  else
    printf '_No evidence files have been written yet._\n'
  fi
  rm -f "${evidence_tmp}"
}

teardown_fact() {
  local resource_group=""
  local group_exists="unknown"
  local state_status="absent"

  source_env_if_present
  resource_group="$(resource_group_name)"

  if command -v az >/dev/null 2>&1 && [[ "${resource_group}" != *unknown* ]]; then
    group_exists="$(az group exists --name "${resource_group}" --output tsv --only-show-errors 2>/dev/null || printf 'unknown')"
  fi

  state_status="$(terraform_state_status "${TERRAFORM_DIR}")"

  printf 'resource_group_exists=%s; terraform_state=%s' "${group_exists}" "${state_status}"
}

write_results_report() {
  local generated_at overall_status
  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  overall_status="$(results_overall_status)"

  cat > "${RESULTS_FILE}" <<EOF
# Run Results

Generated: ${generated_at}
Started: ${RESULTS_STARTED_AT}
Command: ${RESULTS_COMMAND}
Overall: ${overall_status}

| Check | Result | Facts |
| --- | --- | --- |
| Build up | ${RESULTS_DEPLOY_STATUS} | ${RESULTS_DEPLOY_FACT} |
| Validation | ${RESULTS_VERIFY_STATUS} | ${RESULTS_VERIFY_FACT} |
| Custom image | ${RESULTS_CUSTOM_IMAGE_STATUS} | ${RESULTS_CUSTOM_IMAGE_FACT} |
| Workloads | ${RESULTS_PROOF_STATUS} | ${RESULTS_PROOF_FACT} |
| Teardown | ${RESULTS_TEARDOWN_STATUS} | ${RESULTS_TEARDOWN_FACT} |

Logs: ${RESULTS_LOG_FACT}

## Evidence From Logs

The lines below are copied from local run logs and status files so the report shows why each PASS claim is credible.

$(results_evidence_lines)
EOF
}

results_latest_summary_fact() {
  local latest_summary=""

  if latest_summary="$(latest_run_summary)"; then
    printf '%s/summary.md' "${latest_summary}"
  else
    printf 'No summary file found yet.'
  fi
}

run_e2e_step() {
  local status_var="$1"
  local fact_var="$2"
  local running_fact="$3"
  local pass_fact="$4"
  shift 4

  local exit_code=0 latest_summary="" step_log=""

  step_log="${RESULTS_RUN_DIR}/$(printf '%02d' "${RESULTS_STEP_INDEX}")-${status_var#RESULTS_}.log"
  RESULTS_STEP_INDEX=$((RESULTS_STEP_INDEX + 1))

  printf -v "${status_var}" '%s' 'RUNNING'
  printf -v "${fact_var}" '%s' "${running_fact}; log=${step_log#${ROOT_DIR}/}"
  write_results_report
  printf '[e2e] %s Log: %s\n' "${running_fact}" "${step_log#${ROOT_DIR}/}"

  set +e
  "$@" > "${step_log}" 2>&1
  exit_code=$?
  set -e

  latest_summary="$(results_latest_summary_fact)"
  RESULTS_LOG_FACT="Latest summary: ${latest_summary}; e2e logs: ${RESULTS_RUN_DIR#${ROOT_DIR}/}"

  if (( exit_code == 0 )); then
    printf -v "${status_var}" '%s' 'PASS'
    if [[ "${status_var}" == "RESULTS_TEARDOWN_STATUS" ]]; then
      printf -v "${fact_var}" '%s' "${pass_fact}; $(teardown_fact); ${latest_summary}; log=${step_log#${ROOT_DIR}/}"
    else
      printf -v "${fact_var}" '%s' "${pass_fact}; ${latest_summary}; log=${step_log#${ROOT_DIR}/}"
    fi
    printf '[e2e] %s\n' "${pass_fact}"
  else
    printf -v "${status_var}" '%s' 'FAIL'
    printf -v "${fact_var}" '%s' "exit_code=${exit_code}; ${latest_summary}; log=${step_log#${ROOT_DIR}/}"
    printf '[e2e] Step failed with exit code %s. Tail of %s:\n' "${exit_code}" "${step_log#${ROOT_DIR}/}" >&2
    tail -n 40 "${step_log}" >&2 || true
  fi

  write_results_report
  return "${exit_code}"
}

doctor() {
  local missing=0
  local command_name
  local doctor_log=""
  local required_commands=(git az terraform kubectl kubelogin helm jq rsync python3 uv curl lsof)
  local optional_commands=(shellcheck drawio podman)

  for command_name in "${required_commands[@]}"; do
    if command -v "${command_name}" >/dev/null 2>&1; then
      printf 'ok: %s\n' "${command_name}"
    else
      printf 'missing: %s\n' "${command_name}"
      printf '  '
      dependency_hint "${command_name}"
      missing=1
    fi
  done

  for command_name in "${optional_commands[@]}"; do
    if [[ "${command_name}" == "drawio" ]] && has_drawio_cli; then
      printf 'ok: %s\n' "${command_name}"
    elif [[ "${command_name}" != "drawio" ]] && command -v "${command_name}" >/dev/null 2>&1; then
      printf 'ok: %s\n' "${command_name}"
    else
      printf 'optional-missing: %s\n' "${command_name}"
      printf '  '
      dependency_hint "${command_name}"
    fi
  done

  if [[ ! -f "${ROOT_DIR}/.env" ]]; then
    printf 'missing: .env\n'
    printf '  Run: ./scripts/anyscale-aks.sh init\n'
    missing=1
  elif grep -qE '^(ARM_SUBSCRIPTION_ID|ARM_TENANT_ID|TF_VAR_azure_subscription_id|TF_VAR_azure_tenant_id)="?00000000-0000-0000-0000-000000000000' "${ROOT_DIR}/.env"; then
    printf 'not-ready: .env still carries the all-zero placeholder Azure ids\n'
    printf '  Run: ./scripts/anyscale-aks.sh init --force\n'
    missing=1
  else
    printf 'ok: .env\n'
  fi

  if [[ -x "${ROOT_DIR}/.venv/bin/anyscale" ]]; then
    printf 'ok: .venv/bin/anyscale\n'
  else
    printf 'missing: .venv/bin/anyscale\n'
    printf '  '
    dependency_hint anyscale
    missing=1
  fi

  if [[ -d "${TERRAFORM_DIR}/.terraform" ]]; then
    printf 'ok: terraform initialized\n'
  else
    printf 'missing: terraform initialized\n'
    missing=1
  fi

  if command -v az >/dev/null 2>&1; then
    if az extension show --name ssh --only-show-errors >/dev/null 2>&1; then
      printf 'ok: Azure CLI ssh extension (Bastion SSH)\n'
    else
      printf 'not-ready: Azure CLI ssh extension (Bastion SSH)\n'
      printf '  Run: az extension add -n ssh\n'
      missing=1
    fi
  fi

  printf '\nScenario readiness:\n'
  source_env_if_present
  local on_azure_vm=false
  running_on_azure_vm && on_azure_vm=true
  if [[ "${on_azure_vm}" == true ]]; then
    printf 'info: running on an Azure VM (in-VNet jump host)\n'
  else
    printf 'info: running on the operator workstation\n'
  fi
  printf 'info: private-endpoint reachability is probed per run from actual DNS, not from where this runs\n'
  local gpu_pool_json gpu_pool_count
  gpu_pool_json="${TF_VAR_gpu_pool_configs:-}"
  gpu_pool_count="$(jq -r 'length' <<<"${gpu_pool_json:-{\}}" 2>/dev/null || printf '0')"
  if [[ -z "${gpu_pool_json}" || "${gpu_pool_count}" == "0" ]]; then
    printf 'info: GPU pools disabled (TF_VAR_gpu_pool_configs is empty); GPU, train, and serve proofs will be skipped\n'
  else
    printf 'info: GPU pools enabled (%s pool(s) in TF_VAR_gpu_pool_configs)\n' "${gpu_pool_count}"
  fi
  if az account show >/dev/null 2>&1; then
    local az_user_type
    az_user_type="$(az account show --query user.type -o tsv --only-show-errors 2>/dev/null || true)"
    printf 'ok: Azure CLI authenticated (user.type=%s)\n' "${az_user_type:-unknown}"
    if [[ "${on_azure_vm}" == true && "${az_user_type}" != "servicePrincipal" ]]; then
      printf '  note: the jump host normally authenticates with its managed identity: az login --identity\n'
    fi
  else
    printf 'not-ready: Azure CLI authentication\n'
    if [[ "${on_azure_vm}" == true ]]; then
      printf '  Run on the jump host: az login --identity\n'
    else
      printf '  Run: az login\n'
    fi
    missing=1
  fi
  if [[ -z "${ANYSCALE_CLI_TOKEN:-}" ]]; then
    unset ANYSCALE_CLI_TOKEN
  fi
  if [[ -x "${ROOT_DIR}/.venv/bin/anyscale" ]]; then
    if ANYSCALE_HOST="${ANYSCALE_HOST:-https://console.azure.anyscale.com}" \
      "${ROOT_DIR}/.venv/bin/anyscale" cloud list --max-items 1 --page-size 1 --no-interactive --json >/dev/null 2>&1; then
      printf 'ok: Anyscale CLI OAuth/API-key auth\n'
    else
      printf 'not-ready: Anyscale CLI OAuth/API-key auth\n'
      printf '  Run: ANYSCALE_HOST=https://console.azure.anyscale.com .venv/bin/anyscale login\n'
      missing=1
    fi
  fi

  if command -v podman >/dev/null 2>&1; then
    if podman info >/dev/null 2>&1; then
      printf 'ok: podman ready\n'
    else
      printf 'not-ready: podman installed but machine is not ready\n'
      missing=1
    fi
  fi

  # Image signing toolchain (jump-host tool; informational on the workstation).
  if command -v notation >/dev/null 2>&1; then
    if notation plugin ls 2>/dev/null | grep -q 'azure-kv'; then
      printf 'ok: notation + azure-kv plugin (image signing)\n'
    else
      printf 'not-ready: notation present but azure-kv plugin missing (image signing)\n'
      printf '  Re-run scripts/bootstrap-jump-host.sh on the jump host.\n'
    fi
  else
    printf 'info: notation not installed (image signing); installed by the jump host bootstrap\n'
  fi

  if command -v az >/dev/null 2>&1; then
    local image_integrity_feature_state
    image_integrity_feature_state="$(az feature show --namespace Microsoft.ContainerService --name EnableImageIntegrityPreview --query properties.state -o tsv --only-show-errors 2>/dev/null || echo Unknown)"
    if [[ "${image_integrity_feature_state}" == "Registered" ]]; then
      printf 'ok: EnableImageIntegrityPreview feature registered\n'
    else
      printf 'info: EnableImageIntegrityPreview feature is %s (managed by Terraform azapi_resource)\n' "${image_integrity_feature_state}"
    fi
  fi

  if [[ -f "${ROOT_DIR}/.env" && -d "${TERRAFORM_DIR}/.terraform" && -x "${SETUP_SCRIPT}" ]]; then
    doctor_log="${TMPDIR:-${ROOT_DIR}/.cache}/anyscale-custom-image-preflight.$$.log"
    if run_setup custom-image preflight >"${doctor_log}" 2>&1; then
      printf 'ok: custom-image local ACR build/push readiness\n'
    else
      printf 'not-ready: custom-image local ACR build/push readiness\n'
      sed -n '1,80p' "${doctor_log}" | sed 's/^/  /'
      missing=1
    fi
  fi

  return "${missing}"
}

e2e() {
  local skip_verify=false
  local skip_proof=false
  local run_custom_image=false
  local teardown_mode="none"
  local yes=false
  local include_browser_precheck=false
  local -a original_args=("$@")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --include-browser-precheck)
        include_browser_precheck=true
        shift
        ;;
      --skip-verify)
        skip_verify=true
        shift
        ;;
      --skip-proof)
        skip_proof=true
        shift
        ;;
      --custom-image)
        run_custom_image=true
        shift
        ;;
      --skip-teardown)
        teardown_mode="none"
        shift
        ;;
      --teardown)
        teardown_mode="terraform"
        shift
        ;;
      --force-teardown)
        teardown_mode="force"
        shift
        ;;
      --yes|-y)
        yes=true
        shift
        ;;
      --help|-h)
        cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh e2e [--custom-image]
      [--skip-verify] [--skip-proof] [--include-browser-precheck]
      [--teardown|--force-teardown --yes]

Runs deploy (terraform apply), verify --full, proof all, and optional teardown
(terraform destroy). Interactive browser validation is skipped; use
--include-browser-precheck for non-interactive browser-host checks. The run
overwrites root RESULTS.md with a concise local summary.

Run this from wherever you are. The harness probes actual DNS each run rather
than trusting a declared mode: it talks to the AKS API directly when the private
FQDN resolves privately from this machine and tunnels through Bastion otherwise,
and the job/service proofs gate on whether the private Storage endpoints resolve
here.

From a laptop, Terraform and verify work over Bastion, but the stages that need
private endpoints — ACR pushes for --custom-image, and the Anyscale job/service
submits in proof all — must run from the in-VNet jump host built in Module 2.
The harness stops with the exact resume command when it reaches one.

Running every stage on the jump host, including terraform apply/destroy, needs
no flag: sync the repo with 'module 2 sync' and run the same command there. That
scenario does require TF_VAR_assign_jump_host_rbac_admin=true so the VM identity
can create role assignments, which lets the VM assign roles at its scope,
including roles you cannot assign yourself. Leave it false unless your org
forbids workstation applies.
USAGE
        return 0
        ;;
      *)
        die "Unknown e2e option: $1"
        ;;
    esac
  done

  RESULTS_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  RESULTS_COMMAND="./scripts/anyscale-aks.sh e2e ${original_args[*]}"
  RESULTS_RUN_DIR="${ROOT_DIR}/.cache/aks-anyscale-sample-harness/e2e/$(date -u '+%Y%m%dT%H%M%SZ')"
  RESULTS_STEP_INDEX=1
  RESULTS_DEPLOY_STATUS="PENDING"
  RESULTS_VERIFY_STATUS="SKIP"
  RESULTS_CUSTOM_IMAGE_STATUS="SKIP"
  RESULTS_PROOF_STATUS="SKIP"
  RESULTS_TEARDOWN_STATUS="SKIP"
  RESULTS_DEPLOY_FACT="Not started."
  RESULTS_VERIFY_FACT="Skipped by request."
  RESULTS_CUSTOM_IMAGE_FACT="Not requested. Use --custom-image to prove packaged dependency flow."
  RESULTS_PROOF_FACT="Skipped by request."
  RESULTS_TEARDOWN_FACT="Not requested. Use --teardown or --force-teardown --yes to prove cleanup."
  RESULTS_LOG_FACT="No run summary yet."
  mkdir -p "${RESULTS_RUN_DIR}"
  write_results_report

  run_e2e_step \
    RESULTS_DEPLOY_STATUS \
    RESULTS_DEPLOY_FACT \
    "Deploy is running." \
    "Deploy completed." \
    run_setup deploy || return $?

  if [[ "${skip_verify}" != true ]]; then
    run_e2e_step \
      RESULTS_VERIFY_STATUS \
      RESULTS_VERIFY_FACT \
      "Full verification is running." \
      "Full verification completed." \
      run_setup verify --full || return $?
  fi

  if [[ "${run_custom_image}" == true ]]; then
    run_e2e_step \
      RESULTS_CUSTOM_IMAGE_STATUS \
      RESULTS_CUSTOM_IMAGE_FACT \
      "Custom image flow is running." \
      "Custom image expected-failure, build, workspace update, and dependency proof completed." \
      custom_image_e2e_stage || return $?
  fi

  if [[ "${skip_proof}" != true ]]; then
    run_e2e_step \
      RESULTS_PROOF_STATUS \
      RESULTS_PROOF_FACT \
      "All workload proofs are running." \
      "All workload proofs completed." \
      run_setup workload proof all || return $?
  fi

  if [[ "${include_browser_precheck}" == true ]]; then
    log "Running non-interactive browser-host prerequisite checks (interactive browser validation is skipped)."
    bash "${MODULE_1_SCRIPT}" browser verify || warn "Browser-host precheck reported issues; see docs/modules/browser-access.md."
  fi

  if [[ "${teardown_mode}" != "none" ]]; then
    log "Note: interactive browser validation was skipped. To inspect console-launched workspace/service URLs, rerun without --teardown or run 'module 3 browser validate' before teardown."
  fi

  case "${teardown_mode}" in
    none)
      ;;
    terraform)
      source_env_if_present
      run_e2e_step \
        RESULTS_TEARDOWN_STATUS \
        RESULTS_TEARDOWN_FACT \
        "Terraform teardown is running." \
        "Terraform teardown completed." \
        run_setup teardown --confirm-project "${TF_VAR_project:-}" || return $?
      ;;
    force)
      if [[ "${yes}" == true ]]; then
        run_e2e_step \
          RESULTS_TEARDOWN_STATUS \
          RESULTS_TEARDOWN_FACT \
          "Force teardown is running." \
          "Force teardown completed." \
          run_setup teardown --force --yes || return $?
      else
        run_e2e_step \
          RESULTS_TEARDOWN_STATUS \
          RESULTS_TEARDOWN_FACT \
          "Force teardown is running." \
          "Force teardown completed." \
          run_setup teardown --force || return $?
      fi
      ;;
    *)
      die "Unknown teardown mode: ${teardown_mode}"
      ;;
  esac

  write_results_report
}

custom_image_e2e_stage() {
  run_setup custom-image prove-failure
  if ! run_setup custom-image preflight; then
    cat >&2 <<'EOF'

[e2e] Custom image prepare requires private network reachability to the ACR:
      - Bastion remains the AKS API path for kubectl/Terraform/Helm.
      - Run this stage from an in-VNet jump host with private DNS so the
        private ACR login and data endpoints resolve and are reachable.

      Resume with:
        ./scripts/anyscale-aks.sh custom-image prepare
        ANYSCALE_CUSTOM_IMAGE_ENABLED=true ./scripts/anyscale-aks.sh custom-image sbom
        ANYSCALE_CUSTOM_IMAGE_ENABLED=true ./scripts/anyscale-aks.sh custom-image sbom-proof
        ANYSCALE_CUSTOM_IMAGE_ENABLED=true ./scripts/anyscale-aks.sh custom-image apply
        ANYSCALE_CUSTOM_IMAGE_ENABLED=true ./scripts/anyscale-aks.sh custom-image proof
        ./scripts/anyscale-aks.sh proof all
EOF
    return 1
  fi
  run_setup custom-image prepare
  if command -v syft >/dev/null 2>&1 && command -v oras >/dev/null 2>&1; then
    ANYSCALE_CUSTOM_IMAGE_ENABLED=true run_setup custom-image sbom
    ANYSCALE_CUSTOM_IMAGE_ENABLED=true run_setup custom-image sbom-proof
  else
    warn "syft or oras not installed; skipping SBOM steps. Re-run scripts/bootstrap-jump-host.sh on the jump host."
  fi
  ANYSCALE_CUSTOM_IMAGE_ENABLED=true run_setup custom-image apply
  ANYSCALE_CUSTOM_IMAGE_ENABLED=true run_setup custom-image proof
}

proof() {
  local target="${1:-}"

  case "${target}" in
    ""|--help|-h)
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh proof {cpu|gpu|pipeline|all} [--command-timeout-seconds N]

Targets:
  cpu       Durable CPU workspace proof.
  gpu       Durable GPU workspace proof.
  pipeline  CPU build job, GPU train job, and GPU Serve proof.
  all       CPU, GPU, and full build/train/serve pipeline.
USAGE
      return 0
      ;;
    cpu|gpu|pipeline|all)
      shift
      run_setup workload proof "${target}" "$@"
      ;;
    build|train|serve)
      die "proof ${target} is planned but not yet implemented as an isolated target; use proof pipeline or proof all."
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh proof {cpu|gpu|pipeline|all}"
      ;;
  esac
}

custom_image() {
  local action="${1:-}"
  case "${action}" in
    preflight|prepare|sign|verify|sbom|sbom-proof|apply|proof|prove-failure)
      shift
      run_setup custom-image "${action}" "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh custom-image preflight
  ./scripts/anyscale-aks.sh custom-image prepare
  ./scripts/anyscale-aks.sh custom-image sign
  ./scripts/anyscale-aks.sh custom-image verify
  ./scripts/anyscale-aks.sh custom-image sbom
  ./scripts/anyscale-aks.sh custom-image sbom-proof
  ./scripts/anyscale-aks.sh custom-image prove-failure
  ./scripts/anyscale-aks.sh custom-image apply
  ./scripts/anyscale-aks.sh custom-image proof

preflight     Check local Podman, private DNS, ACR push role, and ACR auth.
prepare       Build and push the custom image with Podman.
sign          Sign the pushed image with Notation + the Key Vault certificate.
verify        Verify the image signature locally with Notation.
sbom          Generate a Syft SPDX SBOM and attach (and sign) it as an OCI referrer.
sbom-proof    Verify the SBOM referrer exists and contains the packaged dependency.
prove-failure Prove the standard image cannot runtime-install the dependency.
apply         Update durable workspaces to use the custom image.
proof         Prove the packaged dependency is available on the custom image.
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh custom-image {preflight|prepare|sign|verify|sbom|sbom-proof|apply|proof|prove-failure}"
      ;;
  esac
}

image_integrity() {
  local action="${1:-}"
  case "${action}" in
    preflight|apply-ratify)
      shift
      run_setup image-integrity "${action}" "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh image-integrity preflight
  ./scripts/anyscale-aks.sh image-integrity apply-ratify

preflight     Check the EnableImageIntegrityPreview feature flag and aks-preview extension.
apply-ratify  Apply the Ratify verification CRDs (KeyManagementProvider/Store/Verifier).

Note: AKS Image Integrity is audit-only. Unsigned images are flagged
non-compliant in Azure Policy but are not blocked from running.
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh image-integrity {preflight|apply-ratify}"
      ;;
  esac
}

tunnel() {
  local action="${1:-}"
  case "${action}" in
    start|status|stop)
      run_setup bastion-tunnel "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh tunnel start [--port PORT]
  ./scripts/anyscale-aks.sh tunnel status
  ./scripts/anyscale-aks.sh tunnel stop
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh tunnel {start|status|stop} [--port PORT]"
      ;;
  esac
}

browser() {
  local action="${1:-}"
  case "${action}" in
    open)
      shift
      run_setup workspace-browser-open start "$@"
      ;;
    ready)
      shift
      run_setup workspace-browser-ready start "$@"
      ;;
    status)
      run_setup workspace-browser-open status
      ;;
    stop)
      shift
      run_setup workspace-browser-open stop "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh browser open --session-id ses_xxx [ARGS]
  ./scripts/anyscale-aks.sh browser ready --session-id ses_xxx [ARGS]
  ./scripts/anyscale-aks.sh browser status
  ./scripts/anyscale-aks.sh browser stop [--keep-network]
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh browser {open|ready|status|stop}"
      ;;
  esac
}

head() {
  local action="${1:-}"
  case "${action}" in
    open)
      shift
      run_setup workspace-head-open start "$@"
      ;;
    status)
      run_setup workspace-head-open status
      ;;
    stop)
      shift
      run_setup workspace-head-open stop "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh head open --session-id ses_xxx [ARGS]
  ./scripts/anyscale-aks.sh head status
  ./scripts/anyscale-aks.sh head stop [--keep-forward]
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh head {open|status|stop}"
      ;;
  esac
}

kubeconfig() {
  local action="${1:-}"
  case "${action}" in
    write)
      shift
      run_setup kubeconfig-bastion "$@"
      ;;
    print)
      shift
      run_setup kubeconfig-bastion --print-path "$@"
      ;;
    export)
      shift
      run_setup kubeconfig-bastion --export "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh kubeconfig write [--admin]
  ./scripts/anyscale-aks.sh kubeconfig print [--admin]
  ./scripts/anyscale-aks.sh kubeconfig export [--admin]
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh kubeconfig {write|print|export} [--admin]"
      ;;
  esac
}

diagrams() {
  local action="${1:-}"
  case "${action}" in
    export)
      local source_diagram="${ROOT_DIR}/docs/Architecture-Diagram.drawio"
      local output_diagram="${ROOT_DIR}/docs/Architecture-Diagram.svg"
      local drawio_bin
      [[ -f "${source_diagram}" ]] || die "Missing diagram source: ${source_diagram}"
      drawio_bin="$(resolve_drawio_cli)" || die "No draw.io/diagrams.net CLI was found. Install the diagrams.net desktop/CLI, then rerun: ./scripts/anyscale-aks.sh diagrams export"
      if "${drawio_bin}" --export --format svg --output "${output_diagram}" "${source_diagram}" 2>/dev/null; then
        printf 'Exported %s\n' "${output_diagram#${ROOT_DIR}/}"
      else
        "${drawio_bin}" -x -f svg -o "${output_diagram}" "${source_diagram}"
        printf 'Exported %s\n' "${output_diagram#${ROOT_DIR}/}"
      fi
      ;;
    --help|-h|"")
      printf 'Usage: ./scripts/anyscale-aks.sh diagrams export\n'
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh diagrams export"
      ;;
  esac
}

self_test() {
  local target="${1:-}"
  case "${target}" in
    timeouts)
      shift
      bash "${TIMEOUT_SELF_TEST_SCRIPT}" "$@"
      ;;
    idempotency)
      shift
      run_setup idempotency "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh self-test timeouts
  ./scripts/anyscale-aks.sh self-test idempotency [ARGS]
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh self-test {timeouts|idempotency}"
      ;;
  esac
}

diagnose() {
  local target="${1:-}"
  local python_bin="${ROOT_DIR}/.venv/bin/python"

  case "${target}" in
    workspace-artifacts)
      shift
      if [[ ! -x "${python_bin}" ]]; then
        python_bin="python3"
      fi
      "${python_bin}" "${DIAGNOSE_WORKSPACE_ARTIFACTS_SCRIPT}" "$@"
      ;;
    --help|-h|"")
      cat <<'USAGE'
Usage:
  ./scripts/anyscale-aks.sh diagnose workspace-artifacts [ARGS]

Runs the workspace artifact diagnostic utility with the repo virtualenv Python
when available, falling back to python3.
USAGE
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh diagnose workspace-artifacts [ARGS]"
      ;;
  esac
}

module_command() {
  local module_number="${1:-}"
  shift || true
  case "${module_number}" in
    1)
      bash "${MODULE_1_SCRIPT}" "$@"
      ;;
    2)
      bash "${MODULE_2_SCRIPT}" "$@"
      ;;
    3)
      bash "${MODULE_3_SCRIPT}" "$@"
      ;;
    4)
      bash "${MODULE_4_SCRIPT}" "$@"
      ;;
    5)
      bash "${MODULE_5_SCRIPT}" "$@"
      ;;
    ""|--help|-h)
      cat <<'USAGE'
Usage: ./scripts/anyscale-aks.sh module {1|2|3|4|5} SUBCOMMAND [ARGS]

  module 1  Build the foundation and connect to the jump hosts.
  module 2  Prepare the Linux jump host and verify the optional browser host.
  module 3  Deploy, verify, prove, and tear down the lab workload.
  module 4  Prove the custom-image requirement, build, sign, and prove the private-ACR image.
  module 5  Enable and verify AKS Image Integrity (signature verification).

Run `module N --help` for each module's subcommands.
USAGE
      ;;
    *)
      die "Unknown module '${module_number}'. Use module {1|2|3|4|5}."
      ;;
  esac
}

main() {
  local command_name="${1:-}"

  case "${command_name}" in
    ""|--help|-h)
      usage
      ;;
    module)
      shift
      module_command "$@"
      ;;
    deploy|verify|teardown|idempotency)
      shift
      is_help_request "$@" || check_dependencies_for "${command_name}"
      run_setup "${command_name}" "$@"
      ;;
    proof)
      shift
      is_help_request "$@" || check_dependencies_for proof
      proof "$@"
      ;;
    custom-image)
      shift
      is_help_request "$@" || check_dependencies_for custom-image "$@"
      custom_image "$@"
      ;;
    image-integrity)
      shift
      is_help_request "$@" || check_dependencies_for image-integrity "$@"
      image_integrity "$@"
      ;;
    workload)
      shift
      is_help_request "$@" || check_dependencies_for workload
      run_setup workload "$@"
      ;;
    e2e)
      shift
      is_help_request "$@" || check_dependencies_for e2e
      e2e "$@"
      ;;
    init)
      shift
      init "$@"
      ;;
    render)
      shift
      [[ $# -eq 0 ]] || die "render does not accept arguments."
      run_setup render
      ;;
    status)
      shift
      [[ $# -eq 0 ]] || die "status does not accept arguments."
      status
      ;;
    doctor)
      shift
      [[ $# -eq 0 ]] || die "doctor does not accept arguments."
      doctor
      ;;
    privatelink-status)
      shift
      [[ $# -eq 0 ]] || die "privatelink-status does not accept arguments."
      run_setup privatelink-status
      ;;
    tunnel)
      shift
      is_help_request "$@" || check_dependencies_for tunnel
      tunnel "$@"
      ;;
    browser)
      shift
      is_help_request "$@" || check_dependencies_for browser
      browser "$@"
      ;;
    head)
      shift
      is_help_request "$@" || check_dependencies_for head
      head "$@"
      ;;
    kubeconfig)
      shift
      is_help_request "$@" || check_dependencies_for kubeconfig
      kubeconfig "$@"
      ;;
    diagnose)
      shift
      is_help_request "$@" || check_dependencies_for diagnose
      diagnose "$@"
      ;;
    diagrams)
      shift
      is_help_request "$@" || check_dependencies_for diagrams
      diagrams "$@"
      ;;
    self-test)
      shift
      is_help_request "$@" || check_dependencies_for self-test
      self_test "$@"
      ;;
    *)
      die "Usage: ./scripts/anyscale-aks.sh COMMAND [ARGS]"
      ;;
  esac
}

main "$@"
