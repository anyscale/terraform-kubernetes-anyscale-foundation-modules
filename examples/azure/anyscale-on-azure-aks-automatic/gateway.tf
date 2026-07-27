###############################################################################
# GATEWAY + IN-CLUSTER BOOTSTRAP.
#
# The Anyscale Azure-managed control plane routes workspace and service traffic
# through an in-cluster Gateway API `Gateway` exposed via an Azure Standard
# load balancer. The Anyscale operator (installed by anyscale.tf) creates the
# TLS Secret resources the HTTPS listeners reference.
#
# WHAT AUTOMATIC REMOVES: the `new-aks` sibling installs the Envoy Gateway Helm
# chart, an `EnvoyProxy` config object, and a `GatewayClass eg`. None of that
# exists here — `web_app_routing_ingress { istio_enabled = true }` on the
# cluster (aks.tf) makes AKS install and manage the Istio Gateway API
# controller and register the `approuting-istio` GatewayClass. Only the
# namespace and the `Gateway` itself are ours to create.
#
# THE HOSTNAME TRICK (kept from upstream awesome-aks and from `new-aks`): the
# gateway's LB service carries a `service.beta.kubernetes.io/azure-dns-label-name`
# annotation derived from the Anyscale cloud resource ID, so its public
# hostname is DETERMINISTIC:
#
#   <cldrsrc-id-hyphenated>.<region>.cloudapp.azure.com
#
# That makes `networking.gateway.hostname` computable before the LB exists — no
# LB polling, no `az k8s-extension update` follow-up. The polling path survives
# only behind var.internal_gateway (internal LBs get a private IP and no public
# DNS label).
#
# WHERE THE ANNOTATIONS GO: with a managed Istio GatewayClass there is no
# `EnvoyProxy` to hang LB annotations on — the controller derives the Service
# from the Gateway, so the annotations ride on `spec.infrastructure.annotations`
# (Gateway API v1.1+). This is upstream's placement.
###############################################################################

locals {
  gateway_public_hostname = "${local.anyscale_cloud_resource_id_hyphenated}.${var.azure_location}.cloudapp.azure.com"

  # What the operator extension registers with the Anyscale control plane.
  gateway_hostname = var.internal_gateway ? data.external.gateway_lb[0].result.address : local.gateway_public_hostname

  # NOTE: the `anyscale-on-azure-private-aks` sibling sets
  # `gateway.istio.io/name-override` here to keep the generated Service name
  # short. Deliberately NOT carried over: on this path the annotation lives on
  # `spec.infrastructure.annotations`, and the managed Istio controller does
  # not honour its own annotations from there — verified on a real deploy,
  # where the Service came up as `gateway-approuting-istio` regardless. The
  # generated name is well inside the 63-char label limit, so the override
  # bought nothing but the false impression that it was doing something.
  # (The `service.beta.kubernetes.io/*` annotations below DO propagate.)
  gateway_infrastructure_annotations = merge(
    {
      "service.beta.kubernetes.io/azure-load-balancer-internal" = var.internal_gateway ? "true" : "false"
    },
    # DNS labels only apply to public LB frontends.
    var.internal_gateway ? {} : {
      "service.beta.kubernetes.io/azure-dns-label-name" = local.anyscale_cloud_resource_id_hyphenated
    },
  )

  ###############################################################################
  # Rendered manifests.
  #
  # These are plain strings in Terraform state, written to disk next to the
  # module (gitignored) so they can be inspected, diffed, and re-applied by hand
  # during triage. The bootstrap below applies them in order.
  ###############################################################################
  namespace_manifest = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = var.anyscale_operator_namespace
      # The Anyscale operator runs an init container that needs elevated
      # capabilities, so the namespace must sit on the privileged Pod Security
      # profile. Baseline/restricted blocks the operator pod at admission.
      labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
      }
    }
  })

  gateway_manifest = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = var.gateway.name
      namespace = var.anyscale_operator_namespace
    }
    spec = {
      gatewayClassName = local.app_routing_gateway_class_name
      infrastructure = {
        annotations = local.gateway_infrastructure_annotations
      }
      listeners = [
        {
          name     = "http"
          port     = 80
          protocol = "HTTP"
          allowedRoutes = {
            namespaces = { from = "Same" }
          }
        },
        {
          name     = "https"
          port     = 443
          protocol = "HTTPS"
          hostname = "*.i.azure.anyscaleuserdata.com"
          tls = {
            mode = "Terminate"
            certificateRefs = [{
              kind = "Secret"
              name = local.anyscale_gateway_certificate_secret_name
            }]
          }
          allowedRoutes = {
            namespaces = { from = "Same" }
          }
        },
        {
          name     = "https-session"
          port     = 443
          protocol = "HTTPS"
          hostname = "*.s.azure.anyscaleuserdata.com"
          tls = {
            mode = "Terminate"
            certificateRefs = [{
              kind = "Secret"
              name = local.anyscale_gateway_service_certificate_secret_name
            }]
          }
          allowedRoutes = {
            namespaces = { from = "Same" }
          }
        },
      ]
    }
  })

  kubeconfig_path = "${path.module}/.kubeconfig"
}

