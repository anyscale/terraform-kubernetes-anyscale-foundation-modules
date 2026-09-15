#!/bin/bash

# ============================================================================
# ANYSCALE OPERATOR INSTALLER (HELM-BASED)
# ============================================================================
# Installs/updates the Anyscale operator on the Nebius MK8s cluster created by
# this example. This script replaces the Terraform-managed deployment so that
# infrastructure and application lifecycles remain independent.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${EXAMPLE_DIR}/config.yaml"

RELEASE_NAME="anyscale-operator"
NAMESPACE="anyscale-system"
SA_NAME="anyscale-bucket-sa"
CREDENTIAL_SECRET_NAME="anyscale-aws-credentials"

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ Required command '$1' not found in PATH" >&2
    exit 1
  fi
}

get_config_value() {
  local key="$1"
  local value
  value=$(grep -E "^[[:space:]]*${key}:" "${CONFIG_FILE}" | head -n1 | awk '{print $2}' | tr -d '"')
  echo "${value}"
}

resolve_cli_token() {
  local token
  token=$(get_config_value "cli_token")
  if [[ -n "${token}" ]]; then
    echo "${token}"
    return 0
  fi

  local creds_file="${HOME}/.anyscale/credentials.json"
  if [[ -f "${creds_file}" ]]; then
    token=$(jq -r '.cli_token // empty' "${creds_file}" 2>/dev/null || true)
    if [[ -n "${token}" && "${token}" != "null" ]]; then
      echo "${token}"
      return 0
    fi
  fi

  return 1
}

resolve_cloud_deployment_id() {
  local cloud_name="$1"
  local from_config

  if [[ -n "${ANYSCALE_CLOUD_DEPLOYMENT_ID:-}" ]]; then
    echo "${ANYSCALE_CLOUD_DEPLOYMENT_ID}"
    return 0
  fi

  from_config=$(get_config_value "cloud_deployment_id")
  if [[ -n "${from_config}" ]]; then
    echo "${from_config}"
    return 0
  fi

  if ! command -v anyscale >/dev/null 2>&1; then
    return 1
  fi

  local cloud_row
  cloud_row=$(anyscale cloud list --name "${cloud_name}" --max-items 25 2>/dev/null | awk '$1 ~ /^cld_/ {print; exit}')
  if [[ -z "${cloud_row}" ]]; then
    return 1
  fi

  local cloud_id
  cloud_id=$(echo "${cloud_row}" | awk '{print $1}')
  if [[ -z "${cloud_id}" ]]; then
    return 1
  fi

  local deployment_id
  deployment_id=$(anyscale cloud get --cloud-id "${cloud_id}" 2>/dev/null | awk '/cloud_resource_id:/ {print $2; exit}')
  if [[ -n "${deployment_id}" ]]; then
    echo "${deployment_id}"
    return 0
  fi

  return 1
}

ensure_non_empty() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    echo "❌ Missing required value for ${name} in config.yaml" >&2
    exit 1
  fi
}

echo "🔍 Validating prerequisites..."
require_bin nebius
require_bin terraform
require_bin helm
require_bin kubectl
require_bin jq
require_bin anyscale

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "❌ ${CONFIG_FILE} not found. Copy config.example.yaml and fill in your values." >&2
  exit 1
fi

TENANT_ID=$(get_config_value "tenant_id")
PROJECT_ID=$(get_config_value "project_id")
REGION=$(get_config_value "region")
CLOUD_NAME=$(get_config_value "cloud_name")

ensure_non_empty "nebius.tenant_id" "${TENANT_ID}"
ensure_non_empty "nebius.project_id" "${PROJECT_ID}"
ensure_non_empty "nebius.region" "${REGION}"
ensure_non_empty "anyscale.cloud_name" "${CLOUD_NAME}"

CLI_TOKEN=$(resolve_cli_token || true)
if [[ -z "${CLI_TOKEN}" ]]; then
  echo "❌ Could not determine Anyscale CLI token. Either set anyscale.cli_token in config.yaml or run 'anyscale login' so it is written to ~/.anyscale/credentials.json." >&2
  exit 1
fi

CLOUD_DEPLOYMENT_ID=$(resolve_cloud_deployment_id "${CLOUD_NAME}" || true)
if [[ -z "${CLOUD_DEPLOYMENT_ID}" ]]; then
  echo "❌ Unable to determine the Anyscale cloud deployment ID for '${CLOUD_NAME}'." >&2
  echo "   Run ./register.sh if you have not registered the cloud yet, or set ANYSCALE_CLOUD_DEPLOYMENT_ID before rerunning this script." >&2
  exit 1
fi

echo "ℹ️  Using project ${PROJECT_ID} in region ${REGION}"

echo "🪄 Gathering Terraform outputs..."
CLUSTER_ID=$(terraform -chdir="${SCRIPT_DIR}" output -raw cluster_id 2>/dev/null || true)
if [[ -z "${CLUSTER_ID}" ]]; then
  echo "❌ Failed to read cluster_id from terraform outputs. Make sure 'terraform apply' succeeded in deploy/." >&2
  exit 1
fi
CLUSTER_NAME=$(terraform -chdir="${SCRIPT_DIR}" output -raw cluster_name 2>/dev/null || echo "${CLUSTER_ID}")
BUCKET_NAME=$(terraform -chdir="${EXAMPLE_DIR}/prepare" output -raw bucket_name 2>/dev/null || true)

if [[ -z "${BUCKET_NAME}" ]]; then
  echo "❌ Failed to read bucket_name from prepare/ terraform outputs. Run 'terraform apply' in prepare/ first." >&2
  exit 1
fi

