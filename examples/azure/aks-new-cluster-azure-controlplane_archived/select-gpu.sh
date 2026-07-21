#!/usr/bin/env bash
# Interactive GPU picker for the Anyscale-on-Azure example.
#
# The example ships with NO GPU node pools by default (var.gpu_pool_configs = {}),
# so a plain `terraform apply` never tries to create a GPU SKU that has no quota
# or capacity in your region. Use this script to opt in to GPU pools.
#
# Flow:
#   1. Ask which GPU type you want, from the Anyscale-supported Azure catalog.
#   2. If you don't have one in mind, scan your chosen region for GPU SKUs that
#      are BOTH available to your subscription AND have vCPU quota headroom.
#   3. Write the chosen `gpu_pool_configs` block into terraform.tfvars.
#
# Each selected GPU type becomes one on-demand pool AND one spot pool in aks.tf.
#
# Usage:
#   ./select-gpu.sh                  # interactive: choose or scan, then write tfvars
#   ./select-gpu.sh --region eastus2 # scan/validate against a specific region
#   ./select-gpu.sh --scan           # jump straight to the region scan
#   ./select-gpu.sh --no-write       # choose only; don't edit terraform.tfvars
#
# Optional environment variables:
#   AZURE_SUBSCRIPTION   Subscription ID or name (default: current az account)
#   GPU_SCAN_REGION      Region to validate against (default: azure_location in
#                        terraform.tfvars, else westus2)
#   TFVARS_FILE          Target tfvars file to update (default: terraform.tfvars)

set -euo pipefail

# -----------------------------------------------------------------------------
# Anyscale-supported Azure GPU catalog — SINGLE SOURCE OF TRUTH for this script.
# Format: KEY|POOL_NAME|VM_SIZE|PRODUCT_NAME|GPU_COUNT
#   KEY          logical map key written into gpu_pool_configs (e.g. "A100")
#   POOL_NAME    AKS node pool name: lowercase alphanumeric, <= 8 chars
#                (spot pools append "spot", AKS allows 12)
#   VM_SIZE      Azure VM SKU
#   PRODUCT_NAME nvidia.com/gpu.product node label the Anyscale operator selects on
#   GPU_COUNT    GPUs per VM
# These are the NVIDIA accelerator products Anyscale recognises on Azure. Keep the
# product_name values aligned with the operator's instance-type catalog.
# -----------------------------------------------------------------------------
GPU_CATALOG=(
  "T4|gput4|Standard_NC16as_T4_v3|NVIDIA-T4|1"
  "A10|gpua10|Standard_NV36ads_A10_v5|NVIDIA-A10|1"
  "A100|gpua100|Standard_NC24ads_A100_v4|NVIDIA-A100|1"
  "A100x8|a100x8|Standard_ND96amsr_A100_v4|NVIDIA-A100|8"
  "H100|gpuh100|Standard_NC40ads_H100_v5|NVIDIA-H100|1"
  "H100x8|h100x8|Standard_ND96isr_H100_v5|NVIDIA-H100|8"
)

TFVARS_FILE="${TFVARS_FILE:-terraform.tfvars}"

WRITE=1
SCAN_FIRST=0
REGION_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-write) WRITE=0 ;;
    --scan)     SCAN_FIRST=1 ;;
    --region)   REGION_ARG="${2:-}"; shift ;;
    --region=*) REGION_ARG="${1#*=}" ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

if ! command -v az &>/dev/null || ! command -v jq &>/dev/null; then
  echo "Requires: az (Azure CLI) and jq. Install with: brew install azure-cli jq" >&2
  exit 1
fi

if ! az account show &>/dev/null; then
  echo "Not signed in to Azure. Run ./azure-login.sh (or 'az login') first." >&2
  exit 1
fi

SUBSCRIPTION="${AZURE_SUBSCRIPTION:-$(az account show --query id -o tsv)}"
SUB_NAME="$(az account show --subscription "$SUBSCRIPTION" --query name -o tsv 2>/dev/null || echo "$SUBSCRIPTION")"

# -----------------------------------------------------------------------------
# Resolve the region: --region > GPU_SCAN_REGION > azure_location in tfvars > default.
# -----------------------------------------------------------------------------
tfvars_region=""
if [[ -f "$TFVARS_FILE" ]]; then
  tfvars_region="$(grep -E '^[[:space:]]*azure_location[[:space:]]*=' "$TFVARS_FILE" 2>/dev/null \
    | head -1 | sed -E 's/.*=[[:space:]]*"?([a-z0-9]+)"?.*/\1/' || true)"
fi
REGION="${REGION_ARG:-${GPU_SCAN_REGION:-${tfvars_region:-westus2}}}"

echo "=============================================================================="
echo "ANYSCALE-ON-AZURE — GPU NODE POOL SELECTION"
echo "=============================================================================="
echo "Subscription:    $SUB_NAME"
echo "Subscription ID: $SUBSCRIPTION"
echo "Region:          $REGION   (override with --region <name>)"
echo ""

