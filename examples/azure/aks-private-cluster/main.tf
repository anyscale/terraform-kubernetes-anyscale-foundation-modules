# ---------------------------------------------------------------------------------------------------------------------
# Anyscale AKS example - private networking, CPU only
#
# This is the Azure counterpart of examples/aws/eks-private-cpu.
#
# This file holds the resource group and the network: VNet, subnets, and the NSG
# that forms the egress boundary. Egress itself is provided by AKS, not by
# anything here - see the note at the bottom of this file.
#
#   storage.tf      - ADLS Gen2 storage account and its private endpoints
#   identity.tf     - operator managed identity and workload identity federation
#   aks.tf          - the cluster and its node pools
#   acr.tf          - private container registry and image cache rules
#   privatelink.tf  - optional Private Link to the Anyscale control plane
# ---------------------------------------------------------------------------------------------------------------------

###############################################################################
# Global-uniqueness suffix
#
# Storage accounts and container registries share a *global* DNS namespace
# across all of Azure, so a name derived from a generic cluster name is likely
# to collide with another tenant's deployment. Append a short random suffix
# unless an explicit name was supplied.
###############################################################################
resource "random_string" "name_suffix" {
  length  = 5
  upper   = false
  special = false
  numeric = true

  keepers = {
    aks_cluster_name = var.aks_cluster_name
  }
}

locals {
  name_suffix = random_string.name_suffix.result

  # Regional service tag suffix, e.g. "West US 2" -> "WestUS2".
  region_tag_suffix = replace(var.azure_location, " ", "")

  # Destinations permitted outbound, one NSG rule each.
  #
  # These are NOT interchangeable with a single regional AzureCloud tag. Most of
  # what the platform needs is GLOBAL infrastructure whose IPs are not in any
  # one region's slice - verified by resolving each host and checking which tag
  # actually contains the address:
  #
  #   login.microsoftonline.com  20.190.190.132  -> AzureActiveDirectory
  #   mcr.microsoft.com          150.171.70.10   -> AzureFrontDoor.FirstParty
  #   management.azure.com       4.150.240.10    -> AzureResourceManager
  #
  # None of those are in AzureCloud.WestUS2. Allowing only the regional tag
  # blocks the workload identity token exchange, every MCR image pull, and all
  # ARM calls - while the cluster keeps running on cached images, so the failure
  # surfaces later as "DefaultAzureCredential: failed to acquire a token".
  # distinct() so an entry in additional_egress_service_tags that duplicates a
  # derived one (e.g. Storage.<region> for your own region) is harmless rather
  # than a duplicate-key error in the for_each below.
  egress_service_tags = distinct(concat(
    [
      "AzureActiveDirectory",       # Entra - workload identity token exchange
      "AzureResourceManager",       # cloud provider, CSI, autoscaler
      "MicrosoftContainerRegistry", # MCR registry API
      "AzureFrontDoor.FirstParty",  # MCR image layers, and other first-party CDN
    ],
    [
      "AzureCloud.${local.region_tag_suffix}", # in-region Azure services
      "Storage.${local.region_tag_suffix}",    # Anyscale images and dependencies
    ],
    var.additional_egress_service_tags,
  ))
}

############################################
# resource group
############################################
resource "azurerm_resource_group" "rg" {
  name     = "${var.aks_cluster_name}-rg"
  location = var.azure_location
  tags     = var.tags
}

############################################
# networking - vnet and subnets
############################################
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.aks_cluster_name}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

# Nodes subnet. With Azure CNI overlay (aks.tf) pods do not consume IPs here,
# so this only needs to be sized for nodes - one IP each.
resource "azurerm_subnet" "nodes" {
  name                 = "aks-nodes"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.nodes_subnet_cidr]
}

# Private endpoint NICs live here, separate from the nodes subnet so the node
# NSG rules do not apply to them.
resource "azurerm_subnet" "private_endpoints" {
  #checkov:skip=CKV2_AZURE_31: "Ensure VNET subnet is configured with a Network Security Group (NSG)"

  name                 = "private-endpoints"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.private_endpoints_subnet_cidr]

  private_endpoint_network_policies = "Disabled"
}

############################################
# NSG on the nodes subnet
#
# This is the egress boundary. The AWS example expresses roughly the same
# intent with a security group allowing all intra-VPC traffic plus unrestricted
# egress; here the egress side is narrowed to Azure destinations.
#
# Rule priority matters: NSG rules evaluate lowest-number-first and the first
# match wins, so the Allow rules below sit ABOVE the optional Deny. Priorities
# are unique per direction; inbound and outbound are separate collections.
#
# The outbound band is carved up so the three ways of adding rules cannot
# collide - a collision fails the apply with SecurityRuleConflict:
#
#    110         VirtualNetwork
#    300-999     generated, one per entry in local.egress_service_tags
#                (300 + index*10, so ~70 tags before it runs out)
#    1000-3899   var.additional_egress_rules (validated to this band)
#    3900        var.anyscale_storage_account, when the Deny is on
#    4000        the Deny itself
#
# Note that the `Internet` service tag INCLUDES Azure's own public IP space.
# A bare "deny Internet" therefore also blocks Microsoft Entra, MCR and ARM, and
# the nodes would never provision. The per-tag allow rules below are what keep
# those reachable - and note it takes the GLOBAL tags to do it, not a regional
# AzureCloud.<region>, which contains almost none of them.
############################################
resource "azurerm_network_security_group" "nodes" {
  name                = "${var.aks_cluster_name}-nodes-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "nodes" {
  subnet_id                 = azurerm_subnet.nodes.id
  network_security_group_id = azurerm_network_security_group.nodes.id
}

