#!/usr/bin/env bash
# Idempotent in-cluster Kubernetes bootstrap for the Anyscale private AKS setup.
# Runs on the Linux jump host from inside the VNet after the AKS cluster exists.
#
# Usage: ./scripts/bootstrap-k8s.sh phase-a | phase-b
#
# phase-a  operator namespace, ServiceAccount, gpu-resources namespace,
#          NVIDIA device plugin, and Anyscale Gateway (no TLS secret names).
# phase-b  re-run Anyscale Gateway helm upgrade with TLS secret names
#          derived from CLOUD_DEPLOYMENT_ID.
#
# Required env vars (set by orchestrator via invoke_jump_host_bootstrap):
#   AKS_CLUSTER_NAME, AKS_RG
#   OPERATOR_NAMESPACE, OPERATOR_SA_NAME
#   WORKLOAD_IDENTITY_CLIENT_ID, WORKLOAD_IDENTITY_TENANT_ID
#   EXTENSION_RELEASE_NAME
#   GPU_RESOURCES_NAMESPACE
#   NVIDIA_RELEASE_NAME, NVIDIA_CHART_VERSION
#   GATEWAY_RELEASE_NAME, GATEWAY_NAME, GATEWAY_CLASS_NAME, GATEWAY_SERVICE_NAME
#   GATEWAY_PRIVATE_IP
#   CLOUD_DEPLOYMENT_ID        (phase-b only)
#   GATEWAY_SERVICE_HTTPS_ENABLED  (optional; default false)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOG_INFO_PREFIX="bootstrap-k8s"
LOG_WARN_PREFIX="bootstrap-k8s"
LOG_ERROR_PREFIX="bootstrap-k8s"
# shellcheck source=./lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

###############################################################################
# Helpers
###############################################################################

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Required env var ${name} is not set."
}

setup_kubeconfig() {
  log "Acquiring kubeconfig for ${AKS_CLUSTER_NAME} in ${AKS_RG} ..."
  local kubeconfig_file
  kubeconfig_file="${ROOT_DIR}/.cache/kubeconfig.bootstrap-k8s"
  mkdir -p "${ROOT_DIR}/.cache"

  az aks get-credentials \
    --resource-group "${AKS_RG}" \
    --name "${AKS_CLUSTER_NAME}" \
    --file "${kubeconfig_file}" \
    --overwrite-existing \
    --only-show-errors >/dev/null

  kubelogin convert-kubeconfig -l azurecli --kubeconfig "${kubeconfig_file}" >/dev/null
  export KUBECONFIG="${kubeconfig_file}"
  log "Kubeconfig ready (${KUBECONFIG})"
}

wait_for_api_server() {
  local attempts=0
  while [[ ${attempts} -lt 30 ]]; do
    if kubectl get --raw=/livez >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts + 1))
    warn "AKS API server not reachable yet (attempt ${attempts}/30); waiting 10s..."
    sleep 10
  done
  die "Timed out waiting for the AKS API server to become reachable."
}

wait_for_helm_release() {
  local release_name="$1"
  local namespace="$2"
  local attempts=0

  while [[ ${attempts} -lt 12 ]]; do
    if helm status "${release_name}" --namespace "${namespace}" >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts + 1))
    warn "Helm release ${release_name} not ready yet (attempt ${attempts}/12); waiting 15s..."
    sleep 15
  done

  die "Timed out waiting for Helm release ${release_name} in namespace ${namespace}."
}