# -----------------------------------------------------------------------------
# Scan the region once: which catalog SKUs are available + have quota?
# Populates AVAIL[idx] = ok|restricted|missing and FREE[idx] = free vCPUs (-1 unknown),
# VCPUS[idx] = vCPUs per VM. Lazily run only when needed (menu choice 's' or --scan).
# -----------------------------------------------------------------------------
declare -a AVAIL=() FREE=() VCPUS=()
SCANNED=0

scan_region() {
  [[ "$SCANNED" == "1" ]] && return 0
  echo "Scanning $REGION for GPU SKU availability and quota (this takes a moment)..."
  echo ""

  local skus usage
  skus="$(az vm list-skus -l "$REGION" --resource-type virtualMachines --all -o json 2>/dev/null || echo '[]')"
  usage="$(az vm list-usage -l "$REGION" --subscription "$SUBSCRIPTION" -o json 2>/dev/null || echo '[]')"

  local i entry vm_size sku vcpus family avail free
  for i in "${!GPU_CATALOG[@]}"; do
    IFS='|' read -r _ _ vm_size _ _ <<<"${GPU_CATALOG[$i]}"

    sku="$(echo "$skus" | jq -c --arg n "$vm_size" 'map(select(.name==$n)) | .[0] // null')"
    if [[ "$sku" == "null" || -z "$sku" ]]; then
      AVAIL[$i]="missing"; VCPUS[$i]=0; FREE[$i]=-1; continue
    fi

    # Available unless a Location restriction makes it NotAvailableForSubscription.
    avail="$(echo "$sku" | jq -r '
      (.restrictions // [])
      | map(select(.type=="Location" and .reasonCode=="NotAvailableForSubscription"))
      | if length > 0 then "restricted" else "ok" end')"
    vcpus="$(echo "$sku" | jq -r '(.capabilities // []) | map(select(.name=="vCPUs"))[0].value // "0"')"
    family="$(echo "$sku" | jq -r '.family // ""')"

    # Free vCPUs in that SKU's quota family (-1 if the family is not reported).
    free="$(echo "$usage" | jq -r --arg f "$family" '
      map(select(.name.value==$f))[0]
      | if . == null then -1 else ((.limit|tonumber) - (.currentValue|tonumber)) end')"

    AVAIL[$i]="$avail"; VCPUS[$i]="$vcpus"; FREE[$i]="$free"
  done
  SCANNED=1
}

# Deployable = available in region AND quota family has room for >= 1 VM.
is_deployable() {
  local i="$1"
  [[ "${AVAIL[$i]:-}" == "ok" ]] || return 1
  local free="${FREE[$i]:--1}" vcpus="${VCPUS[$i]:-0}"
  # Unknown quota family (-1) → don't block; let apply surface a quota error if any.
  [[ "$free" == "-1" ]] && return 0
  (( free >= vcpus ))
}

status_label() {
  local i="$1"
  [[ "$SCANNED" == "1" ]] || { echo ""; return; }
  case "${AVAIL[$i]:-}" in
    missing)    echo "not offered in $REGION" ;;
    restricted) echo "NOT available to your subscription in $REGION" ;;
    ok)
      local free="${FREE[$i]:--1}" vcpus="${VCPUS[$i]:-0}"
      if [[ "$free" == "-1" ]]; then echo "available (quota unknown)"
      elif (( free >= vcpus )); then echo "deployable — ${free} free vCPUs (needs ${vcpus})"
      else echo "available but NO quota — ${free} free vCPUs (needs ${vcpus})"
      fi ;;
    *) echo "" ;;
  esac
}

print_catalog() {
  local i key pool vm_size product count st
  printf "  %-3s %-8s %-28s %-16s %-5s %s\n" "#" "TYPE" "VM_SIZE" "PRODUCT" "GPUS" "$([[ $SCANNED == 1 ]] && echo "STATUS ($REGION)")"
  for i in "${!GPU_CATALOG[@]}"; do
    IFS='|' read -r key pool vm_size product count <<<"${GPU_CATALOG[$i]}"
    st="$(status_label "$i")"
    printf "  %-3s %-8s %-28s %-16s %-5s %s\n" "$((i + 1))" "$key" "$vm_size" "$product" "$count" "$st"
  done
}

# -----------------------------------------------------------------------------
# Menu.
# -----------------------------------------------------------------------------
[[ "$SCAN_FIRST" == "1" ]] && scan_region

echo "Anyscale-supported Azure GPU SKUs:"
echo "------------------------------------------------------------------------------"
print_catalog
echo ""
echo "Each type you pick becomes one ON-DEMAND pool + one SPOT pool (autoscaling 0-10)."
echo ""
echo "Choose:"
echo "  - one or more numbers (comma-separated, e.g. 1,3) to select those GPU types"
echo "  - s : scan $REGION and show which are actually deployable, then choose"
echo "  - n : none — deploy CPU-only (clears gpu_pool_configs)"
echo "  - q : quit without changes"
echo ""

declare -a SELECTED_IDX=()

