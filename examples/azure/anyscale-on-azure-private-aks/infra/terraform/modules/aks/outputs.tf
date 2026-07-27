output "cluster_id" {
  description = "Full ARM resource ID of the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.id
}

output "cluster_name" {
  description = "Name of the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.name
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL used for Kubernetes Workload Identity federation."
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  description = "Object ID of the AKS kubelet identity used for AcrPull assignment."
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "private_fqdn" {
  description = "Private FQDN of the AKS API server."
  value       = azurerm_kubernetes_cluster.this.private_fqdn
}

output "control_plane_identity_principal_id" {
  description = "Principal ID of the user-assigned managed identity used by the AKS control plane."
  value       = azurerm_user_assigned_identity.aks_control_plane.principal_id
}

output "private_mode" {
  description = "Plan-time AKS private-mode settings used by root terraform tests."
  value = {
    private_cluster_enabled             = azurerm_kubernetes_cluster.this.private_cluster_enabled
    private_cluster_public_fqdn_enabled = azurerm_kubernetes_cluster.this.private_cluster_public_fqdn_enabled
    private_dns_zone_id                 = azurerm_kubernetes_cluster.this.private_dns_zone_id
    api_server_vnet_integration_enabled = azurerm_kubernetes_cluster.this.api_server_access_profile[0].virtual_network_integration_enabled
    api_server_subnet_id                = azurerm_kubernetes_cluster.this.api_server_access_profile[0].subnet_id
    outbound_type                       = azurerm_kubernetes_cluster.this.network_profile[0].outbound_type
    network_plugin                      = azurerm_kubernetes_cluster.this.network_profile[0].network_plugin
    network_policy                      = azurerm_kubernetes_cluster.this.network_profile[0].network_policy
    sku_tier                            = azurerm_kubernetes_cluster.this.sku_tier
    availability_zones                  = azurerm_kubernetes_cluster.this.default_node_pool[0].zones
    gpu_pool_availability_zones         = { for key, pool in var.gpu_pool_configs : key => pool.availability_zones }
    system_node_pool_min_count          = azurerm_kubernetes_cluster.this.default_node_pool[0].min_count
    system_node_pool_max_count          = azurerm_kubernetes_cluster.this.default_node_pool[0].max_count
    diagnostic_settings_enabled         = var.diagnostic_settings_enabled
    oidc_issuer_enabled                 = azurerm_kubernetes_cluster.this.oidc_issuer_enabled
    workload_identity_enabled           = azurerm_kubernetes_cluster.this.workload_identity_enabled
    azure_rbac_enabled                  = azurerm_kubernetes_cluster.this.azure_active_directory_role_based_access_control[0].azure_rbac_enabled
    automatic_upgrade_channel           = azurerm_kubernetes_cluster.this.automatic_upgrade_channel
    node_os_upgrade_channel             = azurerm_kubernetes_cluster.this.node_os_upgrade_channel
    local_account_disabled              = azurerm_kubernetes_cluster.this.local_account_disabled
    defender_enabled                    = length(azurerm_kubernetes_cluster.this.microsoft_defender) > 0
    key_vault_secrets_provider_enabled  = length(azurerm_kubernetes_cluster.this.key_vault_secrets_provider) > 0
    app_routing_istio_enabled           = local.app_routing_istio_enabled
    app_routing_istio_gateway_class     = local.app_routing_istio_gateway_class
    managed_gateway_api_installation    = local.managed_gateway_api_installation
    app_routing_istio_api_type          = local.app_routing_istio_managed_cluster_api_type
  }
}

output "container_insights" {
  description = "Container Insights DCR/DCE settings used by root terraform tests."
  value = {
    dcr_id                           = azurerm_monitor_data_collection_rule.container_insights.id
    dcr_name                         = azurerm_monitor_data_collection_rule.container_insights.name
    association_name                 = azurerm_monitor_data_collection_rule_association.container_insights.name
    streams                          = local.container_insights_streams
    container_log_v2_enabled         = var.container_insights_v2_enabled
    data_collection_interval         = var.container_insights_data_collection_interval
    namespace_filtering_mode         = var.container_insights_namespace_filtering_mode
    namespaces                       = var.container_insights_namespaces
    ampls_enabled                    = var.ampls_enabled
    config_dce_id                    = var.ampls_enabled ? azurerm_monitor_data_collection_endpoint.container_insights_config[0].id : null
    config_dce_public_network_access = var.ampls_enabled ? azurerm_monitor_data_collection_endpoint.container_insights_config[0].public_network_access_enabled : null
    config_dce_scoped_service_id     = var.ampls_enabled ? azurerm_monitor_private_link_scoped_service.container_insights_config_dce[0].id : null
  }
}

output "workload_identity" {
  description = "Federated workload identity settings for the Anyscale operator service account."
  value = {
    audience                  = azurerm_federated_identity_credential.anyscale_operator.audience
    issuer                    = azurerm_federated_identity_credential.anyscale_operator.issuer
    subject                   = azurerm_federated_identity_credential.anyscale_operator.subject
    user_assigned_identity_id = azurerm_federated_identity_credential.anyscale_operator.user_assigned_identity_id
  }
}

output "kubelogin_access" {
  description = "Entra-backed access settings used by validation scripts."
  value = {
    tenant_id            = azurerm_kubernetes_cluster.this.azure_active_directory_role_based_access_control[0].tenant_id
    azure_rbac_enabled   = azurerm_kubernetes_cluster.this.azure_active_directory_role_based_access_control[0].azure_rbac_enabled
    current_principal_id = data.azurerm_client_config.current.object_id
    role_assignments = concat(
      [for r in azurerm_role_assignment.current_principal_cluster_user : r.role_definition_name],
      [for r in azurerm_role_assignment.current_principal_cluster_admin : r.role_definition_name],
      [for r in azurerm_role_assignment.cluster_user : r.role_definition_name],
      [for r in azurerm_role_assignment.cluster_admin : r.role_definition_name],
    )
  }
}
