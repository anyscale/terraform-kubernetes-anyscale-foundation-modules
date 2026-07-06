#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)"
DEFAULT_EXAMPLE_DIR="${SCRIPT_DIR}"
EXAMPLE_DIR="${EXAMPLE_DIR:-${DEFAULT_EXAMPLE_DIR}}"

AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"
CLOUD_NAME="${CLOUD_NAME:-}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
ANYSCALE_CLOUD_NAME="${ANYSCALE_CLOUD_NAME:-}"
EFA_CAPACITY_RESERVATION_ID="${EFA_CAPACITY_RESERVATION_ID:-}"
EFA_EXPECTED_INSTANCE_TYPE="${EFA_EXPECTED_INSTANCE_TYPE:-p5.48xlarge}"
EFA_WORKER_COUNT="${EFA_WORKER_COUNT:-2}"
EFA_WORKLOAD_NAME="${EFA_WORKLOAD_NAME:-efa}"
EFA_PRIVATE_SUBNET_CIDR="${EFA_PRIVATE_SUBNET_CIDR:-}"
NODE_GROUP_DISK_SIZE="${NODE_GROUP_DISK_SIZE:-1000}"
ENABLE_EFS="${ENABLE_EFS:-false}"
TAGS_ENVIRONMENT="${TAGS_ENVIRONMENT:-dev}"
TAGS_TTL_HOURS="${TAGS_TTL_HOURS:-200}"
TAGS_ANYSCALE_USER="${TAGS_ANYSCALE_USER:-anyscale-efa}"
TAGS_ANYSCALE_CUSTODIAN="${TAGS_ANYSCALE_CUSTODIAN:-ignore}"
ECR_REGISTRY="${ECR_REGISTRY:-}"
ECR_MIRROR_PREFIX="${ECR_MIRROR_PREFIX:-}"
ANYSCALE_CLOUD_RESOURCE_ID="${ANYSCALE_CLOUD_RESOURCE_ID:-}"
TF_WORKSPACE_NAME="${TF_WORKSPACE_NAME:-}"
RUN_DIR="${RUN_DIR:-}"
# Runtime image (EFA + UCCL). Not yet public: build from
# https://github.com/jinghanyao1-hub/AWS_EFA_DOCKER, push to a registry the cloud can pull
# (e.g. the account ECR), then `anyscale image register` and pass the registered URI here.
RUNTIME_IMAGE_URI="${RUNTIME_IMAGE_URI:-anyscale/image/anyscale-ray-2.55.1-cu128-torch2.8-efa-uccl:1}"
RUNTIME_RAY_VERSION="${RUNTIME_RAY_VERSION:-2.55.1}"
RUNTIME_VALIDATION_ACTIONS="${RUNTIME_VALIDATION_ACTIONS:-quick,nccl,uccl-ll,uccl-ht}"
RUNTIME_WORKSPACE_NAME="${RUNTIME_WORKSPACE_NAME:-}"
RUNTIME_COMPUTE_CONFIG_NAME="${RUNTIME_COMPUTE_CONFIG_NAME:-}"
RUNTIME_WAIT_TIMEOUT_SECONDS="${RUNTIME_WAIT_TIMEOUT_SECONDS:-2400}"
RUNTIME_KUBECTL_WAIT_TIMEOUT="${RUNTIME_KUBECTL_WAIT_TIMEOUT:-1200s}"
EFA_NODEGROUP_MAX_SIZE="${EFA_NODEGROUP_MAX_SIZE:-4}"
EFA_WARMUP_TIMEOUT_SECONDS="${EFA_WARMUP_TIMEOUT_SECONDS:-1800}"
RUNTIME_WARMUP="${RUNTIME_WARMUP:-true}"
RUNTIME_PREPULL_IMAGE="${RUNTIME_PREPULL_IMAGE:-true}"
RUNTIME_PREPULL_TIMEOUT_SECONDS="${RUNTIME_PREPULL_TIMEOUT_SECONDS:-1800}"
ANYSCALE_CLOUD_ID="${ANYSCALE_CLOUD_ID:-}"
ANYSCALE_CLOUD_REGISTRY="${ANYSCALE_CLOUD_REGISTRY:-}"

APPLY=0
SKIP_REGISTER=0
SKIP_HELM=0
SKIP_VERIFY=0
RUN_RUNTIME_VALIDATION=0
KEEP_RUNTIME_WORKSPACE=1
RUNTIME_WORKSPACE_ID=""
RUNTIME_COMPUTE_CONFIG_REF=""
VALIDATION_CLEANUP_DONE=0
WARMUP_NODEGROUP_ACTIVE=0

usage() {
  cat <<EOF
Usage:
  CLOUD_NAME=<name> EFA_CAPACITY_RESERVATION_ID=cr-... $0 [--apply]

Required input:
  CLOUD_NAME or both EKS_CLUSTER_NAME and ANYSCALE_CLOUD_NAME
  AWS_PROFILE
  EFA_CAPACITY_RESERVATION_ID
  EFA_PRIVATE_SUBNET_CIDR
  ECR_REGISTRY and ECR_MIRROR_PREFIX, unless --skip-helm is used

Common options:
  --apply                         Create/update AWS resources, register the Anyscale cloud, and install Helm add-ons.
  --name NAME                     Set both EKS_CLUSTER_NAME and ANYSCALE_CLOUD_NAME.
  --eks-cluster-name NAME         AWS EKS cluster name. Defaults to CLOUD_NAME.
  --anyscale-cloud-name NAME      Anyscale cloud name. Defaults to CLOUD_NAME.
  --capacity-reservation-id ID    EC2 Capacity Reservation ID, cr-...
  --worker-count N                Required available p5 capacity for validation. Default: ${EFA_WORKER_COUNT}
  --efa-workload-name NAME        Workload label/name for the P5/H100 EFA node group. Default: ${EFA_WORKLOAD_NAME}
  EFA_PRIVATE_SUBNET_CIDR         Private subnet CIDR for the EFA node group.
  --ttl-hours HOURS               AWS Cloud Custodian ttl-hours tag for EC2 instances. Default: ${TAGS_TTL_HOURS}
  --custodian-user VALUE          anyscale-user tag value for Custodian bypass. Default: ${TAGS_ANYSCALE_USER}
  --terraform-workspace NAME      Terraform workspace. Default: efa-<EKS_CLUSTER_NAME>.
  --validate-runtime              Launch an Anyscale workspace, run EFA/NCCL/UCCL validation, and leave it running.
  --validation-actions LIST       Comma-separated actions. Default: ${RUNTIME_VALIDATION_ACTIONS}
  --docker-image URI              Validation workspace Docker image. Default: ${RUNTIME_IMAGE_URI}
  --runtime-image-uri URI         Alias for --docker-image.
  --workspace-image-uri URI       Alias for --docker-image.
  --image-uri URI                 Alias for --docker-image.
  --workspace-name NAME           Validation workspace name. Default: timestamped name.
  --compute-config-name NAME      Validation compute config name. Default: workspace name.
  --keep-workspace                Deprecated no-op; validation workspaces are always left running.
  --skip-runtime-warmup           Do not pre-scale and wait for the EFA node group before validation.
  --skip-image-prepull            Warm EFA nodes, but do not pre-pull the validation image.
  --skip-register                 Do not run anyscale cloud register. Requires ANYSCALE_CLOUD_RESOURCE_ID for Helm.
  --skip-helm                     Do not install Kubernetes Helm add-ons.
  --skip-verify                   Do not run anyscale cloud verify/status.
  -h, --help                      Show this help.

Plan-only mode is the default and does not create resources.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=1
      shift
      ;;
    --name)
      CLOUD_NAME="${2:?Missing value for --name}"
      shift 2
      ;;
    --eks-cluster-name)
      EKS_CLUSTER_NAME="${2:?Missing value for --eks-cluster-name}"
      shift 2
      ;;
    --anyscale-cloud-name)
      ANYSCALE_CLOUD_NAME="${2:?Missing value for --anyscale-cloud-name}"
      shift 2
      ;;
    --capacity-reservation-id)
      EFA_CAPACITY_RESERVATION_ID="${2:?Missing value for --capacity-reservation-id}"
      shift 2
      ;;
    --worker-count)
      EFA_WORKER_COUNT="${2:?Missing value for --worker-count}"
      shift 2
      ;;
    --efa-workload-name)
      EFA_WORKLOAD_NAME="${2:?Missing value for --efa-workload-name}"
      shift 2
      ;;
    --ttl-hours)
      TAGS_TTL_HOURS="${2:?Missing value for --ttl-hours}"
      shift 2
      ;;
    --custodian-user)
      TAGS_ANYSCALE_USER="${2:?Missing value for --custodian-user}"
      shift 2
      ;;
    --terraform-workspace)
      TF_WORKSPACE_NAME="${2:?Missing value for --terraform-workspace}"
      shift 2
      ;;
    --validate-runtime)
      RUN_RUNTIME_VALIDATION=1
      shift
      ;;
    --validation-actions)
      RUNTIME_VALIDATION_ACTIONS="${2:?Missing value for --validation-actions}"
      shift 2
      ;;
    --docker-image|--runtime-image-uri|--workspace-image-uri|--image-uri)
      RUNTIME_IMAGE_URI="${2:?Missing value for $1}"
      shift 2
      ;;
    --workspace-name)
      RUNTIME_WORKSPACE_NAME="${2:?Missing value for --workspace-name}"
      shift 2
      ;;
    --compute-config-name)
      RUNTIME_COMPUTE_CONFIG_NAME="${2:?Missing value for --compute-config-name}"
      shift 2
      ;;
    --keep-workspace)
      KEEP_RUNTIME_WORKSPACE=1
      shift
      ;;
    --skip-runtime-warmup)
      RUNTIME_WARMUP=false
      shift
      ;;
    --skip-image-prepull)
      RUNTIME_PREPULL_IMAGE=false
      shift
      ;;
    --skip-register)
      SKIP_REGISTER=1
      shift
      ;;
    --skip-helm)
      SKIP_HELM=1
      shift
      ;;
    --skip-verify)
      SKIP_VERIFY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION
