###############################################################################
# Azure Container Registry — Premium SKU (required for Private Link),
# public network access disabled, accessed via private endpoint only.
# Docs: https://learn.microsoft.com/azure/container-registry/container-registry-private-link
###############################################################################
resource "azurerm_container_registry" "this" {
  name                          = var.name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = false
  zone_redundancy_enabled       = var.zone_redundancy_enabled
  tags                          = var.tags
}

resource "azurerm_private_endpoint" "this" {
  name                = "pep-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_container_registry.this.id
    is_manual_connection           = false
    subresource_names              = ["registry"]
  }

  private_dns_zone_group {
    name                 = "pdz-acr"
    private_dns_zone_ids = [var.pe_dns_zone_id]
  }
}

###############################################################################
# Diagnostic settings — registry login/repository events and metrics.
###############################################################################
resource "azurerm_monitor_diagnostic_setting" "acr" {
  count = var.diagnostic_settings_enabled ? 1 : 0

  name                       = "tfdiag-${var.name}"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }

  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
