###############################################################################
# Envoy Gateway bootstrap.
#
# The Anyscale Azure-managed control plane routes workspace and service
# traffic through an in-cluster Envoy Gateway exposed via an Azure Standard
# LoadBalancer. The Anyscale operator (installed by anyscale.tf) creates the
# TLS Secret resources the Gateway listeners reference; the Gateway in turn
# tells the operator extension which LB hostname to register with the
# control plane (see `networking.gateway.hostname` in anyscale.tf).
#
# The kubernetes/helm/kubectl providers authenticate via the AKS cluster's
# admin cert attributes (versions.tf), so every in-cluster resource implicitly
# waits for the cluster and nothing reads a kubeconfig file at plan time. This
# makes the whole thing a true single `terraform apply`:
#
#   aks ─► helm envoy-gateway ─► EnvoyProxy ─► GatewayClass
#                                                  │
#   azapi anyscale_platform (publishes cloud_resource_id) ─┤
#                                                  ▼
#                                              Gateway (references future TLS secret names)
#                                                  │
#                                                  ▼
#                                       wait_for_gateway_lb (kubectl poll, uses the
#                                       isolated .kubeconfig from aks_credentials)
#                                                  │
#                                                  ▼
#                                       data.external.gateway_lb
#                                                  │
#                                                  ▼
#                                       azurerm_kubernetes_cluster_extension
#                                       .anyscale_operator (installs operator → operator
#                                       creates TLS secrets → listeners reconcile)
###############################################################################

###############################################################################
# Write an ISOLATED kubeconfig for the gateway-LB shell calls only.
#
# The kubernetes / helm / kubectl PROVIDERS no longer use a kubeconfig file at
# all — they authenticate via the AKS admin cert attributes directly (see
# versions.tf), which sidesteps the stale-context problem entirely. But the two
# LB-address steps below (wait_for_gateway_lb, data.external.gateway_lb) shell
# out to `kubectl`, which needs a kubeconfig. We write a dedicated one to
# ${path.module}/.kubeconfig (NOT ~/.kube/config) so it only ever contains this
# cluster's context — freshly written each apply, no other contexts to go
# stale. `.kubeconfig` is gitignored.
###############################################################################
resource "terraform_data" "aks_credentials" {
  triggers_replace = {
    cluster_id = local.aks_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      az aks get-credentials \
        --resource-group "${local.rg_name}" \
        --name "${local.aks_name}" \
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

###############################################################################
# Envoy Gateway Helm release (v1.7.0 from docker.io OCI registry).
###############################################################################
moved {
  from = helm_release.envoy_gateway
  to   = helm_release.envoy_gateway[0]
}

resource "helm_release" "envoy_gateway" {
  count = var.create_envoy_gateway ? 1 : 0

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
# EnvoyProxy — wires the GatewayClass to an external Azure Standard LB.
# `azure-load-balancer-internal: "false"` forces a public LB; flip to "true"
# if you want the Anyscale data plane reachable only from the VNet.
###############################################################################
moved {
  from = kubectl_manifest.envoy_proxy
  to   = kubectl_manifest.envoy_proxy[0]
}

resource "kubectl_manifest" "envoy_proxy" {
  count = var.create_envoy_gateway ? 1 : 0

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
            annotations = {
              "service.beta.kubernetes.io/azure-load-balancer-internal" = "false"
            }
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
moved {
  from = kubectl_manifest.gateway_class
  to   = kubectl_manifest.gateway_class[0]
}

resource "kubectl_manifest" "gateway_class" {
  count = var.create_envoy_gateway ? 1 : 0

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
moved {
  from = kubernetes_namespace_v1.anyscale_operator
  to   = kubernetes_namespace_v1.anyscale_operator[0]
}

resource "kubernetes_namespace_v1" "anyscale_operator" {
  count = var.create_operator_namespace ? 1 : 0

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
# is still allocated as soon as the Gateway resource exists, which is the
# value we hand back to the operator extension via
# `networking.gateway.hostname`.
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
    azapi_resource.anyscale_platform,
  ]
}

###############################################################################
# Poll the Gateway until its `status.addresses[0].value` is populated by the
# Envoy Gateway controller. Times out after gateway_lb_wait_timeout_seconds.
###############################################################################
resource "terraform_data" "wait_for_gateway_lb" {
  input = {
    namespace        = var.anyscale_operator_namespace
    gateway_name     = var.envoy_gateway.gateway_name
    timeout_seconds  = var.envoy_gateway.gateway_lb_wait_timeout_seconds
    poll_interval    = var.envoy_gateway.gateway_lb_poll_interval_seconds
    kubeconfig       = "${path.module}/.kubeconfig"
    gateway_manifest = kubectl_manifest.gateway.id
    gateway_class    = var.envoy_gateway.gateway_class_name
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

          # The usual cause when reusing an Envoy Gateway install
          # (create_envoy_gateway=false) is a GatewayClass whose EnvoyProxy
          # publishes the data plane as something other than a LoadBalancer, so
          # status.addresses never gets populated. Surface enough to see that.
          echo "--- GatewayClass ${self.input.gateway_class} ---" >&2
          kubectl describe gatewayclass ${self.input.gateway_class} >&2 || true
          ref="$(kubectl get gatewayclass ${self.input.gateway_class}             -o jsonpath='{.spec.parametersRef.namespace}/{.spec.parametersRef.name}' 2>/dev/null || true)"
          if [ -n "$ref" ] && [ "$ref" != "/" ]; then
            echo "--- EnvoyProxy $ref (envoyService.type must be LoadBalancer) ---" >&2
            kubectl get envoyproxy "$${ref#*/}" -n "$${ref%/*}"               -o jsonpath='{.spec.provider.kubernetes.envoyService.type}{"\n"}' >&2 || true
          else
            echo "GatewayClass ${self.input.gateway_class} has no parametersRef -> no EnvoyProxy pinning the service type." >&2
          fi
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

###############################################################################
# Read the Gateway LB address back into Terraform state so the Anyscale
# operator extension can consume it as a configuration_settings value.
# Using the external data source plus the same kubectl/jsonpath the wait
# loop ran keeps this resilient across kubernetes-provider versions.
###############################################################################
data "external" "gateway_lb" {
  program = [
    "bash",
    "-c",
    "value=\"$(KUBECONFIG=${path.module}/.kubeconfig kubectl get gateway ${var.envoy_gateway.gateway_name} -n ${var.anyscale_operator_namespace} -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)\"; printf '{\"address\":\"%s\"}' \"$value\"",
  ]

  depends_on = [terraform_data.wait_for_gateway_lb]
}
