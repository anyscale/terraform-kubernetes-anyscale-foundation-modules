###############################################################################
# Route Table — sends 0.0.0.0/0 to the Azure Firewall private IP.
# Required by AKS when outboundType = userDefinedRouting.
# Docs: https://learn.microsoft.com/azure/aks/egress-outboundtype#outbound-type-of-userdefinedrouting
###############################################################################
resource "azurerm_route_table" "this" {
  name                = var.route_table_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  # Avoid BGP route propagation overriding the default route via the firewall.
  bgp_route_propagation_enabled = false
}

resource "azurerm_route" "default_to_firewall" {
  name                   = "default-to-firewall"
  resource_group_name    = var.resource_group_name
  route_table_name       = azurerm_route_table.this.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.firewall_private_ip
}

resource "azurerm_subnet_route_table_association" "this" {
  for_each       = var.subnet_ids_to_associate
  subnet_id      = each.value
  route_table_id = azurerm_route_table.this.id
}
