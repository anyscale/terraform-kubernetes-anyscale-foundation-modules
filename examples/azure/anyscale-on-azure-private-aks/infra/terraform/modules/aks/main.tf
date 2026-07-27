###############################################################################
# Private AKS cluster with API Server VNet Integration
# Docs:
# - https://learn.microsoft.com/azure/aks/private-clusters
# - https://learn.microsoft.com/azure/aks/api-server-vnet-integration
# - https://learn.microsoft.com/azure/aks/egress-outboundtype#outbound-type-of-userdefinedrouting
# - https://learn.microsoft.com/azure/aks/use-managed-identity
###############################################################################
resource "azurerm_user_assigned_identity" "aks_control_plane" {
  name                = "id-${var.cluster_name}-cp"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

data "azurerm_client_config" "current" {}

locals {
  app_routing_istio_gateway_class            = "approuting-istio"
  app_routing_istio_enabled                  = true
  managed_gateway_api_installation           = "Standard"
  app_routing_istio_managed_cluster_api_type = "Microsoft.ContainerService/managedClusters@2026-03-02-preview"
}

# Required for AKS to manage the node resource group and integrate the API
# server into the VNet. With BYO subnets + private DNS zone we must grant the
# control-plane identity rights on those resources.
# Docs: https://learn.microsoft.com/azure/aks/configure-azure-cni#prerequisites
resource "azurerm_role_assignment" "cp_network_contrib_nodes" {
  scope                = var.nodes_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_control_plane.principal_id
}

resource "azurerm_role_assignment" "cp_network_contrib_apiserver" {
  scope                = var.apiserver_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_control_plane.principal_id
}

resource "azurerm_role_assignment" "cp_pdns_contrib" {
  scope                = var.private_dns_zone_id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.aks_control_plane.principal_id
}

###############################################################################
# Cluster
###############################################################################
resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.dns_prefix
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier
  tags                = var.tags

  # Private cluster + API server VNet integration.
  private_cluster_enabled             = true
  private_dns_zone_id                 = var.private_dns_zone_id
  private_cluster_public_fqdn_enabled = false

  # Workload identity / OIDC.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  role_based_access_control_enabled = true
  local_account_disabled            = var.local_account_disabled

  # Azure Policy add-on — required for the AKS Image Integrity (Preview) feature,
  # which is delivered through an Azure Policy built-in initiative + Gatekeeper.
  azure_policy_enabled = var.azure_policy_enabled

  automatic_upgrade_channel = var.automatic_upgrade_channel
  node_os_upgrade_channel   = var.node_os_upgrade_channel

  azure_active_directory_role_based_access_control {
    tenant_id          = var.azure_tenant_id
    azure_rbac_enabled = true
  }

  # Force all egress through the Azure Firewall via the route table on the
  # node subnet (UDR).
  # Docs: https://learn.microsoft.com/azure/aks/egress-outboundtype
  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    outbound_type     = "userDefinedRouting"
    service_cidr      = var.service_cidr
    dns_service_ip    = var.dns_service_ip
    load_balancer_sku = "standard"
  }

  api_server_access_profile {
    virtual_network_integration_enabled = true
    subnet_id                           = var.apiserver_subnet_id
  }

  default_node_pool {
    name                         = "sys"
    vm_size                      = var.system_vm_size
    vnet_subnet_id               = var.nodes_subnet_id
    os_disk_size_gb              = 64
    type                         = "VirtualMachineScaleSets"
    auto_scaling_enabled         = true
    min_count                    = var.system_node_pool_min_count
    max_count                    = var.system_node_pool_max_count
    zones                        = var.availability_zones
    only_critical_addons_enabled = true
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks_control_plane.id]
  }

  dynamic "microsoft_defender" {
    for_each = var.defender_enabled ? [1] : []
    content {
      log_analytics_workspace_id = var.log_analytics_workspace_id
    }
  }

  dynamic "key_vault_secrets_provider" {
    for_each = var.key_vault_secrets_provider_enabled ? [1] : []
    content {
      secret_rotation_enabled = true
    }
  }

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  lifecycle {
    ignore_changes = [
      default_node_pool[0].upgrade_settings,
      kubernetes_version,
      microsoft_defender,
      web_app_routing,
    ]
  }

  depends_on = [
    azurerm_role_assignment.cp_network_contrib_nodes,
    azurerm_role_assignment.cp_network_contrib_apiserver,
    azurerm_role_assignment.cp_pdns_contrib,
  ]
}

