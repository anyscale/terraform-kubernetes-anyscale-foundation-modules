###############################################################################
# AKS AUTOMATIC CLUSTER
#
# `azurerm_kubernetes_automatic_cluster` (azurerm >= 4.81.0) is a deliberately
# small resource, because AKS Automatic decides most of what the `new-aks`
# sibling configures by hand:
#
#   * Azure CNI overlay + Cilium dataplane and network policy — always on.
#   * Node Auto Provisioning (managed Karpenter) — always on. There is no
#     `default_node_pool` block and no `azurerm_kubernetes_cluster_node_pool`
#     anywhere in this stack; workload capacity comes from the built-in
#     `default` Karpenter NodePool, and GPU capacity from the NodePool CRs
#     rendered by gpu.tf.
#   * A managed system node pool, auto-upgrade channels, and node OS patching.
#   * Entra ID authentication with Kubernetes RBAC, local accounts DISABLED.
#   * Azure Policy with deployment safeguards in **Enforcement** — see the
#     exclusion patch further down, which the Anyscale operator depends on.
#   * Standard SKU tier (this is not a Free-tier cluster).
#
# What is left to declare: where it lives on the network, who it runs as, and
# that we want the app-routing Istio Gateway API implementation.
###############################################################################

locals {
  # Shared by the azapi patches and the kubelet-identity read below.
  # Bump together.
  aks_preview_api_version = "2026-03-02-preview"

  # AKS Automatic ships the app-routing Istio Gateway API implementation; the
  # GatewayClass it registers is named `approuting-istio`. This replaces the
  # Envoy Gateway Helm release + custom `GatewayClass eg` from `new-aks`.
  app_routing_gateway_class_name = "approuting-istio"
}

#trivy:ignore:avd-azu-0040
#trivy:ignore:avd-azu-0041
#trivy:ignore:avd-azu-0042
resource "azurerm_kubernetes_automatic_cluster" "aks" {

  #checkov:skip=CKV_AZURE_115: "Ensure that AKS enables private clusters"
  #checkov:skip=CKV_AZURE_117: "Ensure that AKS uses disk encryption set"
  #checkov:skip=CKV_AZURE_6: "Ensure AKS has an API Server Authorized IP Ranges enabled"

  name                = var.aks_cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # BYO VNet ("hosted system"). Both subnets are required together — the
  # managed system pool and the Karpenter-provisioned user nodes are separated
  # so a workload node cannot exhaust the address space CoreDNS and the
  # Karpenter controller need.
  hosted_system {
    node_subnet_id        = azurerm_subnet.nodes.id
    system_node_subnet_id = azurerm_subnet.system_nodes.id
  }

  # API Server VNet Integration. The control plane's inbound NICs are injected
  # into the delegated subnet from main.tf. The API server is still reachable
  # over its public FQDN unless var.api_server_authorized_ip_ranges narrows it
  # (or private_cluster is enabled below).
  api_server_access {
    subnet_id            = azurerm_subnet.apiserver.id
    authorized_ip_ranges = length(var.api_server_authorized_ip_ranges) > 0 ? var.api_server_authorized_ip_ranges : null
  }

  # UserAssigned is mandatory for BYO VNet — see the identity comment in
  # main.tf for why SystemAssigned cannot work here.
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # NO `private_cluster` BLOCK, DELIBERATELY.
  #
  # The typed resource supports one, but this example cannot: the bootstrap in
  # gateway.tf reaches the cluster over the DATA plane (`kubectl apply` against
  # the API server). Against a private API server that has no route from wherever
  # Terraform runs, the first apply hangs and you end up with a cluster that has
  # no namespace, no Gateway, and no operator — a half-built deployment whose
  # failure mode looks like a network timeout.
  #
  # Making it work needs the bootstrap to switch to `az aks command invoke`
  # (kubectl in an AKS-scheduled pod, streamed through ARM — a control-plane
  # call that works against a private API server from anywhere `az` works),
  # plus private DNS and egress handling.
  #
  # That is exactly what `anyscale-on-azure-private-aks` already does. Use that
  # example for private deployments rather than bolting a flag on here.
  #
  # For a middle ground, `api_server_authorized_ip_ranges` narrows the public
  # API server to known egress IPs without breaking the bootstrap.

  # The ingress story. `istio_enabled` registers the `approuting-istio`
  # GatewayClass and its managed controller — the whole reason gateway.tf has
  # no Helm release and no GatewayClass of its own.
  #
  # App routing has two independent halves: that Istio GatewayClass (wanted)
  # and a default nginx ingress controller (not wanted — it would stand up a
  # second PUBLIC load balancer, billed and exposed for nothing). The typed
  # schema only accepts AnnotationControlled / Internal / External for
  # `default_nginx_controller`, so switching it off entirely happens in the
  # azapi patch below.
  web_app_routing_ingress {
    istio_enabled = true
  }

  tags = var.tags

  timeouts {
    create = "1h"
    update = "1h"
    delete = "1h"
  }

  # The cluster cannot join the BYO subnets until its identity can write to
  # them. Without this the create fails partway through with a subnet
  # authorization error.
  depends_on = [
    azurerm_role_assignment.aks_network_contributor,
  ]
}

