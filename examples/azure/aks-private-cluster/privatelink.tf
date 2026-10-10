###############################################################################
# Azure Private Link to the Anyscale control plane.
#
# Creates a private endpoint against the Private Link Service that Anyscale
# exposes for your cloud deployment, plus a private DNS zone and records so
# that workloads inside the VNet resolve the control plane hostname to the
# endpoint's private IP rather than reaching it over the public internet.
#
# This is the Azure counterpart of examples/aws/eks-private-cpu/privatelink.tf,
# which does the same thing with a VPC interface endpoint and a Route 53 private
# hosted zone.
#
# Opt-in. Set enable_privatelink = true and supply the PLS alias Anyscale
# provides for your deployment.
#
# Two things to be aware of, both carried over from the AWS example:
#
#   * This does NOT remove the need for egress. Private Link carries control
#     plane traffic only. Nodes still reach Microsoft Entra for workload
#     identity tokens, MCR for system images, Azure Resource Manager, and the
#     Anyscale storage account that serves images and dependencies.
#
#   * The private DNS zone is authoritative for its whole domain inside this
#     VNet. Once the zone exists and is linked, no other name in that domain
#     resolves publicly from inside the VNet. That is why the record list
#     defaults to a wildcard rather than an enumeration of hostnames.
###############################################################################

locals {
  privatelink_enabled = var.enable_privatelink

  # FQDNs that resolve to the endpoint, for the output below.
  # An entry of "*" produces the wildcard record *.<zone>; "@" is the apex.
  privatelink_record_fqdns = local.privatelink_enabled ? {
    for name in var.anyscale_privatelink_record_names :
    name => name == "@" ? var.anyscale_private_dns_zone_name : "${name}.${var.anyscale_private_dns_zone_name}"
  } : {}
}

###############################################################################
# Private endpoint against the Anyscale Private Link Service.
#
# `is_manual_connection = true` because this is a cross-tenant connection:
# Anyscale owns the service and must approve the request on their side. The
# endpoint stays in a Pending state - and DNS records point at an IP that does
# not yet carry traffic - until they do. Expect that handshake after the first
# apply.
#
# The alias does NOT have to be in this cluster's region. A private endpoint
# must sit in the same region as its own VNet, but a Private Link service can be
# accessed from approved private endpoints in any public region - so the alias
# Anyscale gives you works regardless of where you deploy. Ask for an in-region
# alias only if you want the traffic landing closer.
###############################################################################
resource "azurerm_private_endpoint" "anyscale" {
  count = local.privatelink_enabled ? 1 : 0

  name                = "${var.aks_cluster_name}-anyscale-pe"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                              = "${var.aks_cluster_name}-anyscale"
    private_connection_resource_alias = var.anyscale_privatelink_service_alias
    is_manual_connection              = true
    request_message                   = "Anyscale cloud for AKS cluster ${var.aks_cluster_name}"
  }

  tags = var.tags
}

###############################################################################
# Private DNS zone linked to this VNet.
#
# No private_dns_zone_group here - that only works for Azure first-party
# resources whose zone layout the platform knows. For a third-party Private
# Link Service the records are ours to manage, which is what the A records
# below do.
###############################################################################
resource "azurerm_private_dns_zone" "anyscale" {
  count = local.privatelink_enabled ? 1 : 0

  name                = var.anyscale_private_dns_zone_name
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "anyscale" {
  count = local.privatelink_enabled ? 1 : 0

  name                  = "${var.aks_cluster_name}-anyscale"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.anyscale[0].name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
  tags                  = var.tags
}

# Point the Anyscale hostnames at the private endpoint's NIC address.
resource "azurerm_private_dns_a_record" "anyscale" {
  for_each = toset(local.privatelink_enabled ? var.anyscale_privatelink_record_names : [])

  name                = each.value
  zone_name           = azurerm_private_dns_zone.anyscale[0].name
  resource_group_name = azurerm_resource_group.rg.name
  ttl                 = 60
  records             = [azurerm_private_endpoint.anyscale[0].private_service_connection[0].private_ip_address]
  tags                = var.tags
}

###############################################################################
# Outputs
###############################################################################
output "anyscale_privatelink_endpoint_id" {
  description = "ID of the Anyscale Private Link endpoint, or null when disabled."
  value       = try(azurerm_private_endpoint.anyscale[0].id, null)
}

output "anyscale_privatelink_private_ip" {
  description = "Private IP the Anyscale control plane hostnames resolve to inside the VNet, or null when disabled."
  value       = try(azurerm_private_endpoint.anyscale[0].private_service_connection[0].private_ip_address, null)
}

output "anyscale_privatelink_record_fqdns" {
  description = "Private DNS records created for the Anyscale control plane."
  value       = values(local.privatelink_record_fqdns)
}