resource "time_sleep" "app_routing_istio_reconcile_wait" {
  create_duration = "600s"

  triggers = {
    cluster_id   = azurerm_kubernetes_cluster.this.id
    cpu_pool_id  = azurerm_kubernetes_cluster_node_pool.cpu.id
    gpu_pools    = length(values(azurerm_kubernetes_cluster_node_pool.gpu)) > 0 ? "present" : "none"
    gpu_pool_ids = length(values(azurerm_kubernetes_cluster_node_pool.gpu)) > 0 ? "present" : "none"
  }

  depends_on = [
    azurerm_kubernetes_cluster.this,
    azurerm_kubernetes_cluster_node_pool.cpu,
    azurerm_kubernetes_cluster_node_pool.gpu,
  ]
}

resource "azapi_update_resource" "app_routing_istio" {
  type        = local.app_routing_istio_managed_cluster_api_type
  resource_id = azurerm_kubernetes_cluster.this.id

  body = {
    properties = {
      ingressProfile = {
        gatewayAPI = {
          installation = local.managed_gateway_api_installation
        }
        webAppRouting = {
          enabled = local.app_routing_istio_enabled
          gatewayAPIImplementations = {
            appRoutingIstio = {
              mode = "Enabled"
            }
          }
        }
      }
    }
  }

  # Enabling the preview web-app-routing + Istio Gateway API profile is a
  # long-running managed-cluster PATCH. Under private egress it can exceed the
  # azapi provider's 30m default, leaving the client with "context deadline
  # exceeded" even though ARM keeps reconciling. Give it room so the apply
  # waits for terminal state instead of failing mid-reconcile.
  timeouts {
    create = "1h"
    update = "1h"
  }

  # AKS can reject the preview ingress patch while the control plane is still
  # reconciling node-pool changes from the same cluster. Wait briefly after the
  # initial node-pool creation cycle so the patch is applied after the cluster
  # is no longer in an update storm.
  depends_on = [
    time_sleep.app_routing_istio_reconcile_wait,
  ]
}

###############################################################################
# CPU node pool — On-demand
###############################################################################
resource "azurerm_kubernetes_cluster_node_pool" "cpu" {
  name                  = "cpu"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.cpu_vm_size
  mode                  = "User"
  vnet_subnet_id        = var.nodes_subnet_id
  os_disk_size_gb       = 128
  zones                 = var.availability_zones

  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 4

  tags = var.tags

  lifecycle {
    # AKS mutates node pool upgrade settings during managed upgrade workflows; keep
    # Terraform from fighting those platform-managed values on later applies.
    ignore_changes = [upgrade_settings]
  }
}

###############################################################################
# GPU node pools — On-demand
###############################################################################
resource "azurerm_kubernetes_cluster_node_pool" "gpu" {
  for_each              = var.gpu_pool_configs
  name                  = each.value.name
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = each.value.vm_size
  mode                  = "User"
  vnet_subnet_id        = var.nodes_subnet_id
  os_disk_size_gb       = 128
  gpu_driver            = "Install"
  zones                 = each.value.availability_zones

  auto_scaling_enabled = true
  min_count            = each.value.min_count
  max_count            = each.value.max_count

  node_labels = {
    "nvidia.com/gpu.product" = each.value.product_name
    "nvidia.com/gpu.count"   = each.value.gpu_count
  }

  node_taints = [
    "node.anyscale.com/capacity-type=ON_DEMAND:NoSchedule",
    "nvidia.com/gpu=present:NoSchedule",
    "node.anyscale.com/accelerator-type=GPU:NoSchedule",
  ]

  tags = var.tags

  lifecycle {
    # AKS mutates node pool upgrade settings during managed upgrade workflows; keep
    # Terraform from fighting those platform-managed values on later applies.
    ignore_changes = [upgrade_settings]
  }
}