export PATH="$HOME/.local/bin:$PATH"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

bool_is_true() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on)
      return 0
      ;;
    0|false|no|n|off)
      return 1
      ;;
    *)
      echo "Expected boolean value for $2, got: $1" >&2
      exit 1
      ;;
  esac
}

require_dnsish_name() {
  local label="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
    echo "${label} must be lowercase DNS-style text: letters, numbers, hyphens, no leading/trailing hyphen." >&2
    echo "Got: ${value}" >&2
    exit 1
  fi
}

sanitize_workspace_name() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//'
}

assert_terraform_workspace() {
  local current_workspace

  current_workspace="$(terraform workspace show)"
  if [[ "$current_workspace" != "$TF_WORKSPACE_NAME" ]]; then
    echo "Terraform workspace mismatch." >&2
    echo "Expected: ${TF_WORKSPACE_NAME}" >&2
    echo "Current:  ${current_workspace}" >&2
    exit 1
  fi
}

assert_terraform_outputs_match_run() {
  local output_cluster_name

  assert_terraform_workspace
  output_cluster_name="$(terraform output -raw eks_cluster_name 2>/dev/null || true)"
  if [[ -n "$output_cluster_name" && "$output_cluster_name" != "$EKS_CLUSTER_NAME" ]]; then
    echo "Terraform output mismatch: eks_cluster_name does not match this run." >&2
    echo "Expected: ${EKS_CLUSTER_NAME}" >&2
    echo "Output:   ${output_cluster_name}" >&2
    echo "Refusing to register or install Anyscale against stale Terraform state." >&2
    exit 1
  fi
}