resource "local_file" "namespace_manifest" {
  filename        = "${path.module}/anyscale-namespace.yaml"
  file_permission = "0600"
  content         = local.namespace_manifest
}

resource "local_file" "gateway_manifest" {
  filename        = "${path.module}/anyscale-gateway.yaml"
  file_permission = "0600"
  content         = local.gateway_manifest
}

###############################################################################
# THE BOOTSTRAP — one local-exec, three kubectl applies.
#
# `new-aks` does this with the kubernetes/kubectl/helm providers authenticated
# from the cluster's admin client certificate. AKS Automatic issues no such
# certificate: local accounts are disabled, Entra RBAC is enforced. So:
#
#   az aks get-credentials --file ./.kubeconfig     # Entra-flavoured kubeconfig
#   kubelogin convert-kubeconfig -l azurecli        # swap the exec plugin for
#                                                   # the az CLI token provider
#   kubectl apply …                                 # namespace → gateway → GPU
#
# ISOLATED KUBECONFIG: `--file ./.kubeconfig` (gitignored) instead of
# ~/.kube/config. Nothing this stack does can disturb the operator's other
# cluster contexts, and no stale context can be picked up here.
#
# `-l azurecli` reuses the `az login` Terraform already depends on — no device
# code prompt mid-apply, which `-l devicelogin` would produce.
#
# The retry loop absorbs Entra role-assignment propagation (a fresh
# "RBAC Cluster Admin" grant can take a minute or two to be honoured by the
# API server) and the app-routing addon still reconciling its GatewayClass.
#
# `triggers_replace` keys on the rendered manifest CONTENT, so editing a
# listener or an annotation re-applies. kubectl apply is idempotent.
###############################################################################
resource "terraform_data" "cluster_bootstrap" {
  triggers_replace = {
    cluster_id         = azurerm_kubernetes_automatic_cluster.aks.id
    namespace_manifest = local.namespace_manifest
    gateway_manifest   = local.gateway_manifest
    gpu_manifest       = local.gpu_nodepool_manifest
  }

  input = {
    subscription   = var.azure_subscription_id
    resource_group = azurerm_resource_group.rg.name
    cluster_name   = azurerm_kubernetes_automatic_cluster.aks.name
    kubeconfig     = local.kubeconfig_path
    namespace_file = local_file.namespace_manifest.filename
    gateway_file   = local_file.gateway_manifest.filename
    gpu_file       = length(var.gpu_nodepool_configs) > 0 ? local_file.gpu_nodepool_manifest[0].filename : ""
    namespace      = var.anyscale_operator_namespace
    gateway_class  = local.app_routing_gateway_class_name
    api_timeout    = var.gateway.api_ready_timeout_seconds
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      for bin in az kubectl kubelogin; do
        command -v "$bin" >/dev/null 2>&1 || {
          echo "[bootstrap] ERROR: '$bin' not found on PATH." >&2
          echo "[bootstrap] Install kubectl and kubelogin with: az aks install-cli" >&2
          exit 1
        }
      done

      az account set --subscription "${self.input.subscription}"

      export KUBECONFIG="${self.input.kubeconfig}"
      echo "[bootstrap] fetching an isolated kubeconfig (not ~/.kube/config)"
      az aks get-credentials \
        --resource-group "${self.input.resource_group}" \
        --name "${self.input.cluster_name}" \
        --file "${self.input.kubeconfig}" \
        --overwrite-existing \
        --only-show-errors

      # AKS Automatic hands back an Entra kubeconfig whose default exec plugin
      # is the deprecated azure auth provider. Convert it to kubelogin's
      # azurecli mode so it reuses the token `az` already holds.
      kubelogin convert-kubeconfig -l azurecli --kubeconfig "${self.input.kubeconfig}"

      # Wait for the Gateway API surface to actually exist before applying a
      # Gateway. The ingressProfile PATCH returns once ARM accepts it, but the
      # CRDs and the GatewayClass land in the cluster minutes later. Blind
      # retries are the wrong tool here — they cannot distinguish "still
      # reconciling" from "gatewayAPI.installation was never set", which is a
      # config error that no amount of retrying fixes.
      wait_for() {
        local label="$1" deadline
        shift
        deadline=$(( $(date +%s) + ${self.input.api_timeout} ))
        until "$@" >/dev/null 2>&1; do
          if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "[bootstrap] ERROR: timed out after ${self.input.api_timeout}s waiting for $label." >&2
            echo "[bootstrap] Check that the ingress profile actually carries the" >&2
            echo "[bootstrap] Gateway API installation:" >&2
            echo "[bootstrap]   az aks show -g ${self.input.resource_group} -n ${self.input.cluster_name} \\" >&2
            echo "[bootstrap]     --query ingressProfile.gatewayApi" >&2
            echo "[bootstrap] If that is null, the ManagedGatewayAPIPreview /" >&2
            echo "[bootstrap] AppRoutingIstioGatewayAPIPreview features are not" >&2
            echo "[bootstrap] registered on this subscription — see the README." >&2
            return 1
          fi
          echo "[bootstrap] waiting for $label..."
          sleep 20
        done
        echo "[bootstrap] $label ready."
      }

      apply_with_retry() {
        local label="$1" file="$2"
        [ -n "$file" ] || return 0
        for attempt in 1 2 3 4 5 6; do
          if kubectl apply -f "$file"; then
            echo "[bootstrap] $label applied."
            return 0
          fi
          if [ "$attempt" -eq 6 ]; then
            echo "[bootstrap] ERROR: applying $label failed after $attempt attempts." >&2
            echo "[bootstrap] 'Forbidden' here usually means the Entra RBAC role" >&2
            echo "[bootstrap] assignment has not propagated yet — re-run apply." >&2
            return 1
          fi
          echo "[bootstrap] $label attempt $attempt failed; retrying in 30s..."
          sleep 30
        done
      }

      apply_with_retry "namespace" "${self.input.namespace_file}"

      wait_for "Gateway API CRDs" \
        kubectl get crd gateways.gateway.networking.k8s.io
      kubectl wait --for=condition=Established \
        --timeout=${self.input.api_timeout}s \
        crd/gateways.gateway.networking.k8s.io
      wait_for "GatewayClass ${self.input.gateway_class}" \
        kubectl get gatewayclass "${self.input.gateway_class}"

      apply_with_retry "gateway" "${self.input.gateway_file}"

      if [ -n "${self.input.gpu_file}" ]; then
        wait_for "Karpenter NodePool CRDs" kubectl get crd nodepools.karpenter.sh
        wait_for "AKSNodeClass CRDs"       kubectl get crd aksnodeclasses.karpenter.azure.com
        apply_with_retry "gpu nodepools" "${self.input.gpu_file}"
      fi
    EOT
  }

  depends_on = [
    azurerm_kubernetes_automatic_cluster.aks,
    # THE LOAD-BEARING ONE: the Gateway API CRDs and the `approuting-istio`
    # GatewayClass only exist once this patch has reconciled. Without this
    # edge Terraform runs the two concurrently and the Gateway apply fails
    # with `no matches for kind "Gateway"`.
    azapi_update_resource.app_routing,
    # kubectl is unauthorized without the RBAC grants.
    azurerm_role_assignment.current_principal_cluster_admin,
    azurerm_role_assignment.current_principal_cluster_user,
    # The Gateway's DNS label is derived from the cloud resource ID.
    azapi_resource.anyscale_cloud_resource,
    # Applying into the operator namespace before the exclusion lands risks
    # the safeguards webhook rejecting it.
    azapi_update_resource.deployment_safeguards,
  ]
}

