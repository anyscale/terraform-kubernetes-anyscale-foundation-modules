#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)"
DEFAULT_EXAMPLE_DIR="${SCRIPT_DIR}"
EXAMPLE_DIR="${EXAMPLE_DIR:-${DEFAULT_EXAMPLE_DIR}}"

AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
EFA_WORKLOAD_NAME="${EFA_WORKLOAD_NAME:-efa}"
ECR_REGISTRY="${ECR_REGISTRY:-}"
ECR_MIRROR_PREFIX="${ECR_MIRROR_PREFIX:-}"
TF_WORKSPACE_NAME="${TF_WORKSPACE_NAME:-}"
ANYSCALE_CLOUD_RESOURCE_ID="${ANYSCALE_CLOUD_RESOURCE_ID:-}"
ANYSCALE_CLOUD_RESOURCE_SOURCE="environment"
HELM_TIMEOUT="${HELM_TIMEOUT:-15m}"

export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"
export PATH="$HOME/.local/bin:$PATH"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need aws
need kubectl
need helm
need terraform

if [[ -z "$AWS_PROFILE" ]]; then
  echo "Set AWS_PROFILE to the named AWS CLI profile to use for this deployment." >&2
  exit 1
fi

if [[ -z "$EKS_CLUSTER_NAME" ]]; then
  echo "Set EKS_CLUSTER_NAME before running this script." >&2
  exit 1
fi

if [[ -z "$ECR_REGISTRY" || -z "$ECR_MIRROR_PREFIX" ]]; then
  echo "Set ECR_REGISTRY and ECR_MIRROR_PREFIX before installing Helm add-ons." >&2
  exit 1
fi

if [[ ! -d "$EXAMPLE_DIR" ]]; then
  echo "EXAMPLE_DIR does not exist: ${EXAMPLE_DIR}" >&2
  echo "Set EXAMPLE_DIR to the terraform-kubernetes-anyscale-foundation-modules/examples/aws/eks-public-efa path." >&2
  exit 1
fi

assert_terraform_outputs_match_run() {
  local current_workspace output_cluster_name

  if [[ -n "$TF_WORKSPACE_NAME" ]]; then
    current_workspace="$(terraform workspace show)"
    if [[ "$current_workspace" != "$TF_WORKSPACE_NAME" ]]; then
      echo "Terraform workspace mismatch in Helm installer." >&2
      echo "Expected: ${TF_WORKSPACE_NAME}" >&2
      echo "Current:  ${current_workspace}" >&2
      exit 1
    fi
  fi

  output_cluster_name="$(terraform output -raw eks_cluster_name 2>/dev/null || true)"
  if [[ -n "$output_cluster_name" && "$output_cluster_name" != "$EKS_CLUSTER_NAME" ]]; then
    echo "Terraform output mismatch in Helm installer: eks_cluster_name does not match this run." >&2
    echo "Expected: ${EKS_CLUSTER_NAME}" >&2
    echo "Output:   ${output_cluster_name}" >&2
    echo "Refusing to install Helm add-ons against stale Terraform state." >&2
    exit 1
  fi
}

collect_anyscale_operator_diagnostics() {
  echo "Collecting Anyscale Operator diagnostics..." >&2
  helm status anyscale-operator -n anyscale-operator >&2 || true
  kubectl get pods -n anyscale-operator -o wide >&2 || true
  kubectl get events -n anyscale-operator --sort-by=.lastTimestamp >&2 || true

  local pod
  for pod in $(kubectl get pods -n anyscale-operator -l app=anyscale-operator -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo "Describing pod ${pod}..." >&2
    kubectl describe pod "$pod" -n anyscale-operator >&2 || true
    echo "Current operator logs for ${pod}..." >&2
    kubectl logs "$pod" -n anyscale-operator -c operator --tail=200 >&2 || true
    echo "Previous operator logs for ${pod}..." >&2
    kubectl logs "$pod" -n anyscale-operator -c operator --previous --tail=200 >&2 || true
  done
}

cd "$EXAMPLE_DIR"

PREVIOUS_TF_WORKSPACE=""
if [[ -n "$TF_WORKSPACE_NAME" ]]; then
  PREVIOUS_TF_WORKSPACE="$(terraform workspace show)"
  terraform workspace select "$TF_WORKSPACE_NAME" >/dev/null
fi
assert_terraform_outputs_match_run

for file in sample-values_efa.yaml sample-values_nvdp.yaml; do
  if [[ ! -f "$file" ]]; then
    echo "Missing ${EXAMPLE_DIR}/${file}" >&2
    exit 1
  fi
done

if [[ -z "$ANYSCALE_CLOUD_RESOURCE_ID" && -f values.yaml ]]; then
  ANYSCALE_CLOUD_RESOURCE_SOURCE="${EXAMPLE_DIR}/values.yaml"
  ANYSCALE_CLOUD_RESOURCE_ID="$(
    sed -n 's/^[[:space:]]*cloudDeploymentId:[[:space:]]*//p' values.yaml | head -1
  )"
fi