registration_arg() {
  local command_text="$1"
  local arg_name="$2"

  printf '%s\n' "$command_text" |
    sed -n "s/^[[:space:]]*${arg_name}[[:space:]]*//p" |
    head -1 |
    sed -E 's/[[:space:]]*\\[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

kubectl_context_number() {
  local target_context="$1"
  local context
  local index=0

  while IFS= read -r context; do
    index=$((index + 1))
    if [[ "$context" == "$target_context" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done < <(kubectl config get-contexts -o name)

  return 1
}

runtime_image_has_registry() {
  local first_component="${1%%/*}"

  [[ "$1" == */* ]] && [[ "$first_component" == *.* || "$first_component" == *:* || "$first_component" == "localhost" ]]
}

cloud_id_to_dns() {
  printf '%s' "$1" | tr '_' '-'
}

find_existing_anyscale_cloud_resource() {
  local expected_s3_bucket="$1"
  local expected_operator_identity="$2"
  local cloud_get_file="${RUN_DIR}/anyscale-cloud-get-existing.yaml"
  local cloud_get_log="${RUN_DIR}/anyscale-cloud-get-existing.log"

  if ! anyscale cloud get --name "$ANYSCALE_CLOUD_NAME" -o "$cloud_get_file" >"$cloud_get_log" 2>&1; then
    return 1
  fi

  awk \
    -v expected_bucket="s3://${expected_s3_bucket}" \
    -v expected_identity="$expected_operator_identity" '
      function trim(value) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        return value
      }
      function maybe_print_match() {
        if (resource_id != "" && bucket_name == expected_bucket && operator_identity == expected_identity) {
          print resource_id
          found = 1
          exit
        }
      }
      /^[[:space:]]*-[[:space:]]*cloud_resource_id:[[:space:]]*/ {
        maybe_print_match()
        value = $0
        sub(/^[[:space:]]*-[[:space:]]*cloud_resource_id:[[:space:]]*/, "", value)
        resource_id = trim(value)
        bucket_name = ""
        operator_identity = ""
        next
      }
      /^[[:space:]]*bucket_name:[[:space:]]*/ {
        value = $0
        sub(/^[[:space:]]*bucket_name:[[:space:]]*/, "", value)
        bucket_name = trim(value)
        next
      }
      /^[[:space:]]*anyscale_operator_iam_identity:[[:space:]]*/ {
        value = $0
        sub(/^[[:space:]]*anyscale_operator_iam_identity:[[:space:]]*/, "", value)
        operator_identity = trim(value)
        next
      }
      END {
        if (!found) {
          maybe_print_match()
        }
      }
    ' "$cloud_get_file"
}

verify_anyscale_cloud_resource() {
  local expected_s3_bucket="$1"
  local expected_operator_identity="$2"
  local cloud_get_file="${RUN_DIR}/anyscale-cloud-get-after-register.yaml"
  local cloud_get_log="${RUN_DIR}/anyscale-cloud-get-after-register.log"

  if [[ -z "$ANYSCALE_CLOUD_RESOURCE_ID" ]]; then
    return 0
  fi

  echo "Verifying Anyscale cloud resource matches Terraform outputs..."
  if ! anyscale cloud get --name "$ANYSCALE_CLOUD_NAME" -o "$cloud_get_file" >"$cloud_get_log" 2>&1; then
    cat "$cloud_get_log" >&2
    echo "Could not read Anyscale cloud metadata for ${ANYSCALE_CLOUD_NAME}." >&2
    exit 1
  fi

  if ! grep -q "cloud_resource_id: ${ANYSCALE_CLOUD_RESOURCE_ID}$" "$cloud_get_file"; then
    cat "$cloud_get_file" >&2
    echo "Anyscale cloud ${ANYSCALE_CLOUD_NAME} does not include resource ${ANYSCALE_CLOUD_RESOURCE_ID}." >&2
    exit 1
  fi

  if [[ -n "$expected_s3_bucket" ]] && ! grep -q "bucket_name: s3://${expected_s3_bucket}$" "$cloud_get_file"; then
    cat "$cloud_get_file" >&2
    echo "Anyscale cloud resource is using a different S3 bucket than Terraform output." >&2
    echo "Expected bucket: s3://${expected_s3_bucket}" >&2
    exit 1
  fi

  if [[ -n "$expected_operator_identity" ]] && ! grep -q "anyscale_operator_iam_identity: ${expected_operator_identity}$" "$cloud_get_file"; then
    cat "$cloud_get_file" >&2
    echo "Anyscale cloud resource is using a different operator IAM identity than Terraform output." >&2
    echo "Expected identity: ${expected_operator_identity}" >&2
    exit 1
  fi
}

if [[ -n "$CLOUD_NAME" ]]; then
  EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-$CLOUD_NAME}"
  ANYSCALE_CLOUD_NAME="${ANYSCALE_CLOUD_NAME:-$CLOUD_NAME}"
fi

if [[ -z "$EKS_CLUSTER_NAME" && -n "$ANYSCALE_CLOUD_NAME" ]]; then
  EKS_CLUSTER_NAME="$ANYSCALE_CLOUD_NAME"
fi

if [[ -z "$ANYSCALE_CLOUD_NAME" && -n "$EKS_CLUSTER_NAME" ]]; then
  ANYSCALE_CLOUD_NAME="$EKS_CLUSTER_NAME"
fi

if [[ -z "$EKS_CLUSTER_NAME" || -z "$ANYSCALE_CLOUD_NAME" ]]; then
  echo "Set CLOUD_NAME, or set both EKS_CLUSTER_NAME and ANYSCALE_CLOUD_NAME." >&2
  usage >&2
  exit 1
fi

if [[ -z "$EFA_CAPACITY_RESERVATION_ID" ]]; then
  echo "Set EFA_CAPACITY_RESERVATION_ID=cr-... before running this script." >&2
  exit 1
fi

if [[ -z "$EFA_PRIVATE_SUBNET_CIDR" ]]; then
  echo "Set EFA_PRIVATE_SUBNET_CIDR to the private subnet CIDR for the EFA node group." >&2
  exit 1
fi

if [[ -z "$AWS_PROFILE" ]]; then
  echo "Set AWS_PROFILE to the named AWS CLI profile to use for this deployment." >&2
  exit 1
fi

if [[ ! -d "$EXAMPLE_DIR" ]]; then
  echo "EXAMPLE_DIR does not exist: ${EXAMPLE_DIR}" >&2
  echo "Set EXAMPLE_DIR to the terraform-kubernetes-anyscale-foundation-modules/examples/aws/eks-public-efa path." >&2
  exit 1
fi

if [[ ! "$EFA_WORKER_COUNT" =~ ^[0-9]+$ ]]; then
  echo "EFA_WORKER_COUNT must be a non-negative integer. Got: ${EFA_WORKER_COUNT}" >&2
  exit 1
fi

if [[ ! "$TAGS_TTL_HOURS" =~ ^[0-9]+$ ]]; then
  echo "TAGS_TTL_HOURS must be a non-negative integer. Got: ${TAGS_TTL_HOURS}" >&2
  exit 1
fi
if [[ -z "$TAGS_ANYSCALE_USER" ]]; then
  echo "TAGS_ANYSCALE_USER must be non-empty." >&2
  exit 1
fi
if [[ "$TAGS_ANYSCALE_CUSTODIAN" != "ignore" ]]; then
  echo "TAGS_ANYSCALE_CUSTODIAN must be 'ignore' for this automation's protected-node tagging flow. Got: ${TAGS_ANYSCALE_CUSTODIAN}" >&2
  exit 1
fi

if (( SKIP_HELM == 0 )); then
  if [[ -z "$ECR_REGISTRY" || -z "$ECR_MIRROR_PREFIX" ]]; then
    echo "Set ECR_REGISTRY and ECR_MIRROR_PREFIX before installing Helm add-ons, or use --skip-helm." >&2
    exit 1
  fi
fi

bool_is_true "$RUNTIME_WARMUP" RUNTIME_WARMUP || true
bool_is_true "$RUNTIME_PREPULL_IMAGE" RUNTIME_PREPULL_IMAGE || true

require_dnsish_name "EKS_CLUSTER_NAME" "$EKS_CLUSTER_NAME"
require_dnsish_name "ANYSCALE_CLOUD_NAME" "$ANYSCALE_CLOUD_NAME"
require_dnsish_name "EFA_WORKLOAD_NAME" "$EFA_WORKLOAD_NAME"

if (( ${#EKS_CLUSTER_NAME} + ${#AWS_REGION} + 1 > 63 )); then
  echo "The generated S3 bucket name '${EKS_CLUSTER_NAME}-${AWS_REGION}' would exceed 63 characters." >&2
  exit 1
fi

if [[ -z "$TF_WORKSPACE_NAME" ]]; then
  TF_WORKSPACE_NAME="efa-$(sanitize_workspace_name "$EKS_CLUSTER_NAME")"
fi

if (( RUN_RUNTIME_VALIDATION == 1 && APPLY == 0 )); then
  echo "--validate-runtime requires --apply because it launches an Anyscale workspace." >&2
  exit 1
fi

if (( RUN_RUNTIME_VALIDATION == 1 && EFA_WORKER_COUNT == 0 )); then
  echo "--validate-runtime requires --worker-count greater than zero." >&2
  exit 1
fi

if (( RUN_RUNTIME_VALIDATION == 1 )); then
  validation_suffix="$(date +%Y%m%d-%H%M%S)"
  if [[ -z "$RUNTIME_WORKSPACE_NAME" ]]; then
    RUNTIME_WORKSPACE_NAME="${ANYSCALE_CLOUD_NAME}-p5-validation-${validation_suffix}"
  fi
  if [[ -z "$RUNTIME_COMPUTE_CONFIG_NAME" ]]; then
    RUNTIME_COMPUTE_CONFIG_NAME="$RUNTIME_WORKSPACE_NAME"
  fi
fi

if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="${WORK_DIR}/runs/${EKS_CLUSTER_NAME}"
fi

TFVARS_FILE="${RUN_DIR}/terraform.tfvars"
PLAN_FILE="${RUN_DIR}/tfplan"
OUTPUT_ENV_FILE="${RUN_DIR}/outputs.env"
RUNTIME_COMPUTE_CONFIG_FILE="${RUN_DIR}/p5-validation-compute.yaml"
RUNTIME_WORKSPACE_FILE="${RUN_DIR}/p5-validation-workspace.yaml"

need aws
need terraform

if (( APPLY == 1 )); then
  if (( SKIP_REGISTER == 0 || SKIP_VERIFY == 0 || RUN_RUNTIME_VALIDATION == 1 )); then
    need anyscale
  fi
  if (( SKIP_HELM == 0 || RUN_RUNTIME_VALIDATION == 1 )); then
    need kubectl
  fi
  if (( SKIP_HELM == 0 )); then
    need helm
  fi
fi

runtime_nodegroup_name() {
  printf '%s-%s-nodegroup' "$EKS_CLUSTER_NAME" "$EFA_WORKLOAD_NAME"
}

runtime_node_selector() {
  printf 'workload=%s,node.kubernetes.io/instance-type=%s' "$EFA_WORKLOAD_NAME" "$EFA_EXPECTED_INSTANCE_TYPE"
}

count_target_efa_instances() {
  aws ec2 describe-instances \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --filters \
      "Name=tag:eks:nodegroup-name,Values=$(runtime_nodegroup_name)" \
      "Name=instance-type,Values=${EFA_EXPECTED_INSTANCE_TYPE}" \
      "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text |
    wc -w |
    tr -d ' '
}

tag_cluster_instances_for_gc() {
  local log_file="${1:-${RUN_DIR}/cluster-instance-custodian-tags.log}"
  local instance_ids_text
  local instance_ids=()

  instance_ids_text="$(
    aws ec2 describe-instances \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --filters \
        "Name=tag:Project,Values=${EKS_CLUSTER_NAME}" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId' \
      --output text
  )"

  if [[ -z "$instance_ids_text" || "$instance_ids_text" == "None" ]]; then
    echo "No current EC2 instances found for Project=${EKS_CLUSTER_NAME}; Custodian tags not applied." | tee "$log_file"
    return 0
  fi

  read -r -a instance_ids <<<"$instance_ids_text"
  {
    echo "Tagging ${#instance_ids[@]} EC2 instance(s) for Cloud Custodian bypass."
    printf '  %s\n' "${instance_ids[@]}"
    aws ec2 create-tags \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --resources "${instance_ids[@]}" \
      --tags \
        "Key=ttl-hours,Value=${TAGS_TTL_HOURS}" \
        "Key=anyscale-user,Value=${TAGS_ANYSCALE_USER}" \
        "Key=anyscale-custodian,Value=${TAGS_ANYSCALE_CUSTODIAN}"
  } 2>&1 | tee "$log_file"
}

tag_cluster_autoscaling_groups_for_gc() {
  local log_file="${1:-${RUN_DIR}/cluster-asg-custodian-tags.log}"
  local asg_names_text
  local asg_names=()
  local asg

  asg_names_text="$(
    aws autoscaling describe-auto-scaling-groups \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --filters "Name=tag:eks:cluster-name,Values=${EKS_CLUSTER_NAME}" \
      --query 'AutoScalingGroups[].AutoScalingGroupName' \
      --output text
  )"

  if [[ -z "$asg_names_text" || "$asg_names_text" == "None" ]]; then
    asg_names_text="$(
      aws autoscaling describe-auto-scaling-groups \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --filters "Name=tag:kubernetes.io/cluster/${EKS_CLUSTER_NAME},Values=owned" \
        --query 'AutoScalingGroups[].AutoScalingGroupName' \
        --output text
    )"
  fi

  if [[ -z "$asg_names_text" || "$asg_names_text" == "None" ]]; then
    echo "No Auto Scaling Groups found for EKS cluster ${EKS_CLUSTER_NAME}; propagated Custodian tags not applied." | tee "$log_file"
    return 0
  fi

  read -r -a asg_names <<<"$asg_names_text"
  {
    echo "Tagging ${#asg_names[@]} Auto Scaling Group(s) for Cloud Custodian bypass with PropagateAtLaunch=true."
    printf '  %s\n' "${asg_names[@]}"
    for asg in "${asg_names[@]}"; do
      aws autoscaling create-or-update-tags \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --tags \
          "ResourceId=${asg},ResourceType=auto-scaling-group,Key=ttl-hours,Value=${TAGS_TTL_HOURS},PropagateAtLaunch=true" \
          "ResourceId=${asg},ResourceType=auto-scaling-group,Key=anyscale-user,Value=${TAGS_ANYSCALE_USER},PropagateAtLaunch=true" \
          "ResourceId=${asg},ResourceType=auto-scaling-group,Key=anyscale-custodian,Value=${TAGS_ANYSCALE_CUSTODIAN},PropagateAtLaunch=true"
    done
  } 2>&1 | tee "$log_file"
}

scale_runtime_nodegroup_to() {
  local desired_size="$1"
  local required="${2:-true}"
  local nodegroup_name scale_output wait_output
  nodegroup_name="$(runtime_nodegroup_name)"

  echo "Scaling EFA node group ${nodegroup_name} to desired size ${desired_size}..."
  if ! scale_output="$(
    aws eks update-nodegroup-config \
      --cluster-name "$EKS_CLUSTER_NAME" \
      --nodegroup-name "$nodegroup_name" \
      --scaling-config "minSize=0,maxSize=${EFA_NODEGROUP_MAX_SIZE},desiredSize=${desired_size}" \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" 2>&1
  )"; then
    if grep -qi 'no changes' <<<"$scale_output"; then
      printf '%s\n' "$scale_output"
    elif bool_is_true "$required" required; then
      printf '%s\n' "$scale_output" >&2
      return 1
    else
      printf '%s\n' "$scale_output" >&2
      echo "Warning: could not request EFA node group scale change. Check ${nodegroup_name} manually." >&2
      return 0
    fi
  else
    printf '%s\n' "$scale_output" | tee "${RUN_DIR}/runtime-nodegroup-scale-${desired_size}.log"
  fi

  if ! wait_output="$(
    aws eks wait nodegroup-active \
      --cluster-name "$EKS_CLUSTER_NAME" \
      --nodegroup-name "$nodegroup_name" \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" 2>&1
  )"; then
    if bool_is_true "$required" required; then
      printf '%s\n' "$wait_output" >&2
      return 1
    fi
    printf '%s\n' "$wait_output" >&2
    echo "Warning: EFA node group scale request was submitted, but wait did not finish cleanly." >&2
  fi
}

scale_runtime_nodegroup_zero() {
  local kubectl_context

  if command -v kubectl >/dev/null 2>&1; then
    kubectl_context="$(kubectl config current-context 2>/dev/null || true)"
    if [[ -n "$kubectl_context" ]]; then
      allow_runtime_nodes_scale_down "$kubectl_context"
    fi
  fi

  scale_runtime_nodegroup_to 0 false
  WARMUP_NODEGROUP_ACTIVE=0
}

cleanup_runtime_validation() {
  if (( VALIDATION_CLEANUP_DONE == 1 )); then
    return 0
  fi

  if [[ -n "$RUNTIME_WORKSPACE_ID" ]]; then
    return 0
  fi

  if (( WARMUP_NODEGROUP_ACTIVE == 1 )); then
    VALIDATION_CLEANUP_DONE=1
    echo "Cleaning up warmed EFA node group because no handoff workspace was created..."
    scale_runtime_nodegroup_zero
  fi
}

write_runtime_compute_config() {
  cat >"$RUNTIME_COMPUTE_CONFIG_FILE" <<EOF
cloud: ${ANYSCALE_CLOUD_NAME}
zones:
  - ${CR_AZ}
head_node:
  instance_type: 8CPU-32GB
worker_nodes:
  - name: 8xh100-190cpu-1800gb
    instance_type: P5-48XLARGE-8xH100-EFA
    min_nodes: ${EFA_WORKER_COUNT}
    max_nodes: ${EFA_WORKER_COUNT}
    market_type: ON_DEMAND
    advanced_instance_config:
      spec:
        containers:
          - name: ray
            resources:
              requests:
                cpu: 189600m
                memory: 1798Gi
                nvidia.com/gpu: "8"
                vpc.amazonaws.com/efa: "32"
              limits:
                cpu: 189600m
                memory: 1798Gi
                nvidia.com/gpu: "8"
                vpc.amazonaws.com/efa: "32"
            securityContext:
              allowPrivilegeEscalation: true
              capabilities:
                add:
                  - SYS_ADMIN
EOF
}

write_runtime_workspace_config() {
  cat >"$RUNTIME_WORKSPACE_FILE" <<EOF
name: ${RUNTIME_WORKSPACE_NAME}
cloud: ${ANYSCALE_CLOUD_NAME}
image_uri: ${RUNTIME_IMAGE_URI}
ray_version: ${RUNTIME_RAY_VERSION}
compute_config: ${RUNTIME_COMPUTE_CONFIG_REF}
idle_termination_minutes: 180
tags:
  purpose: efa-runtime-validation
  capacity_reservation: ${EFA_CAPACITY_RESERVATION_ID}
EOF
}

wait_for_pod_count() {
  local selector="$1"
  local expected_count="$2"
  local label="$3"
  local kubectl_context="$4"
  local count

  for _ in {1..120}; do
    count="$(
      kubectl --context "$kubectl_context" get pods \
        -n anyscale-operator \
        -l "$selector" \
        --no-headers 2>/dev/null |
        wc -l |
        tr -d ' '
    )"
    if (( count >= expected_count )); then
      return 0
    fi
    sleep 10
  done

  echo "Timed out waiting for ${expected_count} ${label} pod(s); found ${count:-0}." >&2
  return 1
}

runtime_ready_nodes() {
  local kubectl_context="$1"
  local selector node ready unschedulable
  selector="$(runtime_node_selector)"

  kubectl --context "$kubectl_context" get nodes \
    -l "$selector" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      ready="$(
        kubectl --context "$kubectl_context" get node "$node" \
          -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true
      )"
      unschedulable="$(
        kubectl --context "$kubectl_context" get node "$node" \
          -o jsonpath='{.spec.unschedulable}' 2>/dev/null || true
      )"
      if [[ "$ready" == "True" && "$unschedulable" != "true" ]]; then
        printf '%s\n' "$node"
      fi
    done
}