recover_stuck_helm_release() {
  local release_name="$1"
  local namespace="$2"
  local release_status
  local attempts=0

  release_status="$(helm status "${release_name}" --namespace "${namespace}" --output json 2>/dev/null | jq -r '.info.status // empty' || true)"
  if [[ "${release_status}" != "pending-upgrade" && "${release_status}" != "pending-install" && "${release_status}" != "pending-rollback" ]]; then
    return 0
  fi

  warn "Helm release ${release_name} is in ${release_status}; clearing the stuck state and retrying."
  helm uninstall "${release_name}" --namespace "${namespace}" --wait=false >/dev/null 2>&1 || true

  while [[ ${attempts} -lt 12 ]]; do
    if ! helm status "${release_name}" --namespace "${namespace}" >/dev/null 2>&1 && \
      ! kubectl get secrets -n "${namespace}" -o name 2>/dev/null | grep -qE "^secret/sh\\.helm\\.release\\.v1\\.${release_name}\\."; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 10
  done

  kubectl delete secret -n "${namespace}" --ignore-not-found \
    $(kubectl get secrets -n "${namespace}" -o name 2>/dev/null | grep -E "^secret/sh\\.helm\\.release\\.v1\\.${release_name}\\." | tr '\n' ' ' || true) >/dev/null 2>&1 || true
}

apply_namespace_pod_security() {
  local namespace="$1"
  local policy_level="${2:-baseline}"

  kubectl label namespace "${namespace}" \
    pod-security.kubernetes.io/enforce="${policy_level}" \
    pod-security.kubernetes.io/audit="${policy_level}" \
    pod-security.kubernetes.io/warn="${policy_level}" \
    --overwrite >/dev/null

  log "Applied Pod Security Admission ${policy_level} labels to namespace ${namespace}."
}

apply_namespace_network_policy() {
  local namespace="$1"

  kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: ${namespace}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress: []
EOF

  kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace-ingress
  namespace: ${namespace}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
EOF

  kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace-and-dns-egress
  namespace: ${namespace}
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector: {}
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
EOF

  log "Applied NetworkPolicy baseline to namespace ${namespace}."
}

remove_namespace_resource_policy() {
  local namespace="$1"

  kubectl delete limitrange default-resource-limits -n "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete resourcequota namespace-quota -n "${namespace}" --ignore-not-found=true >/dev/null 2>&1 || true

  log "Removed resource guardrails from namespace ${namespace}."
}

apply_namespace_resource_policy() {
  local namespace="$1"

  kubectl apply -f - <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: default-resource-limits
  namespace: ${namespace}
spec:
  limits:
    - type: Container
      # Keep namespace defaults compatible with the Anyscale operator's
      # 1 CPU request while still preventing runaway workloads.
      default:
        cpu: "1"
        memory: "1Gi"
      defaultRequest:
        cpu: "500m"
        memory: "512Mi"
      max:
        cpu: "4"
        memory: 8Gi
      min:
        cpu: 50m
        memory: 64Mi
EOF

  kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: namespace-quota
  namespace: ${namespace}
spec:
  hard:
    pods: "50"
    requests.cpu: "16"
    requests.memory: 32Gi
    limits.cpu: "32"
    limits.memory: 64Gi
EOF

  log "Applied resource guardrails to namespace ${namespace}."
}

# Build and deploy the Anyscale Gateway helm release.
# Args: cloud_deployment_id (empty string for phase-a)
gateway_upgrade() {
  local cloud_deployment_id="$1"
  local gateway_values_file
  gateway_values_file="$(mktemp)"

  local deployment_slug="" primary_tls="" service_tls=""
  if [[ -n "${cloud_deployment_id}" ]]; then
    deployment_slug="${cloud_deployment_id//_/-}"
    primary_tls="anyscale-${deployment_slug}-certificate"
    if [[ "${GATEWAY_SERVICE_HTTPS_ENABLED:-false}" == "true" ]]; then
      service_tls="anyscale-svc-${deployment_slug}-certificate"
    fi
  fi

  {
    printf 'gateway:\n'
    printf '  name: "%s"\n' "${GATEWAY_NAME}"
    printf '  className: "%s"\n' "${GATEWAY_CLASS_NAME}"
    [[ -n "${primary_tls}" ]] && printf '  primaryTlsSecretName: "%s"\n' "${primary_tls}"
    [[ -n "${service_tls}" ]] && printf '  serviceTlsSecretName: "%s"\n' "${service_tls}"
    printf '  sessionHostname: "*.i.azure.anyscaleuserdata.com"\n'
    printf '  serviceHostname: "*.s.azure.anyscaleuserdata.com"\n'
    printf '  annotations:\n'
    printf '    service.beta.kubernetes.io/azure-load-balancer-internal: "true"\n'
    printf '    service.beta.kubernetes.io/azure-load-balancer-ipv4: "%s"\n' "${GATEWAY_PRIVATE_IP}"
    printf '    gateway.istio.io/name-override: "%s"\n' "${GATEWAY_SERVICE_NAME}"
    printf '  allowedRoutes:\n'
    printf '    namespaces:\n'
    printf '      from: Same\n'
  } > "${gateway_values_file}"

  log "helm upgrade --install ${GATEWAY_RELEASE_NAME} (cloud_deployment_id=${cloud_deployment_id:-<empty>}) ..."
  helm upgrade --install "${GATEWAY_RELEASE_NAME}" \
    "${ROOT_DIR}/infra/terraform/modules/cluster_bootstrap/charts/anyscale-gateway" \
    --namespace "${OPERATOR_NAMESPACE}" \
    --values "${gateway_values_file}" \
    --wait

  rm -f "${gateway_values_file}"
  log "Gateway helm release ${GATEWAY_RELEASE_NAME} installed/upgraded."
}