if [[ -z "$ANYSCALE_CLOUD_RESOURCE_ID" ]]; then
  echo "Set ANYSCALE_CLOUD_RESOURCE_ID=cldrsrc_... before running this script." >&2
  echo "Use the Cloud Deployment ID printed by 'anyscale cloud register'." >&2
  exit 1
fi

ANYSCALE_CLOUD_RESOURCE_DNS_ID="${ANYSCALE_CLOUD_RESOURCE_ID//_/-}"
RENDER_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$RENDER_DIR"
  if [[ -n "$PREVIOUS_TF_WORKSPACE" ]]; then
    terraform workspace select "$PREVIOUS_TF_WORKSPACE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

render_device_plugin_values() {
  local source_file="$1"
  local target_file="$2"

  awk -v workload="$EFA_WORKLOAD_NAME" '
    /^[[:space:]]*value:[[:space:]]*h100-efa[[:space:]]*$/ {
      sub(/h100-efa/, workload)
    }
    { print }
  ' "$source_file" > "$target_file"
}

echo "Rendering device plugin values for workload ${EFA_WORKLOAD_NAME}..."
render_device_plugin_values sample-values_efa.yaml "${RENDER_DIR}/sample-values_efa.yaml"
render_device_plugin_values sample-values_nvdp.yaml "${RENDER_DIR}/sample-values_nvdp.yaml"

echo "Using Anyscale Cloud Deployment ID from ${ANYSCALE_CLOUD_RESOURCE_SOURCE}: ${ANYSCALE_CLOUD_RESOURCE_ID}"

echo "Updating kubeconfig for ${EKS_CLUSTER_NAME} in ${AWS_REGION}..."
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$EKS_CLUSTER_NAME" \
  --profile "$AWS_PROFILE"

echo "Adding/updating Helm repositories..."
helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null
helm repo add anyscale https://anyscale.github.io/helm-charts >/dev/null
helm repo update

VPC_ID="$(terraform output -raw vpc_id 2>/dev/null || terraform console <<< 'module.anyscale_vpc.vpc_id' | tr -d '"')"
GATEWAY_NLB_SECURITY_GROUP_ID="$(terraform output -raw gateway_nlb_security_group_id)"

echo "Installing/upgrading Cluster Autoscaler..."
helm upgrade cluster-autoscaler autoscaler/cluster-autoscaler \
  --version 9.46.0 \
  --namespace kube-system \
  --set awsRegion="$AWS_REGION" \
  --set "autoDiscovery.clusterName=$EKS_CLUSTER_NAME" \
  --set image.repository="${ECR_REGISTRY}/${ECR_MIRROR_PREFIX}/autoscaling/cluster-autoscaler" \
  --set image.tag="v1.32.0" \
  --install \
  --wait \
  --timeout "$HELM_TIMEOUT"

echo "Installing/upgrading AWS Load Balancer Controller..."
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 1.13.2 \
  --namespace kube-system \
  --set clusterName="$EKS_CLUSTER_NAME" \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --set image.repository="${ECR_REGISTRY}/${ECR_MIRROR_PREFIX}/eks/aws-load-balancer-controller" \
  --set image.tag="v2.13.2" \
  --set enableShield=false \
  --set enableWaf=false \
  --set enableWafv2=false \
  --install \
  --wait \
  --timeout "$HELM_TIMEOUT"

echo "Installing/upgrading EFA device plugin..."
helm upgrade efa eks/aws-efa-k8s-device-plugin \
  --namespace kube-system \
  --set image.repository="${ECR_REGISTRY}/${ECR_MIRROR_PREFIX}/eks/aws-efa-k8s-device-plugin" \
  --set image.tag="v0.5.19" \
  --values "${RENDER_DIR}/sample-values_efa.yaml" \
  --install \
  --wait \
  --timeout "$HELM_TIMEOUT"

echo "Installing/upgrading NVIDIA device plugin..."
helm upgrade nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --version 0.17.1 \
  --set image.repository="${ECR_REGISTRY}/${ECR_MIRROR_PREFIX}/nvidia/k8s-device-plugin" \
  --set image.tag="v0.17.1" \
  --values "${RENDER_DIR}/sample-values_nvdp.yaml" \
  --create-namespace \
  --install \
  --wait \
  --timeout "$HELM_TIMEOUT"

echo "Restarting Cluster Autoscaler to refresh scale-up backoff..."
kubectl rollout restart deployment \
  -n kube-system \
  -l app.kubernetes.io/name=aws-cluster-autoscaler,app.kubernetes.io/instance=cluster-autoscaler
kubectl rollout status deployment \
  -n kube-system \
  -l app.kubernetes.io/name=aws-cluster-autoscaler,app.kubernetes.io/instance=cluster-autoscaler \
  --timeout=120s

echo "Installing/upgrading Envoy Gateway..."
helm upgrade eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 \
  --namespace envoy-gateway-system \
  --create-namespace \
  --set global.images.envoyGateway.image="${ECR_REGISTRY}/${ECR_MIRROR_PREFIX}/envoyproxy/gateway:v1.7.0" \
  --set global.images.ratelimit.image="${ECR_REGISTRY}/${ECR_MIRROR_PREFIX}/envoyproxy/ratelimit:3fb70258" \
  --install \
  --wait \
  --timeout "$HELM_TIMEOUT"