###############################################################################
# Container Insights DCR/DCE — explicitly selects ContainerLogV2 and supports
# AMPLS private configuration access without enabling Managed Prometheus/Grafana.
###############################################################################
locals {
  container_insights_streams           = var.container_insights_v2_enabled ? distinct(concat(var.container_insights_streams, ["Microsoft-ContainerLogV2"])) : var.container_insights_streams
  container_insights_extension_streams = ["Microsoft-ContainerInsights-Group-Default"]
  ci_dcr_name                          = "MSCI-${var.location}-${var.cluster_name}"
  ci_config_dce_name_full              = "MSCI-config-${var.location}-${var.cluster_name}"
  ci_config_dce_name_trimmed           = substr(local.ci_config_dce_name_full, 0, 43)
  ci_config_dce_name                   = endswith(local.ci_config_dce_name_trimmed, "-") ? substr(local.ci_config_dce_name_trimmed, 0, 42) : local.ci_config_dce_name_trimmed
}

resource "azurerm_monitor_data_collection_endpoint" "container_insights_config" {
  count = var.ampls_enabled ? 1 : 0

  name                          = local.ci_config_dce_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  kind                          = "Linux"
  public_network_access_enabled = false
  tags                          = var.tags
}

resource "azurerm_monitor_data_collection_rule" "container_insights" {
  name                = local.ci_dcr_name
  resource_group_name = var.resource_group_name
  location            = var.location
  description         = "DCR for AKS Container Insights with ContainerLogV2 enabled."
  tags                = var.tags

  destinations {
    log_analytics {
      workspace_resource_id = var.log_analytics_workspace_id
      name                  = "ciworkspace"
    }
  }

  data_flow {
    streams      = local.container_insights_extension_streams
    destinations = ["ciworkspace"]
  }

  data_sources {
    extension {
      streams        = local.container_insights_extension_streams
      extension_name = "ContainerInsights"
      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = var.container_insights_data_collection_interval
          namespaceFilteringMode = var.container_insights_namespace_filtering_mode
          namespaces             = var.container_insights_namespaces
          enableContainerLogV2   = var.container_insights_v2_enabled
        }
      })
      name = "ContainerInsightsExtension"
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
  description             = "Association of Container Insights data collection rule."
}

resource "azurerm_monitor_data_collection_rule_association" "container_insights_config" {
  count = var.ampls_enabled ? 1 : 0

  name                        = "configurationAccessEndpoint"
  target_resource_id          = azurerm_kubernetes_cluster.this.id
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.container_insights_config[0].id
  description                 = "Private configuration endpoint association for Container Insights."
}

resource "azurerm_monitor_private_link_scoped_service" "container_insights_config_dce" {
  count = var.ampls_enabled ? 1 : 0

  name                = "${local.ci_config_dce_name}-connection"
  resource_group_name = var.ampls_resource_group_name
  scope_name          = var.ampls_scope_name
  linked_resource_id  = azurerm_monitor_data_collection_endpoint.container_insights_config[0].id
}

###############################################################################
# Workload identity — federated credential for the Anyscale operator UAMI
###############################################################################
resource "azurerm_federated_identity_credential" "anyscale_operator" {
  name                      = "anyscale-operator-fic"
  user_assigned_identity_id = var.anyscale_operator_identity_id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.anyscale_operator_namespace}:${var.anyscale_operator_serviceaccount}"
}

###############################################################################
# Allow AKS kubelet to pull from ACR
###############################################################################
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "current_principal_cluster_user" {
  count = var.assign_current_principal_cluster_access ? 1 : 0

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "current_principal_cluster_admin" {
  count = var.assign_current_principal_cluster_access ? 1 : 0

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "cluster_user" {
  for_each = var.cluster_user_principal_ids

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each = var.cluster_admin_principal_ids

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}

###############################################################################
# AKS diagnostic settings -> Log Analytics
###############################################################################
resource "azurerm_monitor_diagnostic_setting" "aks" {
  count = var.diagnostic_settings_enabled ? 1 : 0

  name                       = "tfdiag-${var.cluster_name}"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