# Node-to-node and node-to-endpoint traffic within the VNet. This restates the
# platform default (AllowVnetInBound/AllowVnetOutBound at priority 65000) so the
# intent is explicit and there is somewhere obvious to tighten later.
resource "azurerm_network_security_rule" "allow_vnet_inbound" {
  name                        = "AllowVnetInbound"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nodes.name

  priority                   = 100
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "*"
  source_port_range          = "*"
  destination_port_range     = "*"
  source_address_prefix      = "VirtualNetwork"
  destination_address_prefix = "VirtualNetwork"
}

resource "azurerm_network_security_rule" "allow_vnet_outbound" {
  name                        = "AllowVnetOutbound"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nodes.name

  priority                   = 110
  direction                  = "Outbound"
  access                     = "Allow"
  protocol                   = "*"
  source_port_range          = "*"
  destination_port_range     = "*"
  source_address_prefix      = "VirtualNetwork"
  destination_address_prefix = "VirtualNetwork"
}

# Inbound traffic to a PUBLIC LoadBalancer service - the Anyscale ingress.
#
# This rule is easy to overlook and its absence fails late. An Azure Standard
# Load Balancer with a public frontend does NOT SNAT the client: the node sees
# the ORIGINAL client's public IP as the source address. That traffic therefore
# matches the `Internet` service tag and, without this rule, is dropped by the
# platform's DenyAllInBound at priority 65500.
#
# AKS does create NSG rules for LoadBalancer services automatically - but on
# the NSG it manages in the node resource group, NOT on a user-assigned NSG
# attached to the subnet. Both NSGs are evaluated for inbound traffic to a
# node, so this one has to permit it independently.
#
# The ports are the ingress controller's SERVICE ports (80/443), NOT its
# nodePorts. AKS creates the load balancing rules with backendPort ==
# frontendPort (floating IP / DSR), so the load balancer forwards to 80 and 443
# on the node and the node's dataplane does the port mapping. The nodePorts
# appear only in the health probe config, and probes are already permitted by
# the platform's AllowAzureLoadBalancerInBound default rule.
#
# Opening the nodePort range instead fails convincingly: probes succeed, the LB
# reports healthy, the Service gets an EXTERNAL-IP, DNS resolves - and every
# real request is dropped.
#
# destination_address_prefix is "*" rather than VirtualNetwork because with
# floating IP the packet arrives addressed to the load balancer's FRONTEND IP,
# not to the node's VNet address.
#
# Set allow_public_ingress = false if you switch the ingress controller to an
# internal load balancer, in which case client traffic originates inside the
# VNet and the AllowVnetInbound rule above already covers it.
resource "azurerm_network_security_rule" "allow_public_ingress" {
  count = var.allow_public_ingress ? 1 : 0

  name                        = "AllowPublicIngressToNodePorts"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nodes.name

  priority                = 200
  direction               = "Inbound"
  access                  = "Allow"
  protocol                = "Tcp"
  source_port_range       = "*"
  destination_port_ranges = var.public_ingress_ports

  # Defaults to the `Internet` tag - anyone. Set public_ingress_source_prefixes
  # to a CIDR list to restrict who can reach the ingress; because the load
  # balancer does not SNAT, a /32 matches the real client.
  #
  # A single value has to use the singular argument: Azure stores one source as
  # `sourceAddressPrefix`, so rendering it as a one-element `sourceAddressPrefixes`
  # produces a permanent diff. The plural form also rejects service tags, which
  # is what keeps the default working.
  source_address_prefix   = length(var.public_ingress_source_prefixes) == 1 ? var.public_ingress_source_prefixes[0] : null
  source_address_prefixes = length(var.public_ingress_source_prefixes) > 1 ? var.public_ingress_source_prefixes : null

  destination_address_prefix = "*"
}

# One allow rule per destination service tag.
#
# A rule takes a single tag - `destination_address_prefixes` accepts CIDRs but
# not service tags - so these are generated rather than written out.
#
# WHAT THIS STILL DOES NOT COVER: `packages.aks.azure.com`, the mirror nodes
# pull kubelet, containerd and CNI binaries from at provisioning time, resolves
# into Akamai address space (23.212.62.207) and is in NO Azure service tag at
# all. NSG rules cannot express it. Existing nodes are unaffected because those
# binaries are baked into the node image, but node image upgrades and some
# provisioning paths can fail with the deny enabled. Only FQDN filtering (Azure
# Firewall) or leaving general egress open covers that case.
#
# Granularity limit, unchanged: a tag permits reaching ANY endpoint behind it -
# Storage.<region> means any storage account in the region, not just Anyscale's.
# This is a blast-radius control, not an exfiltration control.
resource "azurerm_network_security_rule" "allow_service_tag_outbound" {
  for_each = { for i, t in local.egress_service_tags : t => 300 + i * 10 }

  name                        = "AllowOutbound-${replace(each.key, ".", "-")}"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nodes.name

  priority                   = each.value
  direction                  = "Outbound"
  access                     = "Allow"
  protocol                   = "*"
  source_port_range          = "*"
  destination_port_range     = "*"
  source_address_prefix      = "*"
  destination_address_prefix = each.key
}