###############################################################################
# INTERNAL-GATEWAY FALLBACK PATH (var.internal_gateway = true only).
#
# Internal LBs get a private IP from the node subnet and no public DNS label,
# so the address must be read back from the Gateway status once the managed
# Istio controller programs it. On the default public path neither of the
# resources below is created.
###############################################################################
resource "terraform_data" "wait_for_gateway_lb" {
  count = var.internal_gateway ? 1 : 0

  input = {
    namespace       = var.anyscale_operator_namespace
    gateway_name    = var.gateway.name
    timeout_seconds = var.gateway.lb_wait_timeout_seconds
    poll_interval   = var.gateway.lb_poll_interval_seconds
    kubeconfig      = local.kubeconfig_path
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="${self.input.kubeconfig}"
      deadline=$(( $(date +%s) + ${self.input.timeout_seconds} ))
      while :; do
        addr="$(kubectl get gateway ${self.input.gateway_name} -n ${self.input.namespace} \
          -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
        if [ -n "$addr" ]; then
          echo "[gateway] LB address: $addr"
          exit 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "[gateway] ERROR: timed out waiting for LB address after ${self.input.timeout_seconds}s" >&2
          kubectl describe gateway ${self.input.gateway_name} -n ${self.input.namespace} >&2 || true
          exit 1
        fi
        sleep ${self.input.poll_interval}
      done
    EOT
  }

  depends_on = [terraform_data.cluster_bootstrap]
}

# Read the Gateway LB address back into Terraform state so the Anyscale
# operator extension can consume it as a configuration_settings value.
data "external" "gateway_lb" {
  count = var.internal_gateway ? 1 : 0

  program = [
    "bash",
    "-c",
    "value=\"$(KUBECONFIG=${local.kubeconfig_path} kubectl get gateway ${var.gateway.name} -n ${var.anyscale_operator_namespace} -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)\"; printf '{\"address\":\"%s\"}' \"$value\"",
  ]

  depends_on = [terraform_data.wait_for_gateway_lb]
}