###############################################################################
# phase-a: namespaces, ServiceAccount, NVIDIA, Gateway (no TLS)
###############################################################################

phase_a() {
  require_var AKS_CLUSTER_NAME
  require_var AKS_RG
  require_var OPERATOR_NAMESPACE
  require_var OPERATOR_SA_NAME
  require_var WORKLOAD_IDENTITY_CLIENT_ID
  require_var WORKLOAD_IDENTITY_TENANT_ID
  require_var EXTENSION_RELEASE_NAME
  require_var GPU_RESOURCES_NAMESPACE
  require_var NVIDIA_RELEASE_NAME
  require_var NVIDIA_CHART_VERSION
  require_var GATEWAY_RELEASE_NAME
  require_var GATEWAY_NAME
  require_var GATEWAY_CLASS_NAME
  require_var GATEWAY_SERVICE_NAME
  require_var GATEWAY_PRIVATE_IP

  setup_kubeconfig
  wait_for_api_server

  # 1. Operator namespace (idempotent via dry-run/apply)
  log "Applying operator namespace ${OPERATOR_NAMESPACE} ..."
  kubectl create namespace "${OPERATOR_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  # The Anyscale operator deploys an init container that requires capability and
  # privileged settings, so it must use the privileged Pod Security profile.
  # It also needs outbound access to Azure identity and the Anyscale control
  # plane, so do not apply the default NetworkPolicy egress restriction here.
  # The marketplace chart needs a namespace without conflicting ResourceQuota or
  # LimitRange defaults, so remove any stale guardrails and keep the pod specs
  # under the chart's own control.
  apply_namespace_pod_security "${OPERATOR_NAMESPACE}" privileged
  remove_namespace_resource_policy "${OPERATOR_NAMESPACE}"

  # 2. Operator ServiceAccount with exact workload-identity labels + annotations
  log "Applying ServiceAccount ${OPERATOR_SA_NAME} ..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${OPERATOR_SA_NAME}
  namespace: ${OPERATOR_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: "Helm"
    azure.workload.identity/use: "true"
  annotations:
    meta.helm.sh/release-name: "${EXTENSION_RELEASE_NAME}"
    meta.helm.sh/release-namespace: "${OPERATOR_NAMESPACE}"
    azure.workload.identity/client-id: "${WORKLOAD_IDENTITY_CLIENT_ID}"
    azure.workload.identity/tenant-id: "${WORKLOAD_IDENTITY_TENANT_ID}"
EOF

  # 3. GPU resources namespace (idempotent)
  log "Applying GPU resources namespace ${GPU_RESOURCES_NAMESPACE} ..."
  kubectl create namespace "${GPU_RESOURCES_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  apply_namespace_pod_security "${GPU_RESOURCES_NAMESPACE}" privileged
  apply_namespace_network_policy "${GPU_RESOURCES_NAMESPACE}"
  apply_namespace_resource_policy "${GPU_RESOURCES_NAMESPACE}"

  # 4. NVIDIA device plugin. Skipped on a CPU-only deploy: with no GPU node pool
  #    the plugin has nowhere to schedule (its node affinity requires the AKS
  #    accelerator label), so installing it would only add a permanently pending
  #    release. The namespace and its policies are still created above so that
  #    enabling GPU pools later is a plain re-run.
  if [[ "${GPU_POOLS_ENABLED:-true}" != "true" ]]; then
    log "No GPU node pools configured; skipping the NVIDIA device plugin."
    gateway_upgrade ""
    return 0
  fi

  log "Installing NVIDIA device plugin ${NVIDIA_CHART_VERSION} into ${GPU_RESOURCES_NAMESPACE} ..."
  helm repo add nvdp https://nvidia.github.io/k8s-device-plugin --force-update >/dev/null
  helm repo update nvdp >/dev/null

  local nvidia_values_file
  nvidia_values_file="$(mktemp)"
  cat > "${nvidia_values_file}" <<'NVVALS'
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.azure.com/accelerator
              operator: Exists
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  - key: node.anyscale.com/accelerator-type
    operator: Exists
    effect: NoSchedule
  - key: node.anyscale.com/capacity-type
    operator: Exists
    effect: NoSchedule
NVVALS

  if helm status "${NVIDIA_RELEASE_NAME}" --namespace "${GPU_RESOURCES_NAMESPACE}" >/dev/null 2>&1; then
    recover_stuck_helm_release "${NVIDIA_RELEASE_NAME}" "${GPU_RESOURCES_NAMESPACE}"
  fi

  helm upgrade --install "${NVIDIA_RELEASE_NAME}" nvdp/nvidia-device-plugin \
    --version "${NVIDIA_CHART_VERSION}" \
    --namespace "${GPU_RESOURCES_NAMESPACE}" \
    --values "${nvidia_values_file}" \
    --wait --timeout 15m
  rm -f "${nvidia_values_file}"
  wait_for_helm_release "${NVIDIA_RELEASE_NAME}" "${GPU_RESOURCES_NAMESPACE}"
  log "NVIDIA device plugin installed."

  # 5. Anyscale Gateway (phase-a: cloud_deployment_id empty → no TLS listener entries)
  gateway_upgrade ""
}

###############################################################################
# phase-b: re-apply Gateway with TLS secret names from CLOUD_DEPLOYMENT_ID
###############################################################################

phase_b() {
  require_var AKS_CLUSTER_NAME
  require_var AKS_RG
  require_var OPERATOR_NAMESPACE
  require_var GATEWAY_RELEASE_NAME
  require_var GATEWAY_NAME
  require_var GATEWAY_CLASS_NAME
  require_var GATEWAY_SERVICE_NAME
  require_var GATEWAY_PRIVATE_IP
  require_var CLOUD_DEPLOYMENT_ID

  setup_kubeconfig
  # TLS secret names are derived in gateway_upgrade() from CLOUD_DEPLOYMENT_ID:
  #   primaryTlsSecretName = "anyscale-${cloud_deployment_id//_/-}-certificate"
  #   serviceTlsSecretName = "anyscale-svc-${cloud_deployment_id//_/-}-certificate"
  gateway_upgrade "${CLOUD_DEPLOYMENT_ID}"
}

###############################################################################
# Dispatch
###############################################################################

case "${1:-}" in
  phase-a)
    log "Starting phase-a ..."
    phase_a
    log "phase-a complete."
    ;;
  phase-b)
    log "Starting phase-b ..."
    phase_b
    log "phase-b complete."
    ;;
  --help | -h)
    cat <<'USAGE'
Usage: ./scripts/bootstrap-k8s.sh phase-a | phase-b

Idempotent Kubernetes bootstrap run on the Linux jump host.
The orchestrator (scripts/setup.sh invoke_jump_host_bootstrap) syncs this
script to the jump box and invokes it via Bastion-tunnelled SSH.
USAGE
    ;;
  *)
    die "Usage: ./scripts/bootstrap-k8s.sh phase-a | phase-b"
    ;;
esac
