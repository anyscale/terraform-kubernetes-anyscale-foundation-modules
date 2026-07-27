output "acr_id" {
  value = azurerm_container_registry.this.id
}

output "acr_name" {
  value = azurerm_container_registry.this.name
}

output "login_server" {
  value = azurerm_container_registry.this.login_server
}

output "private_mode" {
  description = "ACR private access settings used by root terraform tests."
  value = {
    sku                           = azurerm_container_registry.this.sku
    admin_enabled                 = azurerm_container_registry.this.admin_enabled
    public_network_access_enabled = azurerm_container_registry.this.public_network_access_enabled
    zone_redundancy_enabled       = azurerm_container_registry.this.zone_redundancy_enabled
    private_endpoint_subnet_id    = azurerm_private_endpoint.this.subnet_id
    diagnostic_settings_enabled   = var.diagnostic_settings_enabled
    diagnostic_categories         = ["ContainerRegistryLoginEvents", "ContainerRegistryRepositoryEvents"]
  }
}