wait_for_runtime_nodes_ready() {
  local kubectl_context="$1"
  local deadline ready_count last_report=""

  echo "Waiting for ${EFA_WORKER_COUNT} Ready ${EFA_EXPECTED_INSTANCE_TYPE} EFA node(s)..."
  deadline=$((SECONDS + EFA_WARMUP_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    ready_count="$(runtime_ready_nodes "$kubectl_context" | wc -l | tr -d ' ')"
    if [[ "$ready_count" != "$last_report" ]]; then
      echo "Ready EFA nodes: ${ready_count}/${EFA_WORKER_COUNT}"
      last_report="$ready_count"
    fi
    if (( ready_count >= EFA_WORKER_COUNT )); then
      runtime_ready_nodes "$kubectl_context" | tee "${RUN_DIR}/runtime-warmup-nodes.txt"
      return 0
    fi
    sleep 10
  done

  kubectl --context "$kubectl_context" get nodes \
    -L workload,node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup >&2 || true
  echo "Timed out waiting for Ready EFA nodes." >&2
  return 1
}

protect_runtime_nodes_from_scale_down() {
  local kubectl_context="$1"
  local node

  echo "Disabling Cluster Autoscaler scale-down for warmed EFA nodes..."
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    kubectl --context "$kubectl_context" annotate node "$node" \
      cluster-autoscaler.kubernetes.io/scale-down-disabled=true \
      --overwrite
  done < <(runtime_ready_nodes "$kubectl_context")
}

protect_workspace_nodes_from_scale_down() {
  local kubectl_context="$1"
  local selector node

  shift
  echo "Disabling Cluster Autoscaler scale-down for validation workspace nodes..."
  for selector in "$@"; do
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      kubectl --context "$kubectl_context" annotate node "$node" \
        cluster-autoscaler.kubernetes.io/scale-down-disabled=true \
        --overwrite
    done < <(
      kubectl --context "$kubectl_context" get pods \
        -n anyscale-operator \
        -l "$selector" \
        -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' |
        sort -u
    )
  done
}

allow_runtime_nodes_scale_down() {
  local kubectl_context="$1"
  local node

  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    kubectl --context "$kubectl_context" annotate node "$node" \
      cluster-autoscaler.kubernetes.io/scale-down-disabled- \
      --overwrite >/dev/null 2>&1 || true
  done < <(runtime_ready_nodes "$kubectl_context")
}

node_has_runtime_resources() {
  local kubectl_context="$1"
  local node="$2"
  local gpu efa

  gpu="$(
    kubectl --context "$kubectl_context" get node "$node" \
      -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true
  )"
  efa="$(
    kubectl --context "$kubectl_context" get node "$node" \
      -o jsonpath='{.status.allocatable.vpc\.amazonaws\.com/efa}' 2>/dev/null || true
  )"

  [[ "$gpu" =~ ^[0-9]+$ && "$efa" =~ ^[0-9]+$ ]] && (( gpu >= 8 && efa >= 32 ))
}

