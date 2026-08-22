output "log_analytics_workspace_id" {
  description = "Full ARM resource ID of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.this.id
}

output "log_analytics_workspace_customer_id" {
  description = "Workspace customer ID used by Azure CLI Log Analytics queries."
  value       = azurerm_log_analytics_workspace.this.workspace_id
}

output "log_analytics_workspace_name" {
  value = azurerm_log_analytics_workspace.this.name
}

output "ampls_scope_id" {
  description = "Azure Monitor Private Link Scope resource ID, when enabled."
  value       = var.ampls_enabled ? azurerm_monitor_private_link_scope.this[0].id : null
}

output "ampls_scope_name" {
  description = "Azure Monitor Private Link Scope name, when enabled."
  value       = var.ampls_enabled ? azurerm_monitor_private_link_scope.this[0].name : null
}

output "private_link_validation" {
  description = "Observability private-link settings used by root terraform tests."
  value = {
    workspace_id                      = azurerm_log_analytics_workspace.this.id
    workspace_customer_id             = azurerm_log_analytics_workspace.this.workspace_id
    internet_ingestion_enabled        = azurerm_log_analytics_workspace.this.internet_ingestion_enabled
    internet_query_enabled            = azurerm_log_analytics_workspace.this.internet_query_enabled
    ampls_enabled                     = var.ampls_enabled
    ampls_scope_id                    = var.ampls_enabled ? azurerm_monitor_private_link_scope.this[0].id : null
    ampls_ingestion_access_mode       = var.ampls_enabled ? azurerm_monitor_private_link_scope.this[0].ingestion_access_mode : null
    ampls_query_access_mode           = var.ampls_enabled ? azurerm_monitor_private_link_scope.this[0].query_access_mode : null
    ampls_private_endpoint_subnet_id  = var.ampls_enabled ? azurerm_private_endpoint.ampls[0].subnet_id : null
    ampls_private_dns_zone_ids        = var.ampls_private_dns_zone_ids
    workspace_scoped_service_resource = var.ampls_enabled ? azurerm_monitor_private_link_scoped_service.workspace[0].linked_resource_id : null
  }
}
