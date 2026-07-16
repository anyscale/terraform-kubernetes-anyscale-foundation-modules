#!/usr/bin/env bash
# Interactive region picker for the Anyscale-on-Azure example.
#
# Flow:
#   1. Print the regions where Anyscale.Platform/clouds is supported.
#   2. Scan your subscription's CPU (and GPU) quota in each of those regions.
#   3. Prompt you to choose a deployable region and write it to terraform.tfvars
#      as `azure_location`.
#
# Usage:
#   ./select-region.sh                 # interactive: scan, choose, write tfvars
#   ./select-region.sh --detailed      # also print the full scan-regional-quotas.sh report
#   ./select-region.sh --no-write      # scan + choose, but don't touch terraform.tfvars
#
# Optional environment variables:
#   AZURE_SUBSCRIPTION   Subscription ID or name (default: current az account)
#   MIN_CPU_VCPUS        Minimum free regional vCPUs to consider a region deployable
#                        (default: 24 — headroom for the system + CPU node pools)
#   CPU_VM_SIZE          VM size used to derive the CPU family quota check
#                        (default: Standard_D16s_v5, matching var.cpu_vm_size)
#   TFVARS_FILE          Target tfvars file to update (default: terraform.tfvars)

set -euo pipefail

# -----------------------------------------------------------------------------
# Anyscale-supported regions — SINGLE SOURCE OF TRUTH for this script.
# Keep in sync with the validation block in variables.tf, the README, and
# terraform.tfvars.example.
# -----------------------------------------------------------------------------
ANYSCALE_REGIONS=(
  westcentralus eastus eastus2 westus2 westus3
  southcentralus westeurope swedencentral uksouth
  australiaeast southeastasia northeurope
)

MIN_CPU_VCPUS="${MIN_CPU_VCPUS:-24}"
CPU_VM_SIZE="${CPU_VM_SIZE:-Standard_D16s_v5}"
TFVARS_FILE="${TFVARS_FILE:-terraform.tfvars}"
GPU_FAMILY_RE='Standard NC|Standard ND|Standard NV|Standard NG|NDISR'

DETAILED=0
WRITE=1
for arg in "$@"; do
  case "$arg" in
    --detailed)  DETAILED=1 ;;
    --no-write)  WRITE=0 ;;
    -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
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

# Map the CPU VM size to a quota-family regex (mirrors scan-regional-quotas.sh).
CPU_FAMILY_PATTERN=""
case "$CPU_VM_SIZE" in
  Standard_D*s_v5|Standard_D*_v5) CPU_FAMILY_PATTERN='DSv5|Dsv5|Dv5' ;;
  Standard_D*s_v6|Standard_D*_v6) CPU_FAMILY_PATTERN='DSv6|Dsv6|Dv6' ;;
  Standard_E*s_v5|Standard_E*_v5) CPU_FAMILY_PATTERN='ESv5|Esv5|Ev5' ;;
esac

echo "=============================================================================="
echo "ANYSCALE-SUPPORTED AZURE REGIONS"
echo "=============================================================================="
echo "Anyscale.Platform/clouds is supported only in these regions:"
echo ""
printf '  %s\n' "${ANYSCALE_REGIONS[@]}" | column 2>/dev/null || printf '  %s\n' "${ANYSCALE_REGIONS[@]}"
echo ""
echo "Subscription:    $SUB_NAME"
echo "Subscription ID: $SUBSCRIPTION"
echo "Deployable if:   >= ${MIN_CPU_VCPUS} free regional vCPUs"
[[ -n "$CPU_FAMILY_PATTERN" ]] && echo "                 + headroom in the ${CPU_VM_SIZE} family (/${CPU_FAMILY_PATTERN}/)"
echo ""
echo "Scanning quota in ${#ANYSCALE_REGIONS[@]} regions (this takes a moment)..."
echo ""

# -----------------------------------------------------------------------------
# Scan each supported region. Builds parallel arrays:
#   DEPLOYABLE[]  — region names that meet the CPU requirement
#   ROWS[]        — display rows (region | cpu usage | free | gpu summary)
# -----------------------------------------------------------------------------
declare -a DEPLOYABLE=()
declare -a ROWS=()