wait_for_runtime_resources() {
  local kubectl_context="$1"
  local deadline ready_nodes resource_ready node last_report=""

  echo "Waiting for EFA/NVIDIA device plugins to advertise GPU and EFA resources..."
  kubectl --context "$kubectl_context" rollout status daemonset/efa-aws-efa-k8s-device-plugin \
    -n kube-system \
    --timeout="${EFA_WARMUP_TIMEOUT_SECONDS}s" 2>&1 |
    tee "${RUN_DIR}/runtime-warmup-efa-device-plugin.log"
  kubectl --context "$kubectl_context" rollout status daemonset/nvdp-nvidia-device-plugin \
    -n nvidia-device-plugin \
    --timeout="${EFA_WARMUP_TIMEOUT_SECONDS}s" 2>&1 |
    tee "${RUN_DIR}/runtime-warmup-nvidia-device-plugin.log"

  deadline=$((SECONDS + EFA_WARMUP_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    resource_ready=0
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      if node_has_runtime_resources "$kubectl_context" "$node"; then
        resource_ready=$((resource_ready + 1))
      fi
    done < <(runtime_ready_nodes "$kubectl_context")

    if [[ "$resource_ready" != "$last_report" ]]; then
      echo "EFA nodes with allocatable GPU/EFA: ${resource_ready}/${EFA_WORKER_COUNT}"
      last_report="$resource_ready"
    fi
    if (( resource_ready >= EFA_WORKER_COUNT )); then
      ready_nodes="$(runtime_ready_nodes "$kubectl_context" | paste -sd ',' -)"
      echo "Runtime EFA resources are ready on: ${ready_nodes}"
      return 0
    fi
    sleep 10
  done

  kubectl --context "$kubectl_context" describe nodes -l "$(runtime_node_selector)" >&2 || true
  echo "Timed out waiting for EFA nodes to advertise GPU/EFA resources." >&2
  return 1
}

resolve_anyscale_cloud_id() {
  local cloud_get_file="${RUN_DIR}/anyscale-cloud-get-for-warmup.yaml"
  local cloud_get_log="${RUN_DIR}/anyscale-cloud-get-for-warmup.log"

  if [[ -n "$ANYSCALE_CLOUD_ID" ]]; then
    printf '%s\n' "$ANYSCALE_CLOUD_ID"
    return 0
  fi

  if ! anyscale cloud get --name "$ANYSCALE_CLOUD_NAME" -o "$cloud_get_file" >"$cloud_get_log" 2>&1; then
    cat "$cloud_get_log" >&2
    return 1
  fi

  ANYSCALE_CLOUD_ID="$(
    sed -n 's/^id:[[:space:]]*//p' "$cloud_get_file" |
      head -1 |
      tr -d '[:space:]'
  )"

  if [[ -z "$ANYSCALE_CLOUD_ID" ]]; then
    cat "$cloud_get_file" >&2
    echo "Could not parse Anyscale cloud ID for ${ANYSCALE_CLOUD_NAME}." >&2
    return 1
  fi

  printf '%s\n' "$ANYSCALE_CLOUD_ID"
}

resolve_runtime_image_pull_uri() {
  local cloud_id cloud_dns registry

  if runtime_image_has_registry "$RUNTIME_IMAGE_URI"; then
    printf '%s\n' "$RUNTIME_IMAGE_URI"
    return 0
  fi

  if [[ -n "$ANYSCALE_CLOUD_REGISTRY" ]]; then
    registry="$ANYSCALE_CLOUD_REGISTRY"
  else
    cloud_id="$(resolve_anyscale_cloud_id)"
    cloud_dns="$(cloud_id_to_dns "$cloud_id")"
    registry="registry-${cloud_dns}.anyscale-cloud.dev:443"
  fi

  printf '%s/%s\n' "$registry" "$RUNTIME_IMAGE_URI"
}

prepull_runtime_image() {
  local kubectl_context="$1"
  local image_uri prepull_name prepull_file

  if ! bool_is_true "$RUNTIME_PREPULL_IMAGE" RUNTIME_PREPULL_IMAGE; then
    echo "Skipping runtime image pre-pull."
    return 0
  fi

  image_uri="$(resolve_runtime_image_pull_uri)"
  prepull_name="anyscale-runtime-image-prepull"
  prepull_file="${RUN_DIR}/runtime-image-prepull-daemonset.yaml"

  echo "Pre-pulling runtime image on EFA nodes: ${image_uri}"
  kubectl --context "$kubectl_context" delete daemonset "$prepull_name" \
    -n anyscale-operator \
    --ignore-not-found=true >/dev/null

  cat >"$prepull_file" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${prepull_name}
  namespace: anyscale-operator
  labels:
    app.kubernetes.io/name: ${prepull_name}
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: ${prepull_name}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${prepull_name}
    spec:
      serviceAccountName: anyscale-operator
      imagePullSecrets:
        - name: anyscale-registry-credentials
      nodeSelector:
        workload: ${EFA_WORKLOAD_NAME}
        node.kubernetes.io/instance-type: ${EFA_EXPECTED_INSTANCE_TYPE}
        nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
        vpc.amazonaws.com/efa.present: "true"
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
        - key: vpc.amazonaws.com/efa
          operator: Exists
          effect: NoSchedule
        - key: node.anyscale.com/capacity-type
          operator: Exists
          effect: NoSchedule
        - key: node.anyscale.com/accelerator-type
          operator: Exists
          effect: NoSchedule
        - key: workload
          operator: Equal
          value: ${EFA_WORKLOAD_NAME}
          effect: NoSchedule
      containers:
        - name: prepull
          image: ${image_uri}
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-lc", "sleep 3600"]
          resources:
            requests:
              cpu: 10m
              memory: 64Mi
EOF

  kubectl --context "$kubectl_context" apply -f "$prepull_file" 2>&1 |
    tee "${RUN_DIR}/runtime-image-prepull-apply.log"

  if ! kubectl --context "$kubectl_context" rollout status daemonset/"$prepull_name" \
    -n anyscale-operator \
    --timeout="${RUNTIME_PREPULL_TIMEOUT_SECONDS}s" 2>&1 |
    tee "${RUN_DIR}/runtime-image-prepull-rollout.log"; then
    kubectl --context "$kubectl_context" describe daemonset "$prepull_name" -n anyscale-operator >&2 || true
    kubectl --context "$kubectl_context" get pods -n anyscale-operator -l app.kubernetes.io/name="$prepull_name" -o wide >&2 || true
    kubectl --context "$kubectl_context" get events -n anyscale-operator --sort-by=.lastTimestamp | tail -80 >&2 || true
    echo "Runtime image pre-pull failed. Rerun with --skip-image-prepull to skip this optimization." >&2
    return 1
  fi

  kubectl --context "$kubectl_context" delete daemonset "$prepull_name" \
    -n anyscale-operator \
    --ignore-not-found=true 2>&1 |
    tee "${RUN_DIR}/runtime-image-prepull-delete.log"
  kubectl --context "$kubectl_context" wait pod \
    -n anyscale-operator \
    -l app.kubernetes.io/name="$prepull_name" \
    --for=delete \
    --timeout=120s >/dev/null 2>&1 || true
}

warmup_runtime_efa_nodes() {
  local kubectl_context

  if ! bool_is_true "$RUNTIME_WARMUP" RUNTIME_WARMUP; then
    echo "Skipping runtime EFA node warm-up."
    return 0
  fi

  echo "Warming EFA node group before runtime validation..."
  aws eks update-kubeconfig \
    --name "$EKS_CLUSTER_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" 2>&1 |
    tee "${RUN_DIR}/runtime-warmup-update-kubeconfig.log"
  kubectl_context="$(kubectl config current-context)"

  scale_runtime_nodegroup_to "$EFA_WORKER_COUNT" true
  WARMUP_NODEGROUP_ACTIVE=1

  wait_for_runtime_nodes_ready "$kubectl_context"
  protect_runtime_nodes_from_scale_down "$kubectl_context"
  wait_for_runtime_resources "$kubectl_context"
  prepull_runtime_image "$kubectl_context"
  echo "Runtime EFA warm-up complete."
}

run_validation_command() {
  local kubectl_context="$1"
  local head_pod="$2"
  local log_file="$3"
  shift 3

  kubectl --context "$kubectl_context" exec \
    -n anyscale-operator \
    "$head_pod" \
    -c ray \
    -- "$@" 2>&1 |
    tee "$log_file"
}

run_runtime_validation() {
  local create_output create_code workspace_output workspace_code
  local kubectl_context head_selector worker_selector head_pod action
  local validation_logs_dir
  local validation_status=0

  echo "Writing runtime validation configs..."
  write_runtime_compute_config

  echo "Creating Anyscale compute config ${RUNTIME_COMPUTE_CONFIG_NAME}..."
  set +e
  create_output="$(
    anyscale compute-config create \
      -n "$RUNTIME_COMPUTE_CONFIG_NAME" \
      -f "$RUNTIME_COMPUTE_CONFIG_FILE" 2>&1
  )"
  create_code=$?
  set -e
  printf '%s\n' "$create_output" | tee "${RUN_DIR}/runtime-compute-config-create.log"
  if (( create_code != 0 )); then
    echo "Anyscale compute config creation failed. See ${RUN_DIR}/runtime-compute-config-create.log" >&2
    exit "$create_code"
  fi

  RUNTIME_COMPUTE_CONFIG_REF="$(
    printf '%s\n' "$create_output" |
      sed -n "s/.*Created compute config: '\([^']*\)'.*/\1/p" |
      head -1
  )"

  if [[ -z "$RUNTIME_COMPUTE_CONFIG_REF" ]]; then
    echo "Could not parse compute config reference from Anyscale output." >&2
    exit 1
  fi

  write_runtime_workspace_config

  echo "Creating validation workspace ${RUNTIME_WORKSPACE_NAME}..."
  set +e
  workspace_output="$(anyscale workspace_v2 create -f "$RUNTIME_WORKSPACE_FILE" 2>&1)"
  workspace_code=$?
  set -e
  printf '%s\n' "$workspace_output" | tee "${RUN_DIR}/runtime-workspace-create.log"
  if (( workspace_code != 0 )); then
    echo "Validation workspace creation failed. See ${RUN_DIR}/runtime-workspace-create.log" >&2
    exit "$workspace_code"
  fi

  RUNTIME_WORKSPACE_ID="$(
    printf '%s\n' "$workspace_output" |
      grep -Eo 'expwrk_[A-Za-z0-9]+' |
      head -1 || true
  )"

  if [[ -z "$RUNTIME_WORKSPACE_ID" ]]; then
    echo "Could not parse workspace ID (expwrk_...) from Anyscale output." >&2
    exit 1
  fi

  echo "Starting validation workspace ${RUNTIME_WORKSPACE_ID}..."
  anyscale workspace_v2 start --id "$RUNTIME_WORKSPACE_ID" 2>&1 |
    tee "${RUN_DIR}/runtime-workspace-start.log"

  anyscale workspace_v2 wait \
    --id "$RUNTIME_WORKSPACE_ID" \
    --state RUNNING \
    --timeout-s "$RUNTIME_WAIT_TIMEOUT_SECONDS" 2>&1 |
    tee "${RUN_DIR}/runtime-workspace-wait-running.log"

  echo "Refreshing kubeconfig for ${EKS_CLUSTER_NAME}..."
  aws eks update-kubeconfig \
    --name "$EKS_CLUSTER_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" 2>&1 |
    tee "${RUN_DIR}/runtime-update-kubeconfig.log"
  kubectl_context="$(kubectl config current-context)"

  head_selector="anyscale-workspace-id=${RUNTIME_WORKSPACE_ID},ray-node-type=head"
  worker_selector="anyscale-workspace-id=${RUNTIME_WORKSPACE_ID},ray-node-type=worker"

  wait_for_pod_count "$head_selector" 1 "head" "$kubectl_context"
  wait_for_pod_count "$worker_selector" "$EFA_WORKER_COUNT" "worker" "$kubectl_context"

  kubectl --context "$kubectl_context" wait \
    --for=condition=Ready pod \
    -n anyscale-operator \
    -l "$head_selector" \
    --timeout="$RUNTIME_KUBECTL_WAIT_TIMEOUT" 2>&1 |
    tee "${RUN_DIR}/runtime-kubectl-wait-head.log"

  kubectl --context "$kubectl_context" wait \
    --for=condition=Ready pod \
    -n anyscale-operator \
    -l "$worker_selector" \
    --timeout="$RUNTIME_KUBECTL_WAIT_TIMEOUT" 2>&1 |
    tee "${RUN_DIR}/runtime-kubectl-wait-workers.log"

  protect_workspace_nodes_from_scale_down "$kubectl_context" "$head_selector" "$worker_selector"
  tag_cluster_autoscaling_groups_for_gc "${RUN_DIR}/cluster-asg-custodian-tags-after-validation.log"
  tag_cluster_instances_for_gc "${RUN_DIR}/cluster-instance-custodian-tags-after-validation.log"

  head_pod="$(
    kubectl --context "$kubectl_context" get pods \
      -n anyscale-operator \
      -l "$head_selector" \
      -o jsonpath='{.items[0].metadata.name}'
  )"

  echo "Detecting Ray compute nodes from ${head_pod}..."
  if ! run_validation_command \
    "$kubectl_context" \
    "$head_pod" \
    "${RUN_DIR}/runtime-detect-compute-nodes.log" \
    bash -lc 'export PATH="/opt/efa-middle/scripts:$PATH"; detect_compute_nodes --details'; then
    validation_status=1
  fi

  IFS=',' read -ra validation_actions <<<"$RUNTIME_VALIDATION_ACTIONS"
  for action in "${validation_actions[@]}"; do
    if (( validation_status != 0 )); then
      break
    fi
    action="$(printf '%s' "$action" | xargs)"
    if [[ -z "$action" ]]; then
      continue
    fi
    echo "Running validation action: ${action}"
    if ! run_validation_command \
      "$kubectl_context" \
      "$head_pod" \
      "${RUN_DIR}/runtime-validation-${action}.log" \
      bash -lc 'export PATH="/opt/efa-middle/scripts:$PATH"; validate_compute_nodes "$1"' _ "$action"; then
      validation_status=1
    fi
  done

  validation_logs_dir="${RUN_DIR}/efa_validation_logs"
  rm -rf "$validation_logs_dir"
  if ! kubectl --context "$kubectl_context" cp \
    -n anyscale-operator \
    -c ray \
    "${head_pod}:/home/ray/default/efa_validation_logs" \
    "$validation_logs_dir" 2>&1 |
    tee "${RUN_DIR}/runtime-copy-validation-logs.log"; then
    echo "Warning: could not copy validation logs from workspace head pod." >&2
  fi

  cat >>"$OUTPUT_ENV_FILE" <<EOF
