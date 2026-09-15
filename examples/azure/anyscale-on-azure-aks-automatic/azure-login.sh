#!/usr/bin/env bash
# Azure CLI login and (optionally) select a subscription.
# Anyscale operator marketplace offer (create directly in the portal):
#   https://portal.azure.com/#create/anyscale1750870039553.anyscale-operator-aksanyscale-operator
#
# Usage:
#   ./azure-login.sh                 # log in, keep the default subscription
#   ./azure-login.sh <sub-id|name>   # log in and switch to that subscription
#   AZURE_SUBSCRIPTION=<sub> ./azure-login.sh

set -euo pipefail

if ! command -v az &>/dev/null; then
  echo "az not found. Install the Azure CLI first: https://learn.microsoft.com/cli/azure/install-azure-cli"
  exit 1
fi

# Subscription is optional: pass it as the first arg or via AZURE_SUBSCRIPTION.
# Nothing is hard-coded — if unset, the CLI's current default is kept.
SUBSCRIPTION="${1:-${AZURE_SUBSCRIPTION:-}}"

echo ">>> Signing in to Azure (a browser window will open)..."
az login >/dev/null

if [[ -n "$SUBSCRIPTION" ]]; then
  echo ">>> Selecting subscription: $SUBSCRIPTION"
  az account set --subscription "$SUBSCRIPTION"
fi

echo ""
echo "Active subscription:"
az account show --query '{name:name, id:id, tenant:tenantId}' -o table
echo ""
echo "Anyscale operator offer: https://portal.azure.com/#create/anyscale1750870039553.anyscale-operator-aksanyscale-operator"
