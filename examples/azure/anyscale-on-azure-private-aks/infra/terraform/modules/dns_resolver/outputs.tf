output "resolver_id" {
  description = "Azure DNS Private Resolver resource ID."
  value       = azurerm_private_dns_resolver.this.id
}

output "inbound_endpoint_id" {
  description = "Inbound endpoint resource ID."
  value       = azurerm_private_dns_resolver_inbound_endpoint.this.id
}

output "inbound_endpoint_ip" {
  description = "Static inbound endpoint private IP."
  value       = var.inbound_endpoint_ip
}

output "outbound_endpoint_id" {
  description = "Outbound endpoint resource ID."
  value       = azurerm_private_dns_resolver_outbound_endpoint.this.id
}

output "forwarding_ruleset_id" {
  description = "DNS forwarding ruleset resource ID."
  value       = azurerm_private_dns_resolver_dns_forwarding_ruleset.this.id
}

output "forwarding_rule_domains" {
  description = "Map of forwarding rule name -> forwarded domain suffix."
  value       = { for name, rule in azurerm_private_dns_resolver_forwarding_rule.this : name => rule.domain_name }
}

output "vnet_link_ids" {
  description = "Map of forwarding ruleset VNet link key -> resource ID."
  value       = { for key, link in azurerm_private_dns_resolver_virtual_network_link.this : key => link.id }
}

output "private_dns_resolver_validation" {
  description = "DNS Private Resolver settings used by root terraform tests."
  value = {
    inbound_endpoint_ip      = var.inbound_endpoint_ip
    inbound_subnet_id        = var.inbound_subnet_id
    outbound_subnet_id       = azurerm_private_dns_resolver_outbound_endpoint.this.subnet_id
    forwarding_ruleset_vnets = var.forwarding_ruleset_vnet_links
    forwarding_rule_domains  = { for name, rule in azurerm_private_dns_resolver_forwarding_rule.this : name => rule.domain_name }
    forwarding_rule_count    = length(azurerm_private_dns_resolver_forwarding_rule.this)
  }
}