export RUNTIME_WORKSPACE_ID="${RUNTIME_WORKSPACE_ID}"
export RUNTIME_WORKSPACE_NAME="${RUNTIME_WORKSPACE_NAME}"
export RUNTIME_COMPUTE_CONFIG_REF="${RUNTIME_COMPUTE_CONFIG_REF}"
export RUNTIME_IMAGE_URI="${RUNTIME_IMAGE_URI}"
export RUNTIME_VALIDATION_ACTIONS="${RUNTIME_VALIDATION_ACTIONS}"
EOF

  if (( validation_status != 0 )); then
    echo "Runtime validation failed. See logs in ${RUN_DIR}." >&2
    echo "Validation workspace was left running for debugging and handoff: ${RUNTIME_WORKSPACE_ID}" >&2
    return "$validation_status"
  fi

  echo "Runtime validation passed. Workspace is running for handoff: ${RUNTIME_WORKSPACE_ID}"
  echo "Workspace head and worker nodes are protected from Cluster Autoscaler scale-down."
}

mkdir -p "$RUN_DIR"

echo "Checking AWS identity..."
aws sts get-caller-identity \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --query '{Account:Account,Arn:Arn}' \
  --output table

echo "Inspecting capacity reservation ${EFA_CAPACITY_RESERVATION_ID}..."
reservation_row="$(
  aws ec2 describe-capacity-reservations \
    --capacity-reservation-ids "$EFA_CAPACITY_RESERVATION_ID" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'CapacityReservations[0].[State,AvailabilityZone,AvailabilityZoneId,InstanceType,AvailableInstanceCount,TotalInstanceCount,InstanceMatchCriteria]' \
    --output text
)"

read -r CR_STATE CR_AZ CR_AZ_ID CR_INSTANCE_TYPE CR_AVAILABLE CR_TOTAL CR_MATCH <<<"$reservation_row"

if [[ -z "${CR_STATE:-}" || "$CR_STATE" == "None" ]]; then
  echo "Capacity reservation not found: ${EFA_CAPACITY_RESERVATION_ID}" >&2
  exit 1
fi