# Anyscale's own storage account, which serves images and dependencies.
#
# Only created when egress is actually being blocked - with the Deny off there
# is nothing to punch through, so the rule would be noise.
#
# Largely redundant with `additional_egress_service_tags`, which is the simpler
# way to add a Storage.<region> tag. It exists because declaring the account
# also drives the optional private endpoint in storage.tf, and because naming
# the dependency is clearer than an opaque tag in a list. If the account is in
# this cluster's own region, the derived Storage.<region> entry already covers
# it and this rule is pure documentation.
#
# Granularity limit worth repeating: Storage.<region> permits reaching ANY
# storage account in that region. To narrow it to this one specific account you
# need the private endpoint in storage.tf
# (var.enable_anyscale_storage_private_endpoint).
resource "azurerm_network_security_rule" "anyscale_storage_egress" {
  count = var.block_public_internet_egress && var.anyscale_storage_account != null ? 1 : 0

  name                        = "AllowAnyscaleStorageOutbound"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nodes.name

  priority                   = 3900
  direction                  = "Outbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "443"
  source_address_prefix      = "*"
  destination_address_prefix = "Storage.${replace(coalesce(var.anyscale_storage_account.region, var.azure_location), " ", "")}"
}

# Free-form escape hatch: destinations that are not expressible as a service tag
# (a specific CIDR, a non-443 port, a protocol restriction).
#
# For service tags prefer `additional_egress_service_tags` - it feeds the
# generated rules above and cannot collide with them. Use this only when a tag
# will not do.
#
# Priorities are validated into 1000-3899 so they sit clear of the generated
# rules, the Anyscale-storage rule at 3900, and the Deny at 4000.
resource "azurerm_network_security_rule" "additional_egress" {
  for_each = var.additional_egress_rules

  name                        = each.key
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nodes.name

  priority                   = each.value.priority
  direction                  = "Outbound"
  access                     = "Allow"
  protocol                   = each.value.protocol
  source_port_range          = "*"
  destination_port_range     = each.value.ports
  source_address_prefix      = "*"
  destination_address_prefix = each.value.destination
}

# Everything that is not an Azure endpoint. Opt-in - see the variable docs for
# why this defaults to off, and what it breaks when enabled.
resource "azurerm_network_security_rule" "deny_internet_outbound" {
  count = var.block_public_internet_egress ? 1 : 0

  name                        = "DenyInternetOutbound"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nodes.name

  priority                   = 4000
  direction                  = "Outbound"
  access                     = "Deny"
  protocol                   = "*"
  source_port_range          = "*"
  destination_port_range     = "*"
  source_address_prefix      = "*"
  destination_address_prefix = "Internet"
}

############################################
# Egress
#
# There is deliberately NO NAT gateway here.
#
# This is the one place the example intentionally diverges from
# examples/aws/eks-private-cpu, because the platforms differ in kind. On AWS a
# private subnet has NO route off the VPC unless you put one in its route table
# - omit the NAT gateway and nodes cannot reach ECR or STS, so they never join
# the cluster. Routing is explicit and the NAT gateway is load-bearing.
#
# On Azure it is not. AKS provisions outbound itself: the default
# `outbound_type = "loadBalancer"` creates a Standard load balancer and wires
# SNAT at cluster-creation time, with no route table to manage. `outbound_type`
# selects HOW egress happens, not WHETHER.
#
# A user-assigned NAT gateway was tried here and removed. It bought a dedicated
# egress IP and on-demand SNAT ports - neither of which matters at this size -
# and cost a VNet-scope `Network Contributor` grant for the cluster identity.
# The reason: with a NAT gateway AKS creates no load balancer at provisioning,
# so the first ingress Service forces the IN-CLUSTER cloud provider to create
# one and join the VMSS to a new backend pool, which needs
# `Microsoft.Network/virtualNetworks/subnets/join/action` on a BYO VNet. With
# the default outbound type the AKS resource provider does that at creation and
# no extra permission is needed.
#
# Egress is still bounded - by the NSG above, not by the outbound mechanism.
# `block_public_internet_egress` denies everything that is not an Azure
# endpoint, and it works identically with either outbound type.
#
# If you do want a dedicated egress IP, add azurerm_public_ip +
# azurerm_nat_gateway + the subnet association, set
# `outbound_type = "userAssignedNATGateway"` in aks.tf, AND grant the cluster
# identity Network Contributor on the VNet - all three, or the ingress Service
# hangs at EXTERNAL-IP <pending>.
############################################
