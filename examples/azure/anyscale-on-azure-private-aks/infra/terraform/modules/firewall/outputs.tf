output "firewall_id" {
  value = azurerm_firewall.this.id
}

output "firewall_name" {
  value = azurerm_firewall.this.name
}

output "firewall_private_ip" {
  description = "Private IP of the Azure Firewall — used as next-hop in AKS UDR."
  value       = azurerm_firewall.this.ip_configuration[0].private_ip_address
}

output "firewall_public_ip" {
  value = azurerm_public_ip.firewall.ip_address
}

output "firewall_policy_id" {
  value = azurerm_firewall_policy.this.id
}

output "rule_collection_group_id" {
  description = "ID of the AKS egress rule collection group — chain dependencies on this so AKS waits for egress allow-list to be in place."
  value       = azurerm_firewall_policy_rule_collection_group.aks_egress.id
}

output "egress_validation" {
  description = "Known firewall egress settings used by root terraform tests."
  value = {
    firewall_sku_tier           = azurerm_firewall.this.sku_tier
    firewall_policy_sku         = azurerm_firewall_policy.this.sku
    dns_proxy_enabled           = azurerm_firewall_policy.this.dns[0].proxy_enabled
    dns_servers                 = azurerm_firewall_policy.this.dns[0].servers
    rule_collection_group       = azurerm_firewall_policy_rule_collection_group.aks_egress.name
    aks_nodes_cidr              = var.aks_nodes_cidr
    aks_fqdn_tag                = "AzureKubernetesService"
    aks_network_ports           = ["TCP:9000", "UDP:1194"]
    azure_identity_fqdns        = var.azure_identity_fqdns
    azure_monitor_fqdns         = var.azure_monitor_fqdns
    anyscale_fqdns              = var.anyscale_fqdns
    container_registry_fqdns    = var.container_registry_fqdns
    diagnostic_settings_enabled = var.diagnostic_settings_enabled
  }
}