if [[ "$CR_AZ_ID" == "None" || -z "$CR_AZ_ID" ]]; then
  CR_AZ_ID="$(
    aws ec2 describe-availability-zones \
      --zone-names "$CR_AZ" \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --query 'AvailabilityZones[0].ZoneId' \
      --output text
  )"
fi

cat <<EOF
Capacity reservation:
  state:          ${CR_STATE}
  az:             ${CR_AZ}
  az_id:          ${CR_AZ_ID}
  instance_type:  ${CR_INSTANCE_TYPE}
  available:      ${CR_AVAILABLE}
  total:          ${CR_TOTAL}
  match:          ${CR_MATCH}
EOF

if [[ "$CR_STATE" != "active" ]]; then
  echo "Capacity reservation must be active." >&2
  exit 1
fi

if [[ "$CR_INSTANCE_TYPE" != "$EFA_EXPECTED_INSTANCE_TYPE" ]]; then
  echo "Expected reservation instance type ${EFA_EXPECTED_INSTANCE_TYPE}, got ${CR_INSTANCE_TYPE}." >&2
  exit 1
fi

TARGET_EFA_INSTANCE_COUNT="$(count_target_efa_instances)"
CR_USABLE_FOR_RUN=$((CR_AVAILABLE + TARGET_EFA_INSTANCE_COUNT))

if (( EFA_WORKER_COUNT > 0 && CR_USABLE_FOR_RUN < EFA_WORKER_COUNT )); then
  echo "Capacity reservation has ${CR_AVAILABLE} available instance(s) plus ${TARGET_EFA_INSTANCE_COUNT} running target EFA node(s), but EFA_WORKER_COUNT=${EFA_WORKER_COUNT}." >&2
  echo "Reduce EFA_WORKER_COUNT for infra-only testing, or free reservation capacity before workspace validation." >&2
  exit 1
fi

if [[ "$CR_MATCH" != "targeted" ]]; then
  echo "Warning: reservation match criteria is '${CR_MATCH}', not 'targeted'." >&2
fi

cat >"$TFVARS_FILE" <<EOF
eks_cluster_name = "${EKS_CLUSTER_NAME}"
aws_region       = "${AWS_REGION}"

gpu_instance_types = {}

node_group_disk_size = ${NODE_GROUP_DISK_SIZE}
enable_efs           = ${ENABLE_EFS}

efa_capacity_reservation_id    = "${EFA_CAPACITY_RESERVATION_ID}"
efa_capacity_reservation_az_id = "${CR_AZ_ID}"
efa_private_subnet_cidr        = "${EFA_PRIVATE_SUBNET_CIDR}"
efa_workload_name              = "${EFA_WORKLOAD_NAME}"

tags = {
  Project                  = "${EKS_CLUSTER_NAME}"
  Environment              = "${TAGS_ENVIRONMENT}"
  ManagedBy                = "pipeline/provision-aws-efa-anyscale.sh"
  EfaCapacityReservationId = "${EFA_CAPACITY_RESERVATION_ID}"
  "ttl-hours"              = "${TAGS_TTL_HOURS}"
  "anyscale-user"          = "${TAGS_ANYSCALE_USER}"
  "anyscale-custodian"     = "${TAGS_ANYSCALE_CUSTODIAN}"
}
EOF

cat >"${RUN_DIR}/inputs.env" <<EOF
export AWS_PROFILE="${AWS_PROFILE}"
export AWS_REGION="${AWS_REGION}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION}"
export CLOUD_NAME="${CLOUD_NAME:-$EKS_CLUSTER_NAME}"
export EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME}"
export ANYSCALE_CLOUD_NAME="${ANYSCALE_CLOUD_NAME}"
export EFA_CAPACITY_RESERVATION_ID="${EFA_CAPACITY_RESERVATION_ID}"
export EFA_CAPACITY_RESERVATION_AZ_NAME="${CR_AZ}"
export EFA_CAPACITY_RESERVATION_AZ_ID="${CR_AZ_ID}"
export EFA_WORKER_COUNT="${EFA_WORKER_COUNT}"
export EFA_WORKLOAD_NAME="${EFA_WORKLOAD_NAME}"
export TAGS_TTL_HOURS="${TAGS_TTL_HOURS}"
export TAGS_ANYSCALE_USER="${TAGS_ANYSCALE_USER}"
export TAGS_ANYSCALE_CUSTODIAN="${TAGS_ANYSCALE_CUSTODIAN}"
export TF_WORKSPACE_NAME="${TF_WORKSPACE_NAME}"
export RUN_DIR="${RUN_DIR}"
export RUN_RUNTIME_VALIDATION="${RUN_RUNTIME_VALIDATION}"
export RUNTIME_WORKSPACE_NAME="${RUNTIME_WORKSPACE_NAME}"
export RUNTIME_COMPUTE_CONFIG_NAME="${RUNTIME_COMPUTE_CONFIG_NAME}"
export RUNTIME_IMAGE_URI="${RUNTIME_IMAGE_URI}"
export RUNTIME_RAY_VERSION="${RUNTIME_RAY_VERSION}"
export RUNTIME_VALIDATION_ACTIONS="${RUNTIME_VALIDATION_ACTIONS}"
export RUNTIME_WARMUP="${RUNTIME_WARMUP}"
export RUNTIME_PREPULL_IMAGE="${RUNTIME_PREPULL_IMAGE}"
export EFA_WARMUP_TIMEOUT_SECONDS="${EFA_WARMUP_TIMEOUT_SECONDS}"
export RUNTIME_PREPULL_TIMEOUT_SECONDS="${RUNTIME_PREPULL_TIMEOUT_SECONDS}"
EOF

echo "Wrote ${TFVARS_FILE}"

cd "$EXAMPLE_DIR"

echo "Initializing Terraform in ${EXAMPLE_DIR}..."
terraform init

PREVIOUS_TF_WORKSPACE="$(terraform workspace show)"
cleanup() {
  cleanup_runtime_validation
  terraform workspace select "$PREVIOUS_TF_WORKSPACE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if terraform workspace select "$TF_WORKSPACE_NAME" >/dev/null 2>&1; then
  echo "Using existing Terraform workspace: ${TF_WORKSPACE_NAME}"
else
  echo "Creating Terraform workspace: ${TF_WORKSPACE_NAME}"
  terraform workspace new "$TF_WORKSPACE_NAME" >/dev/null
fi
assert_terraform_workspace

terraform validate

echo "Planning Terraform changes..."
terraform plan \
  -var-file="$TFVARS_FILE" \
  -out="$PLAN_FILE"

if (( APPLY == 0 )); then
  cat <<EOF

Plan saved to:
  ${PLAN_FILE}

No resources were created. To apply this exact path, run:
  CLOUD_NAME="${CLOUD_NAME:-$EKS_CLUSTER_NAME}" \\
  EFA_CAPACITY_RESERVATION_ID="${EFA_CAPACITY_RESERVATION_ID}" \\
  AWS_PROFILE="${AWS_PROFILE}" \\
  AWS_REGION="${AWS_REGION}" \\
  EFA_WORKER_COUNT="${EFA_WORKER_COUNT}" \\
  EFA_WORKLOAD_NAME="${EFA_WORKLOAD_NAME}" \\
  $0 --apply

Generated run files:
  ${RUN_DIR}
EOF
  exit 0
fi

echo "Applying Terraform plan..."
terraform apply -auto-approve "$PLAN_FILE"
assert_terraform_outputs_match_run
tag_cluster_autoscaling_groups_for_gc "${RUN_DIR}/cluster-asg-custodian-tags-after-apply.log"
tag_cluster_instances_for_gc "${RUN_DIR}/cluster-instance-custodian-tags-after-apply.log"

REGISTER_COMMAND="$(
  terraform output -raw anyscale_registration_command |
    sed "s/<anyscale_cloud_name>/${ANYSCALE_CLOUD_NAME}/g"
)"
EXPECTED_S3_BUCKET_ID="$(registration_arg "$REGISTER_COMMAND" "--s3-bucket-id")"
EXPECTED_OPERATOR_IAM_IDENTITY="$(registration_arg "$REGISTER_COMMAND" "--anyscale-operator-iam-identity")"

if [[ -z "$EXPECTED_S3_BUCKET_ID" || -z "$EXPECTED_OPERATOR_IAM_IDENTITY" ]]; then
  printf '%s\n' "$REGISTER_COMMAND" >&2
  echo "Could not parse expected S3 bucket or operator IAM identity from Terraform registration command." >&2
  exit 1
fi