###############################################################################
# KUBELET IDENTITY — read back via azapi.
#
# The typed resource exports `identity`, `kube_config`, `oidc_issuer_url`,
# `node_resource_group_id` and the FQDNs — but NOT `kubelet_identity`, which
# `acr.tf` needs for the AcrPull assignment. Read it straight off the ARM
# representation of the cluster instead.
###############################################################################
data "azapi_resource" "aks" {
  type        = "Microsoft.ContainerService/managedClusters@${local.aks_preview_api_version}"
  resource_id = azurerm_kubernetes_automatic_cluster.aks.id

  response_export_values = ["properties.identityProfile"]
}

locals {
  aks_kubelet_object_id = try(
    data.azapi_resource.aks.output.properties.identityProfile.kubeletidentity.objectId,
    null,
  )
}

###############################################################################
# CLUSTER ADMIN ACCESS (Entra RBAC).
#
# AKS Automatic disables local accounts and enforces Entra RBAC, so a
# kubeconfig on its own authenticates nothing — the caller also needs an AKS
# RBAC role. The gateway bootstrap in gateway.tf runs `kubectl` as the
# signed-in principal, so without these two assignments its very first
# `kubectl apply` fails with a 403 that reads like a networking problem.
#
#   * RBAC Cluster Admin — authorizes the Kubernetes API calls themselves.
#   * Cluster User Role  — authorizes `az aks get-credentials` (ARM action
#                          Microsoft.ContainerService/managedClusters/
#                          listClusterUserCredential/action).
#
# Role assignments take a little while to propagate; the bootstrap retries.
###############################################################################
resource "azurerm_role_assignment" "current_principal_cluster_admin" {
  count = var.assign_current_principal_cluster_access ? 1 : 0

  scope                = azurerm_kubernetes_automatic_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "current_principal_cluster_user" {
  count = var.assign_current_principal_cluster_access ? 1 : 0

  scope                = azurerm_kubernetes_automatic_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Additional principals (a platform team group, a CI service principal) that
# should be able to reach the cluster directly.
resource "azurerm_role_assignment" "cluster_admin" {
  for_each = var.aks_cluster_admin_principal_ids

  scope                = azurerm_kubernetes_automatic_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}

###############################################################################
# PATCH 0 — INGRESS PROFILE: INSTALL GATEWAY API, TURN OFF DEFAULT NGINX.
#
# THIS PATCH IS WHAT MAKES THE GATEWAY WORK. Two independent fields, and the
# typed resource can express neither:
#
#   gatewayAPI.installation = "Standard"
#     Installs the Gateway API CRDs (gateways/httproutes/gatewayclasses).
#     `web_app_routing_ingress { istio_enabled = true }` does NOT do this — it
#     only sets webAppRouting.gatewayApiImplementations.appRoutingIstio, which
#     configures the Istio *implementation* while leaving `ingressProfile.gatewayAPI`
#     null and the cluster with zero Gateway CRDs. Applying a `Gateway` then
#     fails with:
#       no matches for kind "Gateway" in version "gateway.networking.k8s.io/v1"
#     which reads like the addon is still reconciling, but never resolves.
#
#   webAppRouting.nginx.defaultIngressControllerType = "None"
#     The typed schema only accepts AnnotationControlled / Internal / External,
#     and its default (AnnotationControlled) makes AKS create an
#     NginxIngressController whose Service is a PUBLIC load balancer. This
#     example routes everything through the Istio Gateway, so that controller
#     is pure cost and exposure. The controller is created during cluster
#     creation and removed by this patch — a few minutes of an unused public IP
#     on first apply.
#
# Both fields are preview surface and need feature flags on the subscription
# (see the README prerequisites):
#   az feature register --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview
#   az feature register --namespace Microsoft.ContainerService --name AppRoutingIstioGatewayAPIPreview
#   az provider register --namespace Microsoft.ContainerService
#
# This reconcile is SLOW — 10+ minutes is normal. Everything in-cluster
# depends on it, which is why terraform_data.cluster_bootstrap depends_on it
# rather than racing it.
###############################################################################
resource "azapi_update_resource" "app_routing" {
  type        = "Microsoft.ContainerService/managedClusters@${local.aks_preview_api_version}"
  resource_id = azurerm_kubernetes_automatic_cluster.aks.id

  body = {
    properties = {
      ingressProfile = {
        gatewayAPI = {
          installation = "Standard"
        }
        webAppRouting = {
          enabled = true
          gatewayAPIImplementations = {
            appRoutingIstio = {
              mode = "Enabled"
            }
          }
          nginx = {
            defaultIngressControllerType = var.enable_default_nginx_ingress_controller ? "AnnotationControlled" : "None"
          }
        }
      }
    }
  }

  timeouts {
    create = "45m"
    update = "45m"
  }
}

###############################################################################
# PATCH 1 — MONITORING PROFILE.
#
# `azurerm_kubernetes_cluster` has typed `oms_agent` and `monitor_metrics`
# blocks; `azurerm_kubernetes_automatic_cluster` has neither. The same
# configuration goes on as an ARM PATCH, which is exactly what the typed blocks
# would have produced:
#
#   addonProfiles.omsagent           → Container Insights → Log Analytics
#   azureMonitorProfile.metrics      → managed Prometheus (DCE/DCR in
#                                      prometheus.tf routes it onward)
#   azureMonitorProfile.appMonitoring→ OTLP auto-instrumentation (preview)
#
# MUST BE SERIALIZED AGAINST PATCH 0. Both patches target the SAME
# managedClusters resource, and ARM does not allow two concurrent writes to a
# cluster — Terraform runs them in parallel by default and the loser gets:
#
#   RESPONSE 409: EtagMismatch
#   "Operation is not allowed: Another operation is in progress."
#
# There is no dependency between the two bodies, so nothing in the graph forces
# an order; the depends_on below exists purely to serialize the ARM writes.
# Any future patch against the cluster must join this chain.
###############################################################################
resource "azapi_update_resource" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  type        = "Microsoft.ContainerService/managedClusters@${local.aks_preview_api_version}"
  resource_id = azurerm_kubernetes_automatic_cluster.aks.id

  depends_on = [azapi_update_resource.app_routing]

  timeouts {
    create = "45m"
    update = "45m"
  }

  body = {
    properties = {
      addonProfiles = {
        omsagent = {
          enabled = true
          config = {
            logAnalyticsWorkspaceResourceID = azurerm_log_analytics_workspace.logs[0].id
            useAADAuth                      = "true"
          }
        }
      }
      azureMonitorProfile = merge(
        {
          metrics = {
            enabled = true
            kubeStateMetrics = {
              metricAnnotationsAllowList = ""
              metricLabelsAllowlist      = ""
            }
          }
          containerInsights = {
            enabled                         = true
            logAnalyticsWorkspaceResourceId = azurerm_log_analytics_workspace.logs[0].id
          }
        },
        # OTLP auto-instrumentation points the cluster at the App Insights
        # component created in monitoring.tf.
        var.enable_otlp_app_insights ? {
          appMonitoring = {
            autoInstrumentation  = { enabled = true }
            openTelemetryMetrics = { enabled = true }
            openTelemetryLogs    = { enabled = true }
          }
        } : {},
      )
    }
  }
}

###############################################################################
# PATCH 2 — DEPLOYMENT SAFEGUARDS EXCLUSION.  ← DO NOT SKIP THIS.
#
# AKS Automatic turns on Azure Policy with deployment safeguards in
# **Enforcement** level. Among other things that mutates/denies workloads that
# do not set resource limits, run as non-root, or use `latest` tags.
#
# The Anyscale operator does not satisfy those constraints: it runs an init
# container with elevated capabilities, and the Ray pods it creates are shaped
# by the Anyscale control plane, not by this Terraform. Left in Enforcement
# over the Anyscale namespaces, admission rejects the operator's pods and the
# cloud never becomes usable — the failure surfaces as an operator deployment
# stuck at 0/1 replicas, not as a policy error, so it is easy to misdiagnose.
#
# This PATCHes the existing safeguards object (AKS Automatic always creates
# one) to exclude the Anyscale namespaces. If a first real workload run turns
# up other namespaces being rejected, widen the list via the variable rather
# than dropping the safeguards level.
#
# NOTE ON THE RESOURCE SHAPE: `deploymentSafeguards` is an EXTENSION resource,
# not a child of managedClusters — the RP lists it as a root-level type, so it
# is addressed as `<cluster-id>/providers/Microsoft.ContainerService/
# deploymentSafeguards/default`. Getting this wrong produces a 404 on an
# otherwise correct-looking patch. Verify with:
#   az provider show -n Microsoft.ContainerService \
#     --query "resourceTypes[?resourceType=='deploymentSafeguards']"
###############################################################################
resource "azapi_update_resource" "deployment_safeguards" {
  count = var.enable_deployment_safeguards_exclusion ? 1 : 0

  type        = "Microsoft.ContainerService/deploymentSafeguards@${var.deployment_safeguards_api_version}"
  resource_id = "${azurerm_kubernetes_automatic_cluster.aks.id}/providers/Microsoft.ContainerService/deploymentSafeguards/default"

  body = {
    properties = {
      level = var.deployment_safeguards_level
      excludedNamespaces = distinct(concat(
        [var.anyscale_operator_namespace],
        var.deployment_safeguards_excluded_namespaces,
      ))
    }
  }
}
