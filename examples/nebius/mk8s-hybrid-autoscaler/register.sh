#!/bin/bash

# ============================================================================
# ANYSCALE CLOUD REGISTRATION SCRIPT
# ============================================================================
# Usage: ./register.sh
# Registers a new Anyscale cloud using config.yaml and terraform outputs
# ============================================================================

set -euo pipefail

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check if anyscale CLI is available
if ! command -v anyscale &> /dev/null; then
  echo "❌ Error: anyscale CLI not found in PATH"
  echo "   Install from: https://docs.anyscale.com/cli/"
  exit 1
fi

# Parse config.yaml for cloud name and region
CLOUD_NAME=$(grep "cloud_name:" config.yaml | awk '{print $2}' | tr -d '"')
REGION=$(grep "region:" config.yaml | awk '{print $2}' | tr -d '"')

# Get infrastructure outputs from terraform
echo "📦 Getting infrastructure details from Terraform..."
cd prepare

BUCKET_NAME=$(terraform output -raw bucket_name 2>/dev/null)
if [ $? -ne 0 ]; then
  echo "❌ Error: Could not get bucket name from terraform output"
  echo "   Make sure you've run 'terraform apply' in prepare/ first"
  exit 1
fi

NFS_IP=$(terraform output -raw nfs_server_ip 2>/dev/null)
if [ "$NFS_IP" == "NFS disabled" ]; then
  echo "⚠️  NFS is disabled in config.yaml"
  NFS_ARGS=""
else
  echo "✅ NFS enabled at: $NFS_IP"
  NFS_ARGS="--nfs-mount-target $NFS_IP --nfs-mount-path /nfs"
fi

cd "$SCRIPT_DIR"

echo ""
echo "🚀 Registering Anyscale cloud..."
echo "   Name: $CLOUD_NAME"
echo "   Region: $REGION"
echo "   Bucket: $BUCKET_NAME"
echo ""

# Ensure Anyscale CLI is logged in
if ! anyscale workspace list >/dev/null 2>&1; then
  echo "🔐 Not logged in to Anyscale. Running login..."
  anyscale login
fi

# Register the cloud
anyscale cloud register \
  --provider generic \
  --region "$REGION" \
  --name "$CLOUD_NAME" \
  --compute-stack k8s \
  --cloud-storage-bucket-name "s3://${BUCKET_NAME}" \
  --cloud-storage-bucket-endpoint "https://storage.${REGION}.nebius.cloud:443" \
  $NFS_ARGS

echo ""
echo "✅ Cloud registered successfully!"
echo ""
echo "📋 Next steps:"
echo "   1. Deploy the cluster (Step 5 in the README): cd deploy && terraform apply"
echo "   2. Install/upgrade the operator: ./deploy/install-operator.sh"
echo "      (the script auto-discovers the deployment ID for '${CLOUD_NAME}')"
echo "   3. Verify the cloud once the operator is healthy:"
echo "        anyscale cloud verify --name ${CLOUD_NAME}"
echo ""
