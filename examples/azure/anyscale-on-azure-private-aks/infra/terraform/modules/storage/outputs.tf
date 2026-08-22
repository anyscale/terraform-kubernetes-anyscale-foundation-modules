output "storage_account_id" {
  description = "Full ARM resource ID of the private storage account."
  value       = azurerm_storage_account.this.id
}

output "storage_account_name" {
  description = "Name of the private storage account."
  value       = azurerm_storage_account.this.name
}

output "container_name" {
  description = "Name of the private blob container used as the Anyscale cloud storage bucket equivalent."
  value       = azurerm_storage_container.blob.name
}

output "container_id" {
  description = "Full ARM resource ID of the private blob container used as the Anyscale cloud storage bucket equivalent."
  value       = local.container_id
}

output "blob_endpoint" {
  description = "Primary blob endpoint for the storage account."
  value       = azurerm_storage_account.this.primary_blob_endpoint
}

output "dfs_endpoint" {
  description = "Primary DFS endpoint for the HNS-enabled storage account."
  value       = azurerm_storage_account.this.primary_dfs_endpoint
}

output "private_mode" {
  description = "Storage private access settings used by root terraform tests."
  value = {
    storage_account_id              = azurerm_storage_account.this.id
    container_id                    = local.container_id
    container_name                  = azurerm_storage_container.blob.name
    account_replication_type        = azurerm_storage_account.this.account_replication_type
    public_network_access_enabled   = azurerm_storage_account.this.public_network_access_enabled
    default_network_action          = azurerm_storage_account.this.network_rules[0].default_action
    https_traffic_only_enabled      = azurerm_storage_account.this.https_traffic_only_enabled
    min_tls_version                 = azurerm_storage_account.this.min_tls_version
    allow_nested_items_to_be_public = azurerm_storage_account.this.allow_nested_items_to_be_public
    shared_access_key_enabled       = azurerm_storage_account.this.shared_access_key_enabled
    default_to_oauth_authentication = azurerm_storage_account.this.default_to_oauth_authentication
    cors_allowed_origins            = azurerm_storage_account.this.blob_properties[0].cors_rule[0].allowed_origins
    cors_allowed_methods            = azurerm_storage_account.this.blob_properties[0].cors_rule[0].allowed_methods
    blob_private_endpoint_subnet_id = azurerm_private_endpoint.blob.subnet_id
    dfs_private_endpoint_subnet_id  = azurerm_private_endpoint.dfs.subnet_id
    diagnostic_settings_enabled     = var.diagnostic_settings_enabled
    diagnostic_setting_targets      = var.diagnostic_settings_enabled ? [azurerm_monitor_diagnostic_setting.storage_account[0].target_resource_id, azurerm_monitor_diagnostic_setting.blob_service[0].target_resource_id] : []
    blob_diagnostic_categories      = ["StorageRead", "StorageWrite", "StorageDelete"]
  }
}