kubectl wait --for=condition=available deployment/envoy-gateway \
  -n envoy-gateway-system \
  --timeout=180s

echo "Applying Gateway API resources..."
kubectl create namespace anyscale-operator --dry-run=client -o yaml | kubectl apply -f -

cat >"${RENDER_DIR}/envoyproxy.yaml" <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: envoy-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        container:
          image: ${ECR_REGISTRY}/${ECR_MIRROR_PREFIX}/envoyproxy/envoy:distroless-v1.36.2
      envoyService:
        type: LoadBalancer
        annotations:
          service.beta.kubernetes.io/aws-load-balancer-type: external
          service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
          service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
          service.beta.kubernetes.io/aws-load-balancer-security-groups: ${GATEWAY_NLB_SECURITY_GROUP_ID}
          service.beta.kubernetes.io/aws-load-balancer-manage-backend-security-group-rules: "true"
EOF

cat >"${RENDER_DIR}/gatewayclass.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: envoy-proxy
    namespace: envoy-gateway-system
EOF

cat >"${RENDER_DIR}/gateway.yaml" <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: gateway
  namespace: anyscale-operator
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      port: 443
      protocol: HTTPS
      hostname: "*.i.anyscaleuserdata.com"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: anyscale-${ANYSCALE_CLOUD_RESOURCE_DNS_ID}-certificate
      allowedRoutes:
        namespaces:
          from: All
    - name: https-session
      port: 443
      protocol: HTTPS
      hostname: "*.s.anyscaleuserdata.com"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: anyscale-svc-${ANYSCALE_CLOUD_RESOURCE_DNS_ID}-certificate
      allowedRoutes:
        namespaces:
          from: All
EOF

kubectl apply -f "${RENDER_DIR}/envoyproxy.yaml"
kubectl apply -f "${RENDER_DIR}/gatewayclass.yaml"
kubectl apply -f "${RENDER_DIR}/gateway.yaml"

echo "Waiting for Gateway address..."
kubectl wait --for=condition=Programmed gateway/gateway \
  -n anyscale-operator \
  --timeout=300s || true

GATEWAY_ADDRESS=""
for _ in {1..60}; do
  GATEWAY_ADDRESS="$(
    kubectl get gateway gateway -n anyscale-operator \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true
  )"
  if [[ -n "$GATEWAY_ADDRESS" ]]; then
    break
  fi
  sleep 10
done

if [[ -z "$GATEWAY_ADDRESS" ]]; then
  echo "Gateway address did not become available." >&2
  kubectl get gateway gateway -n anyscale-operator -o yaml >&2 || true
  exit 1
fi

echo "Gateway address: ${GATEWAY_ADDRESS}"

cat >"${RENDER_DIR}/values.yaml" <<EOF
global:
  cloudDeploymentId: ${ANYSCALE_CLOUD_RESOURCE_ID}
  cloudProvider: aws
  aws:
    region: ${AWS_REGION}

networking:
  gateway:
    enabled: true
    name: gateway
    namespace: anyscale-operator
    apiVersion: gateway.networking.k8s.io/v1
    hostname: ${GATEWAY_ADDRESS}

workloads:
  serviceAccount:
    name: anyscale-operator
  instanceTypes:
    validationHook:
      enabled: false
    additional:
      P5-48XLARGE-8xH100-EFA:
        resources:
          CPU: 190
          memory: 1800Gi
          GPU: 8
          'accelerator_type:H100': 8
          vpc.amazonaws.com/efa: 32
        accelerators:
          - H100
        nodeSelector:
          workload: ${EFA_WORKLOAD_NAME}
          nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
          vpc.amazonaws.com/efa.present: "true"
        tolerations:
          - key: nvidia.com/gpu
            operator: Equal
            value: present
            effect: NoSchedule
          - key: node.anyscale.com/accelerator-type
            operator: Equal
            value: GPU
            effect: NoSchedule
          - key: node.anyscale.com/capacity-type
            operator: Equal
            value: CAPACITY_RESERVATION
            effect: NoSchedule
          - key: workload
            operator: Equal
            value: ${EFA_WORKLOAD_NAME}
            effect: NoSchedule

operator:
  container:
    image:
      registry: ${ECR_REGISTRY}
      image: ${ECR_MIRROR_PREFIX}/anyscale/kubernetes_manager
      tag: ci-2c43cde542a2c6e856c6e49bc99812d7d2f78e17
  vector:
    image:
      registry: ${ECR_REGISTRY}
      image: ${ECR_MIRROR_PREFIX}/timberio/vector
      tag: 0.40.0-debian
EOF

echo "Installing/upgrading Anyscale Operator..."
if ! helm upgrade anyscale-operator anyscale/anyscale-operator \
  --namespace anyscale-operator \
  --version 1.7.0 \
  --values "${RENDER_DIR}/values.yaml" \
  --create-namespace \
  --install \
  --wait \
  --timeout "$HELM_TIMEOUT"; then
  collect_anyscale_operator_diagnostics
  exit 1
fi

echo "Helm add-ons installed/upgraded."
helm list -A