echo "   Cluster ID: ${CLUSTER_ID}"
echo "   Cluster Name: ${CLUSTER_NAME}"
echo "   Object storage bucket: ${BUCKET_NAME}"

echo "🔐 Ensuring AWS-compatible credentials for Anyscale object storage..."
SA_ID=$(nebius iam service-account list \
  --parent-id "${PROJECT_ID}" \
  --format json \
  | jq -r --arg NAME "${SA_NAME}" '.items[]? | select(.metadata.name == $NAME).metadata.id')

if [[ -z "${SA_ID}" || "${SA_ID}" == "null" ]]; then
  echo "   Creating service account '${SA_NAME}'..."
  SA_ID=$(nebius iam service-account create \
    --parent-id "${PROJECT_ID}" \
    --name "${SA_NAME}" \
    --format json \
    | jq -r '.metadata.id')
else
  echo "   Reusing existing service account '${SA_NAME}' (${SA_ID})"
fi

EDITORS_GROUP_ID=$(nebius iam group get-by-name \
  --parent-id "${TENANT_ID}" \
  --name "editors" \
  --format json \
  | jq -r '.metadata.id')

if [[ -z "${EDITORS_GROUP_ID}" || "${EDITORS_GROUP_ID}" == "null" ]]; then
  echo "❌ Could not resolve editors group in tenant ${TENANT_ID}. Check your Nebius IAM configuration." >&2
  exit 1
fi

IS_MEMBER=$(nebius iam group-membership list-members \
  --parent-id "${EDITORS_GROUP_ID}" \
  --page-size 1000 \
  --format json \
  | jq -r --arg SA "${SA_ID}" '.memberships[]? | select(.spec.member_id == $SA).spec.member_id')

if [[ -z "${IS_MEMBER}" ]]; then
  echo "   Adding service account to editors group..."
  nebius iam group-membership create \
    --parent-id "${EDITORS_GROUP_ID}" \
    --member-id "${SA_ID}" >/dev/null
fi

if [[ "$(uname)" == "Darwin" ]]; then
  ACCESS_KEY_EXPIRATION=$(date -v +7d '+%Y-%m-%dT%H:%M:%SZ')
else
  ACCESS_KEY_EXPIRATION=$(date -u -d '+7 days' '+%Y-%m-%dT%H:%M:%SZ')
fi

ACCESS_KEY_NAME="anyscale-s3-$(date +%s)"
echo "   Creating short-lived access key '${ACCESS_KEY_NAME}' (expires ${ACCESS_KEY_EXPIRATION})..."
ACCESS_KEY=$(nebius iam access-key create \
  --parent-id "${PROJECT_ID}" \
  --name "${ACCESS_KEY_NAME}" \
  --account-service-account-id "${SA_ID}" \
  --description "Anyscale operator object storage credentials" \
  --expires-at "${ACCESS_KEY_EXPIRATION}" \
  --format json)

ACCESS_KEY_ID=$(echo "${ACCESS_KEY}" | jq -r '.resource_id')
AWS_ACCESS_KEY_ID=$(nebius iam access-key get-by-id \
  --id "${ACCESS_KEY_ID}" \
  --format json | jq -r '.status.aws_access_key_id')
AWS_SECRET_ACCESS_KEY=$(nebius iam access-key get-secret-once \
  --id "${ACCESS_KEY_ID}" \
  --format json | jq -r '.secret')

if [[ -z "${AWS_ACCESS_KEY_ID}" || -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
  echo "❌ Failed to retrieve AWS-compatible credentials from Nebius." >&2
  exit 1
fi

AWS_ENDPOINT="https://storage.${REGION}.nebius.cloud:443"

TMP_VALUES_FILE=$(mktemp)
trap 'rm -f "${TMP_VALUES_FILE}"' EXIT

cat > "${TMP_VALUES_FILE}" <<EOF
cloudDeploymentId: "${CLOUD_DEPLOYMENT_ID}"
cloudProvider: "generic"
region: "${REGION}"
anyscaleCliToken: "${CLI_TOKEN}"
aws:
  credentialSecret:
    enabled: true
    create: true
    name: ${CREDENTIAL_SECRET_NAME}
    accessKeyId: "${AWS_ACCESS_KEY_ID}"
    secretAccessKey: "${AWS_SECRET_ACCESS_KEY}"
    endpointUrl: "${AWS_ENDPOINT}"
EOF

echo "📦 Fetching kubeconfig for cluster (id: ${CLUSTER_ID})..."
nebius mk8s cluster get-credentials \
  --id "${CLUSTER_ID}" \
  --external \
  --force \
  --context-name "nebius-mk8s-anyscale-cluster-v2" >/dev/null

echo "🚀 Installing/Upgrading Anyscale operator via Helm..."
helm upgrade --install "${RELEASE_NAME}" "${EXAMPLE_DIR}/charts/anyscale-operator" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f "${EXAMPLE_DIR}/values/anyscale-operator.yaml" \
  -f "${TMP_VALUES_FILE}" \
  --wait

echo ""
echo "✅ Anyscale operator deployment complete."
echo ""
echo "Summary:"
echo "  • Release: ${RELEASE_NAME}"
echo "  • Namespace: ${NAMESPACE}"
echo "  • Cluster: ${CLUSTER_NAME} (${CLUSTER_ID})"
echo "  • Bucket: s3://${BUCKET_NAME}"
echo "  • Credential secret: ${CREDENTIAL_SECRET_NAME}"
echo "  • Access key expires: ${ACCESS_KEY_EXPIRATION}"
echo ""
echo "Next steps:"
echo "  1. Verify operator pods: kubectl get pods -n ${NAMESPACE}"
echo "  2. Confirm cloud status in Anyscale console."
echo "  3. Consider rotating/deleting old Nebius access keys if re-running this script."