for region in "${ANYSCALE_REGIONS[@]}"; do
  json="$(az vm list-usage -l "$region" --subscription "$SUBSCRIPTION" -o json 2>/dev/null)" || json=""
  if [[ -z "$json" ]] || ! echo "$json" | jq -e . >/dev/null 2>&1; then
    ROWS+=("$region|n/a|0|unavailable|0")
    continue
  fi

  read -r ok usage avail gpu <<<"$(echo "$json" | jq -r \
    --argjson min "$MIN_CPU_VCPUS" \
    --arg gpu_re "$GPU_FAMILY_RE" \
    --arg cpu_fam_re "$CPU_FAMILY_PATTERN" '
    (.[] | select(.name.value == "cores")) as $cores |
    (if $cores == null then 0
     else (($cores.limit | tonumber) - ($cores.currentValue | tonumber)) end) as $cpu_avail |
    (if $cores == null then "n/a"
     else "\($cores.currentValue)/\($cores.limit)" end) as $cpu_usage |
    # CPU family headroom (if a pattern was supplied)
    (if ($cpu_fam_re | length) == 0 then $cpu_avail
     else
       ([ .[]
          | select(.name.localizedValue | test($cpu_fam_re; "i"))
          | select((.limit | tonumber) > 0)
          | ((.limit | tonumber) - (.currentValue | tonumber)) ] | max // 0)
     end) as $fam_avail |
    # GPU families with any headroom
    ([ .[]
       | select((.limit | tonumber) > 0)
       | select(.name.localizedValue | test($gpu_re; "i"))
       | select(((.limit | tonumber) - (.currentValue | tonumber)) > 0) ] | length) as $gpu_count |
    (($cpu_avail >= $min) and ($fam_avail >= $min)) as $ok |
    "\(if $ok then 1 else 0 end) \($cpu_usage) \($cpu_avail) \($gpu_count)"
  ')"

  if [[ "$gpu" -gt 0 ]]; then
    gpu_label="${gpu} GPU famil$([[ "$gpu" -eq 1 ]] && echo y || echo ies)"
  else
    gpu_label="no GPU"
  fi

  ROWS+=("$region|$usage|$avail|$gpu_label|$ok")
  [[ "$ok" == "1" ]] && DEPLOYABLE+=("$region")
done

# -----------------------------------------------------------------------------
# Print the scan results.
# -----------------------------------------------------------------------------
echo "QUOTA SCAN RESULTS"
echo "------------------------------------------------------------------------------"
printf "  %-3s %-16s %-14s %-8s %-16s %s\n" "#" "REGION" "CPU_USAGE" "FREE" "GPU" "DEPLOYABLE"
idx=0
for row in "${ROWS[@]}"; do
  IFS='|' read -r region usage avail gpu ok <<<"$row"
  if [[ "$ok" == "1" ]]; then
    idx=$((idx + 1))
    mark="$idx"
    flag="yes"
  else
    mark="-"
    flag="no"
  fi
  printf "  %-3s %-16s %-14s %-8s %-16s %s\n" "$mark" "$region" "$usage" "$avail" "$gpu" "$flag"
done
echo ""

if [[ "$DETAILED" == "1" ]]; then
  echo "Running full scan-regional-quotas.sh report on supported regions..."
  echo ""
  REGIONS="${ANYSCALE_REGIONS[*]}" NODE_VM_SIZE="$CPU_VM_SIZE" \
    MIN_CPU_VCPUS="$MIN_CPU_VCPUS" AZURE_SUBSCRIPTION="$SUBSCRIPTION" \
    "$(dirname "$0")/scan-regional-quotas.sh" || true
  echo ""
fi

if [[ "${#DEPLOYABLE[@]}" -eq 0 ]]; then
  echo "No Anyscale-supported region meets the ${MIN_CPU_VCPUS}-vCPU requirement." >&2
  echo "Request a quota increase (Azure Portal > Subscriptions > Usage + quotas)," >&2
  echo "or re-run with a lower threshold: MIN_CPU_VCPUS=12 ./select-region.sh" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Prompt for a choice.
# -----------------------------------------------------------------------------
echo "=============================================================================="
echo "SELECT A REGION"
echo "=============================================================================="
echo "Enter the number of a deployable region (1-${#DEPLOYABLE[@]}), or q to quit:"
printf '  %2d) %s\n' $(for i in "${!DEPLOYABLE[@]}"; do echo $((i + 1)); echo "${DEPLOYABLE[$i]}"; done)
echo ""

choice=""
while true; do
  read -r -p "Region # > " choice
  case "$choice" in
    q|Q) echo "Aborted. No changes made."; exit 0 ;;
    ''|*[!0-9]*) echo "  Please enter a number between 1 and ${#DEPLOYABLE[@]} (or q)." ;;
    *)
      if (( choice >= 1 && choice <= ${#DEPLOYABLE[@]} )); then
        break
      fi
      echo "  Out of range. Enter 1-${#DEPLOYABLE[@]} (or q)."
      ;;
  esac
done

SELECTED="${DEPLOYABLE[$((choice - 1))]}"
echo ""
echo "Selected region: $SELECTED"

if [[ "$WRITE" == "0" ]]; then
  echo ""
  echo "Skipping terraform.tfvars update (--no-write). To apply manually:"
  echo "  terraform apply -var=\"azure_location=$SELECTED\""
  exit 0
fi

# -----------------------------------------------------------------------------
# Write azure_location into terraform.tfvars.
# -----------------------------------------------------------------------------
if [[ -f "$TFVARS_FILE" ]] && grep -qE '^[[:space:]]*azure_location[[:space:]]*=' "$TFVARS_FILE"; then
  tmp="$(mktemp)"
  sed -E "s|^([[:space:]]*azure_location[[:space:]]*=[[:space:]]*).*|\1\"$SELECTED\"|" "$TFVARS_FILE" >"$tmp"
  mv "$tmp" "$TFVARS_FILE"
  echo "Updated azure_location in $TFVARS_FILE"
else
  printf 'azure_location = "%s"\n' "$SELECTED" >>"$TFVARS_FILE"
  echo "Appended azure_location to $TFVARS_FILE"
fi

echo ""
echo "Next: review $TFVARS_FILE, then run:"
echo "  terraform init"
echo "  terraform apply"