parse_selection() {
  # Validate a comma/space-separated list of 1-based catalog numbers.
  local raw="$1" tok idx
  SELECTED_IDX=()
  for tok in ${raw//,/ }; do
    if [[ ! "$tok" =~ ^[0-9]+$ ]]; then echo "  '$tok' is not a number." >&2; return 1; fi
    idx=$((tok - 1))
    if (( idx < 0 || idx >= ${#GPU_CATALOG[@]} )); then
      echo "  $tok is out of range (1-${#GPU_CATALOG[@]})." >&2; return 1
    fi
    SELECTED_IDX+=("$idx")
  done
  [[ "${#SELECTED_IDX[@]}" -gt 0 ]]
}

while true; do
  read -r -p "Selection > " choice
  case "$choice" in
    q|Q) echo "Aborted. No changes made."; exit 0 ;;
    n|N) SELECTED_IDX=(); break ;;
    s|S)
      scan_region
      echo ""
      echo "Deployable GPU types in $REGION:"
      echo "------------------------------------------------------------------------------"
      print_catalog
      echo ""
      any_deployable=0
      for i in "${!GPU_CATALOG[@]}"; do is_deployable "$i" && any_deployable=1; done
      if [[ "$any_deployable" == "0" ]]; then
        echo "No catalog GPU SKU is deployable in $REGION (none available with quota)."
        echo "Options: request GPU quota (Azure Portal > Usage + quotas), pick another"
        echo "region with ./select-region.sh, or choose 'n' for a CPU-only cluster."
        echo ""
      fi
      echo "Enter number(s) of the GPU type(s) to use (or n / q):"
      ;;
    '') echo "  Enter a number, s, n, or q." ;;
    *)
      if parse_selection "$choice"; then
        # If we've scanned, warn (don't block) on non-deployable picks.
        if [[ "$SCANNED" == "1" ]]; then
          for i in "${SELECTED_IDX[@]}"; do
            if ! is_deployable "$i"; then
              IFS='|' read -r key _ _ _ _ <<<"${GPU_CATALOG[$i]}"
              echo "  WARNING: $key is '$(status_label "$i")'. apply may fail."
            fi
          done
        fi
        break
      fi
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Build the gpu_pool_configs HCL block.
# -----------------------------------------------------------------------------
build_block() {
  local i key pool vm_size product count
  if [[ "${#SELECTED_IDX[@]}" -eq 0 ]]; then
    echo "gpu_pool_configs = {}"
    return
  fi
  echo "gpu_pool_configs = {"
  for i in "${SELECTED_IDX[@]}"; do
    IFS='|' read -r key pool vm_size product count <<<"${GPU_CATALOG[$i]}"
    printf '  %s = {\n' "$key"
    printf '    name         = "%s"\n' "$pool"
    printf '    vm_size      = "%s"\n' "$vm_size"
    printf '    product_name = "%s"\n' "$product"
    printf '    gpu_count    = "%s"\n' "$count"
    printf '  }\n'
  done
  echo "}"
}

BLOCK="$(build_block)"

echo ""
echo "=============================================================================="
echo "gpu_pool_configs"
echo "=============================================================================="
echo "$BLOCK"
echo ""

if [[ "$WRITE" == "0" ]]; then
  echo "Skipping $TFVARS_FILE update (--no-write). To apply manually, paste the block"
  echo "above into terraform.tfvars, or pass it via -var-file."
  exit 0
fi

# -----------------------------------------------------------------------------
# Write into terraform.tfvars: remove any existing top-level gpu_pool_configs
# block (brace-balanced), then append the new one.
# -----------------------------------------------------------------------------
[[ -f "$TFVARS_FILE" ]] || : >"$TFVARS_FILE"

if grep -qE '^[[:space:]]*gpu_pool_configs[[:space:]]*=' "$TFVARS_FILE"; then
  tmp="$(mktemp)"
  awk '
    skip == 1 {
      depth += gsub(/{/, "{") - gsub(/}/, "}")
      if (depth <= 0) skip = 0
      next
    }
    $0 ~ /^[[:space:]]*gpu_pool_configs[[:space:]]*=/ {
      skip = 1
      depth = gsub(/{/, "{") - gsub(/}/, "}")
      if (depth <= 0) skip = 0
      next
    }
    { print }
  ' "$TFVARS_FILE" >"$tmp"
  # Drop trailing blank lines left behind, then re-append the new block.
  awk 'NF {blank=0} !NF {blank++} {lines[NR]=$0} END {for(i=1;i<=NR-blank;i++) print lines[i]}' "$tmp" >"$TFVARS_FILE"
  rm -f "$tmp"
  echo "Replaced existing gpu_pool_configs in $TFVARS_FILE"
else
  echo "Appended gpu_pool_configs to $TFVARS_FILE"
fi

{
  echo ""
  echo "$BLOCK"
} >>"$TFVARS_FILE"

echo ""
echo "Next:"
echo "  terraform plan      # review the GPU node pools that will be created"
echo "  terraform apply"
