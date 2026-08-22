output "route_table_id" {
  value = azurerm_route_table.this.id
}

output "route_table_name" {
  value = azurerm_route_table.this.name
}

output "egress_route" {
  description = "Default egress route settings used by root terraform tests."
  value = {
    address_prefix         = azurerm_route.default_to_firewall.address_prefix
    next_hop_type          = azurerm_route.default_to_firewall.next_hop_type
    next_hop_in_ip_address = azurerm_route.default_to_firewall.next_hop_in_ip_address
    associated_subnet_ids  = values(var.subnet_ids_to_associate)
  }
}
