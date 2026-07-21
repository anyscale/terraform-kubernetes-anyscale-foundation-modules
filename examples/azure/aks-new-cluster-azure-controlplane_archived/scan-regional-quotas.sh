#!/usr/bin/env bash
# Scan Azure regions for CPU and GPU deployment capacity from subscription quotas.
#
# Usage:
#   ./scan-regional-quotas.sh              # summary only (recommended)
#   VERBOSE=1 ./scan-regional-quotas.sh    # summary + per-region detail
#
# Optional environment variables:
#   AZURE_SUBSCRIPTION     Subscription ID or name (default: current account)
#   REGIONS                Explicit region list (space- or comma-separated) to scan
#                          instead of discovering via az account list-locations.
#                          e.g. REGIONS="eastus westus2 westeurope". Used by
#                          select-region.sh to restrict the scan to Anyscale-
#                          supported regions.
#   REGION_FILTER          JMESPath filter for az account list-locations
#   MIN_CPU_VCPUS          Minimum free regional vCPUs required (default: 12 = 3x D4s_v5)
#   MIN_GPU_VCPUS          Minimum free vCPUs per GPU family (default: 1)
#   CPU_FAMILY_PATTERN     Require headroom in a VM family (regex), e.g. 'DSv5'
#   NODE_VM_SIZE           Sets CPU_FAMILY_PATTERN from VM size (e.g. Standard_D4s_v5)
#   VERBOSE=1              Print per-region quota tables in addition to summary

set -euo pipefail

REGION_FILTER="${REGION_FILTER:-[?metadata.regionType=='Physical']}"
MIN_CPU_VCPUS="${MIN_CPU_VCPUS:-12}"
MIN_GPU_VCPUS="${MIN_GPU_VCPUS:-1}"
VERBOSE="${VERBOSE:-0}"
CPU_FAMILY_PATTERN="${CPU_FAMILY_PATTERN:-}"

if [[ -n "${NODE_VM_SIZE:-}" ]]; then
  case "${NODE_VM_SIZE}" in
    Standard_D4s_v5|Standard_D4s_v6|Standard_D2s_v5|Standard_D8s_v5) CPU_FAMILY_PATTERN='DSv5|Dsv5|Dv5' ;;
    Standard_E4s_v5|Standard_E8s_v5) CPU_FAMILY_PATTERN='ESv5|Esv5|Ev5' ;;
  esac
fi

GPU_FAMILY_RE='Standard NC|Standard ND|Standard NV|Standard NG|NDISR'
SUBSCRIPTION="${AZURE_SUBSCRIPTION:-$(az account show --query id -o tsv)}"

if ! command -v az &>/dev/null || ! command -v jq &>/dev/null; then
  echo "Requires: az (Azure CLI) and jq" >&2
  exit 1
fi

TMP="$(mktemp)"
RESULTS="$(mktemp)"
trap 'rm -f "$TMP" "$RESULTS"' EXIT

