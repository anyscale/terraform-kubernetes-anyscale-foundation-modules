###############################################################################
# Envoy Gateway bootstrap.
#
# The Anyscale Azure-managed control plane routes workspace and service
# traffic through an in-cluster Envoy Gateway exposed via an Azure Standard
# LoadBalancer. The Anyscale operator (installed by anyscale.tf) creates the
# TLS Secret resources the Gateway listeners reference.
#
# THE HOSTNAME TRICK (grafted from the awesome-aks demo): the gateway's LB
# service carries a `service.beta.kubernetes.io/azure-dns-label-name`
# annotation derived from the Anyscale cloud resource ID, so its public
# hostname is DETERMINISTIC:
#
#   <cldrsrc-id-hyphenated>.<region>.cloudapp.azure.com
#
# That makes `networking.gateway.hostname` computable before the LB exists —
# no LB polling, no isolated kubeconfig, no `az k8s-extension update`
# follow-up. The polling path survives only behind var.internal_gateway
# (internal LBs get a private IP and no public DNS label).
###############################################################################

locals {
  gateway_public_hostname = "${local.anyscale_cloud_resource_id_hyphenated}.${var.azure_location}.cloudapp.azure.com"

  # What the operator extension registers with the Anyscale control plane.
  gateway_hostname = var.internal_gateway ? data.external.gateway_lb[0].result.address : local.gateway_public_hostname
}

###############################################################################
# Envoy Gateway Helm release (from docker.io OCI registry).
###############################################################################
resource "helm_release" "envoy_gateway" {
  name             = var.envoy_gateway.release_name
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = var.envoy_gateway.chart_version
  namespace        = var.envoy_gateway.namespace
  create_namespace = true
  wait             = true
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 600

  # The helm provider authenticates via the AKS cluster's kube_config
  # attributes, so this release implicitly depends on the cluster existing —
  # no kubeconfig-file dependency needed.
}

###############################################################################
# EnvoyProxy — wires the GatewayClass to an Azure Standard LB.
# Public by default with the deterministic DNS label; internal (VNet-only)
# when var.internal_gateway = true.
###############################################################################
resource "kubectl_manifest" "envoy_proxy" {
  yaml_body = yamlencode({
    apiVersion = "gateway.envoyproxy.io/v1alpha1"
    kind       = "EnvoyProxy"
    metadata = {
      name      = "envoy-proxy"
      namespace = var.envoy_gateway.namespace
    }
    spec = {
      provider = {
        type = "Kubernetes"
        kubernetes = {
          envoyService = {
            type = "LoadBalancer"
            annotations = merge(
              {
                "service.beta.kubernetes.io/azure-load-balancer-internal" = var.internal_gateway ? "true" : "false"
              },
              # DNS labels only apply to public LB frontends.
              var.internal_gateway ? {} : {
                "service.beta.kubernetes.io/azure-dns-label-name" = local.anyscale_cloud_resource_id_hyphenated
              },
            )
          }
        }
      }
    }
  })

  depends_on = [helm_release.envoy_gateway]
}

###############################################################################
# GatewayClass — named `eg` to match the Anyscale quickstart.
###############################################################################
resource "kubectl_manifest" "gateway_class" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name = var.envoy_gateway.gateway_class_name
    }
    spec = {
      controllerName = "gateway.envoyproxy.io/gatewayclass-controller"
      parametersRef = {
        group     = "gateway.envoyproxy.io"
        kind      = "EnvoyProxy"
        name      = "envoy-proxy"
        namespace = var.envoy_gateway.namespace
      }
    }
  })

  depends_on = [kubectl_manifest.envoy_proxy]
}

###############################################################################
# Operator namespace (the Gateway lives here, alongside the operator the
# AKS extension is about to install).
###############################################################################
resource "kubernetes_namespace_v1" "anyscale_operator" {
  metadata {
    name = var.anyscale_operator_namespace
  }
  # Implicitly ordered after the cluster via the kubernetes provider's
  # kube_config-based auth.
}

