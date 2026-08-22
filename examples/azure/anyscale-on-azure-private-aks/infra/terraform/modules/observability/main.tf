###############################################################################
# Log Analytics workspace — used by Container Insights (AKS), Firewall logs,
# and any diagnostic settings.
###############################################################################
resource "azurerm_log_analytics_workspace" "this" {
  name                       = var.log_analytics_name
  resource_group_name        = var.resource_group_name
  location                   = var.location
  sku                        = "PerGB2018"
  retention_in_days          = var.retention_in_days
  internet_ingestion_enabled = var.internet_ingestion_enabled
  internet_query_enabled     = var.internet_query_enabled
  tags                       = var.tags
}

###############################################################################
# Azure Monitor Private Link Scope — private ingestion/query path for Monitor,
# Log Analytics, and Azure Monitor Agent endpoints.
###############################################################################
resource "azurerm_monitor_private_link_scope" "this" {
  count = var.ampls_enabled ? 1 : 0

  name                  = var.ampls_name
  resource_group_name   = var.resource_group_name
  ingestion_access_mode = var.ampls_ingestion_access_mode
  query_access_mode     = var.ampls_query_access_mode
  tags                  = var.tags
}

resource "azurerm_monitor_private_link_scoped_service" "workspace" {
  count = var.ampls_enabled ? 1 : 0

  name                = "${var.log_analytics_name}-connection"
  resource_group_name = var.resource_group_name
  scope_name          = azurerm_monitor_private_link_scope.this[0].name
  linked_resource_id  = azurerm_log_analytics_workspace.this.id
}

resource "azurerm_private_endpoint" "ampls" {
  count = var.ampls_enabled ? 1 : 0

  name                = var.ampls_private_endpoint_name
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.ampls_name}"
    private_connection_resource_id = azurerm_monitor_private_link_scope.this[0].id
    is_manual_connection           = false
    subresource_names              = ["azuremonitor"]
  }

  private_dns_zone_group {
    name = "pdz-ampls"
    private_dns_zone_ids = [
      var.ampls_private_dns_zone_ids.monitor,
      var.ampls_private_dns_zone_ids.oms,
      var.ampls_private_dns_zone_ids.ods,
      var.ampls_private_dns_zone_ids.agentsvc,
      var.ampls_private_dns_zone_ids.blob,
    ]
  }
}
