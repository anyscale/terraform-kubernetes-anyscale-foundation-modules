output "bastion_id" {
  value = azurerm_bastion_host.this.id
}

output "bastion_name" {
  value = azurerm_bastion_host.this.name
}

output "bastion_dns_name" {
  value = azurerm_bastion_host.this.dns_name
}

output "private_aks_access" {
  description = "Bastion settings used by root terraform tests."
  value = {
    sku                         = azurerm_bastion_host.this.sku
    tunneling_enabled           = azurerm_bastion_host.this.tunneling_enabled
    bastion_subnet_id           = azurerm_bastion_host.this.ip_configuration[0].subnet_id
    public_ip_sku               = azurerm_public_ip.bastion.sku
    public_ip_method            = azurerm_public_ip.bastion.allocation_method
    diagnostic_settings_enabled = var.diagnostic_settings_enabled
    diagnostic_categories       = ["BastionAuditLogs"]
  }
}