if (( SKIP_REGISTER == 0 )); then
  if [[ -n "$ANYSCALE_CLOUD_RESOURCE_ID" ]]; then
    echo "Using existing ANYSCALE_CLOUD_RESOURCE_ID=${ANYSCALE_CLOUD_RESOURCE_ID}; skipping registration."
  else
    ANYSCALE_CLOUD_RESOURCE_ID="$(
      find_existing_anyscale_cloud_resource "$EXPECTED_S3_BUCKET_ID" "$EXPECTED_OPERATOR_IAM_IDENTITY" || true
    )"

    if [[ -n "$ANYSCALE_CLOUD_RESOURCE_ID" ]]; then
      echo "Using existing Anyscale cloud resource ${ANYSCALE_CLOUD_RESOURCE_ID} for ${ANYSCALE_CLOUD_NAME}; skipping registration."
    else
    printf '%s\n' "$REGISTER_COMMAND" >"${RUN_DIR}/anyscale-register-command.sh"
    chmod +x "${RUN_DIR}/anyscale-register-command.sh"

    echo "Registering Anyscale cloud ${ANYSCALE_CLOUD_NAME}..."
    set +e
    REGISTER_OUTPUT="$(bash -lc "$REGISTER_COMMAND" 2>&1)"
    REGISTER_CODE=$?
    set -e
    printf '%s\n' "$REGISTER_OUTPUT" | tee "${RUN_DIR}/anyscale-register.log"
    if (( REGISTER_CODE != 0 )); then
      if grep -q 'already exists' "${RUN_DIR}/anyscale-register.log"; then
        echo "Cloud ${ANYSCALE_CLOUD_NAME} already exists, but no matching cloud resource was found for this Terraform output." >&2
        echo "Set ANYSCALE_CLOUD_RESOURCE_ID=cldrsrc_... with --skip-register, or choose a new ANYSCALE_CLOUD_NAME." >&2
      fi
      echo "anyscale cloud register failed. See ${RUN_DIR}/anyscale-register.log" >&2
      exit "$REGISTER_CODE"
    fi

    ANYSCALE_CLOUD_RESOURCE_ID="$(
      printf '%s\n' "$REGISTER_OUTPUT" |
        grep -Eo 'cldrsrc_[A-Za-z0-9]+' |
        head -1 || true
    )"

    if [[ -z "$ANYSCALE_CLOUD_RESOURCE_ID" ]]; then
      echo "Could not parse Cloud Deployment ID (cldrsrc_...) from registration output." >&2
      echo "Set ANYSCALE_CLOUD_RESOURCE_ID manually and rerun with --skip-register." >&2
      exit 1
    fi
    fi
  fi
elif [[ -z "$ANYSCALE_CLOUD_RESOURCE_ID" && "$SKIP_HELM" == "0" ]]; then
  echo "--skip-register requires ANYSCALE_CLOUD_RESOURCE_ID=cldrsrc_... unless --skip-helm is also set." >&2
  exit 1
fi

verify_anyscale_cloud_resource "$EXPECTED_S3_BUCKET_ID" "$EXPECTED_OPERATOR_IAM_IDENTITY"

cat >"$OUTPUT_ENV_FILE" <<EOF
export AWS_PROFILE="${AWS_PROFILE}"
export AWS_REGION="${AWS_REGION}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION}"
export CLOUD_NAME="${CLOUD_NAME:-$EKS_CLUSTER_NAME}"
export EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME}"
export ANYSCALE_CLOUD_NAME="${ANYSCALE_CLOUD_NAME}"
export ANYSCALE_CLOUD_RESOURCE_ID="${ANYSCALE_CLOUD_RESOURCE_ID}"
export EFA_CAPACITY_RESERVATION_ID="${EFA_CAPACITY_RESERVATION_ID}"
export EFA_CAPACITY_RESERVATION_AZ_NAME="${CR_AZ}"
export EFA_CAPACITY_RESERVATION_AZ_ID="${CR_AZ_ID}"
export EFA_WORKER_COUNT="${EFA_WORKER_COUNT}"
export EFA_WORKLOAD_NAME="${EFA_WORKLOAD_NAME}"
export TF_WORKSPACE_NAME="${TF_WORKSPACE_NAME}"
export RUN_DIR="${RUN_DIR}"
export RUN_RUNTIME_VALIDATION="${RUN_RUNTIME_VALIDATION}"
export RUNTIME_WORKSPACE_NAME="${RUNTIME_WORKSPACE_NAME}"
export RUNTIME_COMPUTE_CONFIG_NAME="${RUNTIME_COMPUTE_CONFIG_NAME}"
export RUNTIME_IMAGE_URI="${RUNTIME_IMAGE_URI}"
export RUNTIME_RAY_VERSION="${RUNTIME_RAY_VERSION}"
export RUNTIME_VALIDATION_ACTIONS="${RUNTIME_VALIDATION_ACTIONS}"
export RUNTIME_WARMUP="${RUNTIME_WARMUP}"
export RUNTIME_PREPULL_IMAGE="${RUNTIME_PREPULL_IMAGE}"
export EFA_WARMUP_TIMEOUT_SECONDS="${EFA_WARMUP_TIMEOUT_SECONDS}"
export RUNTIME_PREPULL_TIMEOUT_SECONDS="${RUNTIME_PREPULL_TIMEOUT_SECONDS}"
EOF

if (( SKIP_HELM == 0 )); then
  echo "Installing Helm add-ons and Anyscale operator..."
  AWS_PROFILE="$AWS_PROFILE" \
  AWS_REGION="$AWS_REGION" \
  EKS_CLUSTER_NAME="$EKS_CLUSTER_NAME" \
  EFA_WORKLOAD_NAME="$EFA_WORKLOAD_NAME" \
  ECR_REGISTRY="$ECR_REGISTRY" \
  ECR_MIRROR_PREFIX="$ECR_MIRROR_PREFIX" \
  ANYSCALE_CLOUD_RESOURCE_ID="$ANYSCALE_CLOUD_RESOURCE_ID" \
  TF_WORKSPACE_NAME="$TF_WORKSPACE_NAME" \
  EXAMPLE_DIR="$EXAMPLE_DIR" \
    "${SCRIPT_DIR}/install-helm-addons.sh" 2>&1 | tee "${RUN_DIR}/install-helm-addons.log"
fi

if (( SKIP_VERIFY == 0 )); then
  echo "Verifying Anyscale cloud..."
  aws eks update-kubeconfig \
    --name "$EKS_CLUSTER_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" >/dev/null
  VERIFY_CONTEXT="$(kubectl config current-context)"
  if ! VERIFY_CONTEXT_NUMBER="$(kubectl_context_number "$VERIFY_CONTEXT")"; then
    echo "Could not find kubectl context number for ${VERIFY_CONTEXT}." >&2
    kubectl config get-contexts -o name >&2
    exit 1
  fi
  echo "Using kubectl context ${VERIFY_CONTEXT_NUMBER}: ${VERIFY_CONTEXT}"
  set +e
  VERIFY_OUTPUT="$(
    printf '%s\nanyscale-operator\n' "$VERIFY_CONTEXT_NUMBER" |
      anyscale cloud verify --name "$ANYSCALE_CLOUD_NAME" 2>&1
  )"
  VERIFY_CODE=$?
  set -e
  printf '%s\n' "$VERIFY_OUTPUT" | tee "${RUN_DIR}/anyscale-cloud-verify.log"
  if (( VERIFY_CODE != 0 )) || ! grep -q 'Overall Result: ALL .* verified successfully' "${RUN_DIR}/anyscale-cloud-verify.log"; then
    echo "anyscale cloud verify did not report success. See ${RUN_DIR}/anyscale-cloud-verify.log" >&2
    exit 1
  fi

  anyscale cloud status --name "$ANYSCALE_CLOUD_NAME" 2>&1 |
    tee "${RUN_DIR}/anyscale-cloud-status.log"
fi

if (( RUN_RUNTIME_VALIDATION == 1 )); then
  warmup_runtime_efa_nodes
  run_runtime_validation
fi

cat <<EOF

Provisioning complete.

Run metadata:
  ${OUTPUT_ENV_FILE}

Terraform workspace:
  ${TF_WORKSPACE_NAME}

Anyscale cloud:
  ${ANYSCALE_CLOUD_NAME}

Cloud Deployment ID:
  ${ANYSCALE_CLOUD_RESOURCE_ID}
EOF

if (( RUN_RUNTIME_VALIDATION == 1 )); then
  cat <<EOF

Runtime validation:
  workspace:       ${RUNTIME_WORKSPACE_NAME}
  workspace_id:    ${RUNTIME_WORKSPACE_ID}
  compute_config:  ${RUNTIME_COMPUTE_CONFIG_REF}
  actions:         ${RUNTIME_VALIDATION_ACTIONS}
  logs:            ${RUN_DIR}/efa_validation_logs
EOF
fi
