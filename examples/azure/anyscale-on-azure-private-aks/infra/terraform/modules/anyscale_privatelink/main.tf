###############################################################################
# Azure Private Link to the Anyscale control plane.
#
# Optional. Everywhere else in this example, the customer's own dependencies
# (storage, ACR, Key Vault, AKS API server) are reached privately, but
# workloads still reach Anyscale's SaaS control plane over the public
# internet via the firewall's anyscale_fqdns allow-list. This module replaces
# that path with a private endpoint against the Private Link Service that
# Anyscale exposes for this cloud deployment, plus a private DNS zone and
# records so hosts in the VNet resolve the control-plane hostname to the
# endpoint's private IP instead of the public one.
#
# Two things to be aware of:
#
#   * This does NOT remove the need for public egress entirely. Private Link
#     carries control-plane traffic only. Nodes still reach Microsoft Entra
#     for workload identity tokens, MCR for system images, Azure Resource
#     Manager, and (unless also privately linked) the Anyscale storage
#     account that serves images and dependencies — see
#     modules/anyscale_privatelink's caller for how i./s.azure.anyscaleuserdata.com
#     are already handled via the internal gateway.
#
#   * The private DNS zone is authoritative for its whole domain inside this
#     VNet. Once the zone exists and is linked, no other name in that domain
#     resolves publicly from inside the VNet — which is why the record list
#     defaults to a wildcard rather than an enumeration of hostnames.
###############################################################################

locals {
  enabled = var.enabled ? 1 : 0
}

###############################################################################
# Private endpoint against the Anyscale Private Link Service.
#
# `is_manual_connection = true` because this is a cross-tenant connection:
# Anyscale owns the service and must approve the request on their side. The
# endpoint stays in a Pending state — and DNS records point at an IP that
# does not yet carry traffic — until they do.
#
# The alias does not have to be in this cluster's region. A private endpoint
# must sit in the same region as its own VNet, but a Private Link Service can
# be reached from approved private endpoints in any public region.
###############################################################################
resource "azurerm_private_endpoint" "this" {
  count = local.enabled

  name                = "${var.name_prefix}-anyscale-pe"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                              = "${var.name_prefix}-anyscale"
    private_connection_resource_alias = var.privatelink_service_alias
    is_manual_connection              = true
    request_message                   = "Anyscale cloud for AKS cluster ${var.name_prefix}"
  }
}

###############################################################################
# Private DNS zone linked to this VNet.
#
# No private_dns_zone_group here — that only works for Azure first-party
# resources whose zone layout the platform already knows. For a third-party
# Private Link Service the records are ours to manage, which is what the A
# records below do.
###############################################################################
resource "azurerm_private_dns_zone" "this" {
  count = local.enabled

  name                = var.dns_zone_name
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  count = local.enabled

  name                  = "${var.name_prefix}-anyscale"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[0].name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}

# Point the Anyscale hostnames at the private endpoint's NIC address.
resource "azurerm_private_dns_a_record" "this" {
  for_each = local.enabled == 1 ? toset(var.record_names) : toset([])

  name                = each.value
  zone_name           = azurerm_private_dns_zone.this[0].name
  resource_group_name = var.resource_group_name
  ttl                 = 60
  records             = [azurerm_private_endpoint.this[0].private_service_connection[0].private_ip_address]
  tags                = var.tags
}