if [[ -n "${REGIONS:-}" ]]; then
  # Explicit region list wins over discovery. Accept commas or whitespace.
  printf '%s\n' ${REGIONS//,/ } | sort -u >"$TMP"
else
  az account list-locations \
    --query "${REGION_FILTER}.name" -o tsv 2>/dev/null | sort -u >"$TMP"
fi

analyze_region() {
  local loc="$1"
  local json="$2"
  echo "$json" | jq -c \
    --arg loc "$loc" \
    --argjson min_cpu "$MIN_CPU_VCPUS" \
    --argjson min_gpu "$MIN_GPU_VCPUS" \
    --arg gpu_re "$GPU_FAMILY_RE" \
    --arg cpu_fam_re "${CPU_FAMILY_PATTERN}" '
    (.[] | select(.name.value == "cores")) as $cores |
    {
      region: $loc,
      cpu: (
        if $cores == null then
          {ok: false, usage: "n/a", avail: 0, label: "Total Regional vCPUs"}
        else
          (($cores.limit | tonumber) - ($cores.currentValue | tonumber)) as $avail |
          {
            ok: ($avail >= $min_cpu and ($cores.limit | tonumber) > 0),
            usage: "\($cores.currentValue)/\($cores.limit)",
            avail: $avail,
            label: ($cores.name.localizedValue // "Total Regional vCPUs")
          }
        end
      ),
      cpu_family: (
        if ($cpu_fam_re | length) == 0 then null
        else
          [.[] |
            select(.name.localizedValue | test($cpu_fam_re; "i")) |
            select((.limit | tonumber) > 0) |
            {
              name: .name.localizedValue,
              usage: "\(.currentValue)/\(.limit)",
              avail: ((.limit | tonumber) - (.currentValue | tonumber))
            }
          ] as $fams |
          if ($fams | length) == 0 then
            {ok: false, name: "(no matching family)", usage: "n/a", avail: 0}
          else
            ($fams | max_by(.avail)) as $best |
            {ok: ($best.avail >= $min_cpu), name: $best.name, usage: $best.usage, avail: $best.avail}
          end
        end
      ),
      gpu: [
        .[] |
        select((.limit | tonumber) > 0) |
        select(.name.localizedValue | test($gpu_re; "i")) |
        ((.limit | tonumber) - (.currentValue | tonumber)) as $avail |
        select($avail >= $min_gpu) |
        {
          name: .name.localizedValue,
          usage: "\(.currentValue)/\(.limit)",
          avail: $avail
        }
      ],
      gpu_quota_no_headroom: (
        [.[] |
          select((.limit | tonumber) > 0) |
          select(.name.localizedValue | test($gpu_re; "i")) |
          select((.currentValue | tonumber) >= (.limit | tonumber)) |
          .name.localizedValue
        ] | length > 0
      )
    } |
    if .cpu_family != null and .cpu_family.ok == false then
      .cpu.ok = false
    else . end
  '
}

total=0
scanned=0

while read -r loc; do
  [[ -z "$loc" ]] && continue
  total=$((total + 1))

  json="$(az vm list-usage -l "$loc" --subscription "$SUBSCRIPTION" -o json 2>/dev/null)" || continue
  echo "$json" | jq -e . >/dev/null 2>&1 || continue
  scanned=$((scanned + 1))

  analyze_region "$loc" "$json" >>"$RESULTS"

  if [[ "$VERBOSE" == "1" ]]; then
    echo "=== ${loc} ==="
    echo "$json" | jq -r --arg re "$GPU_FAMILY_RE" '
      .[] | select(.name.value == "cores" or .name.value == "virtualMachines") |
      "  CPU\t\(.name.localizedValue)\t\(.currentValue)/\(.limit)"
    '
    echo "$json" | jq -r --arg re "$GPU_FAMILY_RE" '
      .[] | select((.limit | tonumber) > 0) |
      select(.name.localizedValue | test($re; "i")) |
      "  GPU\t\(.name.localizedValue)\t\(.currentValue)/\(.limit)"
    '
    echo ""
  fi
done <"$TMP"

sub_name="$(az account show --subscription "$SUBSCRIPTION" --query name -o tsv 2>/dev/null || echo "$SUBSCRIPTION")"

echo "=============================================================================="
echo "REGION AVAILABILITY SUMMARY"
echo "=============================================================================="
echo "Subscription:     $sub_name"
echo "Subscription ID:  $SUBSCRIPTION"
echo "Regions scanned:  $scanned / $total (physical)"
echo "CPU requirement:  >= ${MIN_CPU_VCPUS} free regional vCPUs (cores quota)"
if [[ -n "$CPU_FAMILY_PATTERN" ]]; then
  echo "                  + VM family matching /${CPU_FAMILY_PATTERN}/ with same headroom"
fi
echo "GPU requirement:  >= ${MIN_GPU_VCPUS} free vCPUs in NC/ND/NV/NG/NDISR families"
echo ""
echo "Note: Quota headroom != guaranteed capacity. A region can still be out of stock."
echo "=============================================================================="
echo ""

print_cpu_table() {
  echo "CPU — regions OK to deploy CPU nodes"
  echo "------------------------------------------------------------------------------"
  local rows
  rows="$(jq -r 'select(.cpu.ok) | [.region, .cpu.usage, (.cpu.avail|tostring), (if .cpu_family then .cpu_family.name else "" end)] | @tsv' "$RESULTS" | sort -u)"
  if [[ -z "$rows" ]]; then
    echo "  (none — request quota increase or lower MIN_CPU_VCPUS)"
  else
    printf "  %-18s %-12s %-8s %s\n" "REGION" "USAGE" "FREE" "VM_FAMILY"
    while IFS=$'\t' read -r region usage avail fam; do
      printf "  %-18s %-12s %-8s %s\n" "$region" "$usage" "$avail" "${fam:-}"
    done <<<"$rows"
  fi
  echo ""
}

print_gpu_table() {
  echo "GPU — regions OK to deploy GPU nodes"
  echo "------------------------------------------------------------------------------"
  local rows
  rows="$(jq -r '. as $r | $r.gpu[]? | [$r.region, .name, .usage, (.avail|tostring)] | @tsv' "$RESULTS" | sort -u)"
  if [[ -z "$rows" ]]; then
    echo "  (none — request GPU quota or lower MIN_GPU_VCPUS)"
  else
    printf "  %-18s %-42s %-12s %s\n" "REGION" "GPU_FAMILY" "USAGE" "FREE"
    while IFS=$'\t' read -r region fam usage avail; do
      printf "  %-18s %-42s %-12s %s\n" "$region" "$fam" "$usage" "$avail"
    done <<<"$rows"
  fi
  echo ""
}

print_cpu_table
print_gpu_table

echo "BOTH CPU + GPU — use these --location values for mixed clusters"
echo "------------------------------------------------------------------------------"
if ! jq -e 'select(.cpu.ok) | select((.gpu | length) > 0)' "$RESULTS" >/dev/null 2>&1; then
  echo "  (none)"
else
  jq -r '
    select(.cpu.ok) |
    select((.gpu | length) > 0) |
    "\(.region)|CPU \(.cpu.usage) (\(.cpu.avail) free) | GPU \(.gpu[0].name) \(.gpu[0].usage) (\(.gpu[0].avail) free)"
  ' "$RESULTS" | sort -u | while IFS='|' read -r region detail; do
    printf "  %-18s %s\n" "$region" "$detail"
  done
fi
echo ""

echo "CPU ONLY (no GPU headroom in subscription)"
echo "------------------------------------------------------------------------------"
jq -r '
  select(.cpu.ok) |
  select((.gpu | length) == 0) |
  .region
' "$RESULTS" | sort -u | sed 's/^/  /' || echo "  (none)"
echo ""

echo "GPU ONLY (CPU quota does not meet requirement)"
echo "------------------------------------------------------------------------------"
jq -r '
  select(.cpu.ok | not) |
  select((.gpu | length) > 0) |
  .region
' "$RESULTS" | sort -u | sed 's/^/  /' || echo "  (none)"
echo ""

echo "NOT DEPLOYABLE — insufficient CPU and no GPU headroom"
echo "------------------------------------------------------------------------------"
jq -r '
  select(.cpu.ok | not) |
  select((.gpu | length) == 0) |
  .region
' "$RESULTS" | sort -u | head -20 | sed 's/^/  /'
not_count="$(jq -r 'select(.cpu.ok | not) | select((.gpu | length) == 0) | .region' "$RESULTS" | wc -l | tr -d ' ')"
if [[ "$not_count" -gt 20 ]]; then
  echo "  ... and $((not_count - 20)) more regions"
fi
echo ""

echo "=============================================================================="
echo "NEXT STEPS"
echo "=============================================================================="
best="$(jq -r 'select(.cpu.ok) | select((.gpu | length) > 0) | .region' "$RESULTS" | sort -u | head -1)"
if [[ -z "$best" ]]; then
  best="$(jq -r 'select(.cpu.ok) | .region' "$RESULTS" | sort -u | head -1)"
fi
if [[ -n "$best" ]]; then
  echo "  az group create --name my-new-rg --location ${best}"
  echo "  az aks create --resource-group my-new-rg --name <cluster> --location ${best} \\"
  echo "    --node-count 3 --node-vm-size Standard_D4s_v5 --network-plugin azure \\"
  echo "    --enable-oidc-issuer --enable-workload-identity --generate-ssh-keys"
else
  echo "  No region meets requirements. Increase quota in Azure Portal > Subscriptions > Usage + quotas."
fi
echo ""
echo "  Check one region:     az vm list-usage -l eastus -o table"
echo "  Match your VM SKU:    NODE_VM_SIZE=Standard_D4s_v5 ./scan-regional-quotas.sh"
echo "  Full per-region dump: VERBOSE=1 ./scan-regional-quotas.sh"
echo "=============================================================================="
