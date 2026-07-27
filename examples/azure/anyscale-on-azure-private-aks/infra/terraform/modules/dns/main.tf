###############################################################################
# Private DNS zones for private endpoints + AKS API server
# Required so that hosts in the workload VNet resolve privatelink FQDNs to
# the private IPs of the corresponding private endpoints.
# Docs: https://learn.microsoft.com/azure/private-link/private-endpoint-dns
###############################################################################
resource "azurerm_private_dns_zone" "this" {
  for_each            = var.zones
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

locals {
  zone_vnet_links = merge([
    for zone_key, zone_name in var.zones : {
      for link_key, vnet_id in var.vnet_links : "${zone_key}-${link_key}" => {
        zone_key  = zone_key
        zone_name = zone_name
        link_key  = link_key
        vnet_id   = vnet_id
      }
    }
  ]...)
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each              = local.zone_vnet_links
  name                  = "link-${each.value.zone_key}-${each.value.link_key}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.value.zone_key].name
  virtual_network_id    = each.value.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}
