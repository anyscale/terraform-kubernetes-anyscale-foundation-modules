###############################################################################
# Naming locals — CAF abbreviations
# https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations
###############################################################################
locals {
  suffix     = "${var.project}-${var.environment}-${var.region_short}"
  suffix_alt = "${var.project}${var.environment}${var.region_short}" # for alphanumeric-only resources

  names = {
    resource_group           = "rg-${local.suffix}"
    vnet                     = "vnet-${local.suffix}"
    subnet_aks_nodes         = "snet-aks-nodes-${local.suffix}"
    subnet_aks_apiserver     = "snet-aks-apiserver-${local.suffix}"
    subnet_private_endpoints = "snet-pe-${local.suffix}"
    subnet_dns_resolver_in   = "snet-dnspr-in-${local.suffix}"
    subnet_dns_resolver_out  = "snet-dnspr-out-${local.suffix}"
    subnet_jump_host         = "snet-jump-host-${local.suffix}"
    subnet_browser_jump_host = "snet-browser-jump-host-${local.suffix}"
    # Azure-required fixed names:
    subnet_firewall = "AzureFirewallSubnet"
    subnet_bastion  = "AzureBastionSubnet"

    nsg_aks_nodes         = "nsg-aks-nodes-${local.suffix}"
    nsg_pe                = "nsg-pe-${local.suffix}"
    nsg_jump_host         = "nsg-jump-host-${local.suffix}"
    nsg_browser_jump_host = "nsg-browser-jump-host-${local.suffix}"
    route_table_aks       = "rt-aks-${local.suffix}"
    pip_firewall          = "pip-afw-${local.suffix}"
    pip_bastion           = "pip-bas-${local.suffix}"
    firewall              = "afw-${local.suffix}"
    firewall_policy       = "afwp-${local.suffix}"
    firewall_rcg          = "afwp-rcg-${local.suffix}"
    dns_resolver          = "dnspr-${local.suffix}"
    dns_resolver_in       = "in-dnspr-${local.suffix}"
    dns_resolver_out      = "out-dnspr-${local.suffix}"
    dns_forwarding_rs     = "dnsfwdrs-${local.suffix}"
    bastion               = "bas-${local.suffix}"
    jump_host             = "vm-jump-${local.suffix}"
    browser_jump_host     = substr("vmbrw${local.suffix_alt}", 0, 15)
    aks                   = "aks-${local.suffix}"
    aks_dns_prefix        = "aks-${local.suffix}"
    log_analytics         = "log-${local.suffix}"
    ampls                 = "ampls-${local.suffix}"
    pep_ampls             = "pep-ampls-${local.suffix}"
    user_assigned_id      = "id-anyscale-operator-${local.suffix}"

    # alphanumeric-only (≤ 24 / ≤ 50 chars). Truncate defensively.
    storage_account = substr("st${local.suffix_alt}", 0, 24)
    acr             = substr("cr${local.suffix_alt}", 0, 50)
    key_vault       = substr("kv-${local.suffix}", 0, 24)
  }

  # Private DNS zones used by private endpoints
  private_dns_zones = {
    blob                = "privatelink.blob.core.windows.net"
    dfs                 = "privatelink.dfs.core.windows.net"
    acr                 = "privatelink.azurecr.io"
    vaultcore           = "privatelink.vaultcore.azure.net"
    aks                 = "privatelink.${var.azure_location}.azmk8s.io"
    monitor             = "privatelink.monitor.azure.com"
    oms                 = "privatelink.oms.opinsights.azure.com"
    ods                 = "privatelink.ods.opinsights.azure.com"
    agentsvc            = "privatelink.agentsvc.azure-automation.net"
    anyscale_userdata_i = "i.azure.anyscaleuserdata.com"
    anyscale_userdata_s = "s.azure.anyscaleuserdata.com"
  }

  anyscale_operator_identity_mode                = var.anyscale_operator_identity.mode
  anyscale_operator_identity_created_by_tf       = local.anyscale_operator_identity_mode == "create"
  anyscale_operator_storage_rbac_managed_by_tf   = coalesce(var.anyscale_operator_identity.manage_storage_rbac, local.anyscale_operator_identity_mode != "existing-external-rbac")
  anyscale_operator_storage_role_definition_name = "Storage Blob Data Contributor"

  # Anyscale gateway internal load balancer IP. Pin a HIGH host in the aks_nodes
  # /22 — cidrhost(..., 1019) = the .251 host of the 4th /24 — so it never collides
  # with Azure CNI's bottom-up node/pod IP allocation (which fills from the low
  # end; a low offset like 120 collided with the aks-cpu node NIC and failed the
  # internal LB with PrivateIPAddressIsAllocated). Both the gateway Service
  # annotation (azure-load-balancer-ipv4) and the operator gateway.hostname MUST
  # use this exact value; keep them in sync through this single local. Do NOT lower
  # the offset.
  gateway_internal_lb_ip = cidrhost(var.subnet_cidrs.aks_nodes, 1019)

  resource_group_name     = azurerm_resource_group.this.name
  resource_group_location = azurerm_resource_group.this.location
  resource_group_id       = azurerm_resource_group.this.id

  net_vnet_id                 = module.network.vnet_id
  net_subnet_ids              = module.network.subnet_ids
  net_dns_zone_ids            = module.dns.zone_ids
  net_firewall_private_ip     = module.firewall.firewall_private_ip
  net_dns_resolver_inbound_ip = module.dns_resolver.inbound_endpoint_ip
  net_bastion_id              = module.bastion.bastion_id
  net_bastion_name            = module.bastion.bastion_name
  net_vnet_dns_servers        = azurerm_virtual_network_dns_servers.workload.dns_servers

  jump_host_rbac_scope = var.jump_host_rbac_scope != "" ? var.jump_host_rbac_scope : "/subscriptions/${var.azure_subscription_id}"

  # Once the Anyscale private DNS zone is authoritative for the Anyscale cloud
  # domain inside the VNet, the firewall's outbound FQDN rules for that domain
  # can never match: the private endpoint IP is in-VNet, so the 0.0.0.0/0 route
  # to the firewall does not apply to it. Drop the superseded entries so the
  # allow-list keeps describing the real egress surface instead of carrying an
  # inert wildcard. Everything else in anyscale_fqdns (console/api hosts, the S3
  # asset bucket, etc.) still egresses through the firewall and stays.
  privatelink_superseded_fqdn_suffixes = var.enable_anyscale_privatelink ? [
    var.anyscale_privatelink_dns_zone_name,
  ] : []

  firewall_anyscale_fqdns = [
    for fqdn in var.anyscale_fqdns : fqdn
    if length([
      for suffix in local.privatelink_superseded_fqdn_suffixes : suffix
      if suffix != "" && (fqdn == suffix || endswith(fqdn, ".${suffix}"))
    ]) == 0
  ]
}