###############################################################################
# Gateway — three listeners (HTTP, HTTPS workspace, HTTPS service).
# The TLS Secrets the HTTPS listeners reference are created by the Anyscale
# operator AFTER azurerm_kubernetes_cluster_extension.anyscale_operator is
# installed. Listeners will be Programmed=False until then; the Standard LB
# (with its deterministic DNS label) is still allocated as soon as the
# Gateway resource exists.
###############################################################################
resource "kubectl_manifest" "gateway" {
  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = var.envoy_gateway.gateway_name
      namespace = var.anyscale_operator_namespace
    }
    spec = {
      gatewayClassName = var.envoy_gateway.gateway_class_name
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

  depends_on = [
    kubectl_manifest.gateway_class,
    kubernetes_namespace_v1.anyscale_operator,
    azapi_resource.anyscale_cloud_resource,
  ]
}

###############################################################################
# INTERNAL-GATEWAY FALLBACK PATH (var.internal_gateway = true only).
#
# Internal LBs get a private IP from the node subnet and no public DNS label,
# so the address must be read back from the Gateway status once the Envoy
# Gateway controller programs it — the reference example's polling approach.
# On the default public path none of the resources below are created.
###############################################################################

# Isolated kubeconfig for the LB polling shell steps only (NOT ~/.kube/config,
# so no other contexts can go stale). Gitignored.
resource "terraform_data" "aks_credentials" {
  count = var.internal_gateway ? 1 : 0

  triggers_replace = {
    cluster_id = azurerm_kubernetes_cluster.aks.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      az aks get-credentials \
        --resource-group "${azurerm_resource_group.rg.name}" \
        --name "${azurerm_kubernetes_cluster.aks.name}" \
        --file "${path.module}/.kubeconfig" \
        --overwrite-existing \
        --only-show-errors
    EOT
  }

  depends_on = [
    azurerm_kubernetes_cluster.aks,
    azurerm_kubernetes_cluster_node_pool.ondemand_cpu,
  ]
}

# Poll the Gateway until its `status.addresses[0].value` is populated by the
# Envoy Gateway controller. Times out after gateway_lb_wait_timeout_seconds.
resource "terraform_data" "wait_for_gateway_lb" {
  count = var.internal_gateway ? 1 : 0

  input = {
    namespace        = var.anyscale_operator_namespace
    gateway_name     = var.envoy_gateway.gateway_name
    timeout_seconds  = var.envoy_gateway.gateway_lb_wait_timeout_seconds
    poll_interval    = var.envoy_gateway.gateway_lb_poll_interval_seconds
    kubeconfig       = "${path.module}/.kubeconfig"
    gateway_manifest = kubectl_manifest.gateway.id
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
          echo "Gateway LB address: $addr"
          exit 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "Timed out waiting for Gateway LB address after ${self.input.timeout_seconds}s" >&2
          kubectl describe gateway ${self.input.gateway_name} -n ${self.input.namespace} >&2 || true
          exit 1
        fi
        sleep ${self.input.poll_interval}
      done
    EOT
  }

  depends_on = [
    kubectl_manifest.gateway,
    terraform_data.aks_credentials,
  ]
}

# Read the Gateway LB address back into Terraform state so the Anyscale
# operator extension can consume it as a configuration_settings value.
data "external" "gateway_lb" {
  count = var.internal_gateway ? 1 : 0

  program = [
    "bash",
    "-c",
    "value=\"$(KUBECONFIG=${path.module}/.kubeconfig kubectl get gateway ${var.envoy_gateway.gateway_name} -n ${var.anyscale_operator_namespace} -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)\"; printf '{\"address\":\"%s\"}' \"$value\"",
  ]

  depends_on = [terraform_data.wait_for_gateway_lb]
}
