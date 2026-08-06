#!/bin/bash

# ============================================================================
# NEBIUS ENVIRONMENT SETUP
# ============================================================================
# Sets up IAM token, terraform backend, and service account credentials
# Loads configuration from config.yaml
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔐 Setting up Nebius environment..."

# Check if nebius CLI is available
if ! command -v nebius &> /dev/null; then
  echo "❌ Error: nebius CLI not found in PATH"
  echo "   Install from: https://docs.nebius.ai/cli/"
  return 1
fi

# Load config from config.yaml
if [ ! -f config.yaml ]; then
  echo "❌ Error: config.yaml not found"
  echo "   Copy config.example.yaml to config.yaml and fill in your details"
  return 1
fi

NEBIUS_TENANT_ID=$(grep "tenant_id:" config.yaml | awk '{print $2}' | tr -d '"')
NEBIUS_PROJECT_ID=$(grep "project_id:" config.yaml | awk '{print $2}' | tr -d '"')
NEBIUS_REGION=$(grep "region:" config.yaml | head -1 | awk '{print $2}' | tr -d '"')

if [ -z "${NEBIUS_TENANT_ID}" ] || [ -z "${NEBIUS_PROJECT_ID}" ] || [ -z "${NEBIUS_REGION}" ]; then
  echo "❌ Error: Missing required fields in config.yaml"
  echo "   Please fill in: tenant_id, project_id, region"
  return 1
fi

# Get IAM token
export NEBIUS_IAM_TOKEN=$(nebius iam get-access-token)
if [ -z "${NEBIUS_IAM_TOKEN}" ]; then
  echo "❌ Error: Failed to get Nebius IAM token"
  echo "   Please run: nebius init"
  return 1
fi

# Terraform backend bucket for state
export NEBIUS_BUCKET_NAME="tfstate-anyscale-$(echo -n "${NEBIUS_TENANT_ID}-${NEBIUS_PROJECT_ID}" | md5sum | awk '$0=$1' 2>/dev/null || echo -n "${NEBIUS_TENANT_ID}-${NEBIUS_PROJECT_ID}" | md5 | awk '$0=$1')"

echo "📦 Checking terraform state bucket..."
EXISTS=$(nebius storage bucket list \
  --parent-id "${NEBIUS_PROJECT_ID}" \
  --format json \
  | jq -r --arg BUCKET "${NEBIUS_BUCKET_NAME}" 'try .items[] | select(.metadata.name == $BUCKET) | .metadata.name')

if [ -z "${EXISTS}" ]; then
  echo "   Creating bucket: ${NEBIUS_BUCKET_NAME}"
  nebius storage bucket create \
    --name "${NEBIUS_BUCKET_NAME}" \
    --parent-id "${NEBIUS_PROJECT_ID}" \
    --versioning-policy 'enabled' >/dev/null
else
  echo "   Using existing bucket: ${NEBIUS_BUCKET_NAME}"
fi

# Service account for terraform backend
echo "🔑 Checking service account..."
NEBIUS_SA_NAME="anyscale-sa"
NEBIUS_SA_ID=$(nebius iam service-account list \
  --parent-id "${NEBIUS_PROJECT_ID}" \
  --format json \
  | jq -r --arg SANAME "${NEBIUS_SA_NAME}" 'try .items[] | select(.metadata.name == $SANAME).metadata.id')

if [ -z "$NEBIUS_SA_ID" ]; then
  echo "   Creating service account: ${NEBIUS_SA_NAME}"
  NEBIUS_SA_ID=$(nebius iam service-account create \
    --parent-id "${NEBIUS_PROJECT_ID}" \
    --name "${NEBIUS_SA_NAME}" \
    --format json \
    | jq -r '.metadata.id')
else
  echo "   Using existing service account: ${NEBIUS_SA_NAME}"
fi

# Add service account to editors group
NEBIUS_GROUP_EDITORS_ID=$(nebius iam group get-by-name \
  --parent-id "${NEBIUS_TENANT_ID}" \
  --name 'editors' \
  --format json \
  | jq -r '.metadata.id')

IS_MEMBER=$(nebius iam group-membership list-members \
  --parent-id "${NEBIUS_GROUP_EDITORS_ID}" \
  --page-size 1000 \
  --format json \
  | jq -r --arg SAID "${NEBIUS_SA_ID}" '.memberships[] | select(.spec.member_id == $SAID) | .spec.member_id')

if [ -z "${IS_MEMBER}" ]; then
  echo "   Adding service account to editors group..."
  nebius iam group-membership create \
    --parent-id "${NEBIUS_GROUP_EDITORS_ID}" \
    --member-id "${NEBIUS_SA_ID}" >/dev/null
fi

# Create access key for S3 backend
echo "🗝️  Creating temporary access key..."
DATE_FORMAT='+%Y-%m-%dT%H:%M:%SZ'
if [[ "$(uname)" == "Darwin" ]]; then
  EXPIRATION_DATE=$(date -v +1d "${DATE_FORMAT}")
else
  EXPIRATION_DATE=$(date -d '+1 day' "${DATE_FORMAT}")
fi

NEBIUS_SA_ACCESS_KEY_ID=$(nebius iam access-key create \
  --parent-id "${NEBIUS_PROJECT_ID}" \
  --name "anyscale-tfstate-$(date +%s)" \
  --account-service-account-id "${NEBIUS_SA_ID}" \
  --description 'Temporary Object Storage Access for Terraform' \
  --expires-at "${EXPIRATION_DATE}" \
  --format json \
  | jq -r '.resource_id')

# Get AWS-compatible credentials
export AWS_ACCESS_KEY_ID=$(nebius iam access-key get-by-id \
  --id "${NEBIUS_SA_ACCESS_KEY_ID}" \
  --format json | jq -r '.status.aws_access_key_id')
export AWS_SECRET_ACCESS_KEY=$(nebius iam access-key get-secret-once \
  --id "${NEBIUS_SA_ACCESS_KEY_ID}" \
  --format json \
  | jq -r '.secret')

# Generate terraform backend configuration
cat > terraform_backend_override.tf << EOF
terraform {
  backend "s3" {
    bucket = "${NEBIUS_BUCKET_NAME}"
    key    = "anyscale.tfstate"

    endpoints = {
      s3 = "https://storage.${NEBIUS_REGION}.nebius.cloud:443"
    }
    region = "${NEBIUS_REGION}"

    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
EOF

echo ""
echo "✅ Environment configured successfully!"
echo ""
echo "📋 Summary:"
echo "   Region: ${NEBIUS_REGION}"
echo "   Project: ${NEBIUS_PROJECT_ID}"
echo "   State bucket: ${NEBIUS_BUCKET_NAME}"
echo "   Service account: ${NEBIUS_SA_NAME}"
echo "   Access key expires: $(echo $EXPIRATION_DATE | cut -d'T' -f1)"
echo ""
echo "Next steps:"
echo "  1. cd prepare && terraform init && terraform apply"
echo "  2. ./register.sh"
echo "  3. cd deploy && terraform init && terraform apply"
echo "  4. ./deploy/install-operator.sh"
echo ""
