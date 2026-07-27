###############################################################################
# Resource Group
###############################################################################
resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = var.azure_location
  tags     = var.tags
}

###############################################################################
# Network — VNet + all subnets (Phase 1)
###############################################################################
module "network" {
  source = "./modules/network"

  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  tags                = var.tags

  vnet_name          = local.names.vnet
  vnet_address_space = var.vnet_address_space

  subnet_cidrs = var.subnet_cidrs
  subnet_names = {
    aks_nodes         = local.names.subnet_aks_nodes
    aks_apiserver     = local.names.subnet_aks_apiserver
    dns_resolver_in   = local.names.subnet_dns_resolver_in
    dns_resolver_out  = local.names.subnet_dns_resolver_out
    private_endpoints = local.names.subnet_private_endpoints
    firewall          = local.names.subnet_firewall
    bastion           = local.names.subnet_bastion
    jump_host         = local.names.subnet_jump_host
    browser_jump_host = local.names.subnet_browser_jump_host
  }

  nsg_aks_nodes_name         = local.names.nsg_aks_nodes
  nsg_pe_name                = local.names.nsg_pe
  nsg_jump_host_name         = local.names.nsg_jump_host
  nsg_browser_jump_host_name = local.names.nsg_browser_jump_host
}

###############################################################################
# Private DNS zones (for private endpoints) (Phase 1)
###############################################################################
module "dns" {
  source = "./modules/dns"

  resource_group_name = local.resource_group_name
  zones               = local.private_dns_zones
  vnet_links = {
    workload = local.net_vnet_id
  }
  tags = var.tags
}

resource "azurerm_private_dns_a_record" "anyscale_userdata" {
  for_each = toset(["i", "s"])

  name                = "*"
  zone_name           = module.dns.zone_names["anyscale_userdata_${each.key}"]
  resource_group_name = local.resource_group_name
  ttl                 = 300
  records             = [local.gateway_internal_lb_ip]
}

###############################################################################
# Azure DNS Private Resolver — enterprise DNS path for Private Link + hybrid DNS
###############################################################################
module "dns_resolver" {
  source = "./modules/dns_resolver"

  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  tags                = var.tags

  resolver_name           = local.names.dns_resolver
  inbound_endpoint_name   = local.names.dns_resolver_in
  outbound_endpoint_name  = local.names.dns_resolver_out
  forwarding_ruleset_name = local.names.dns_forwarding_rs

  virtual_network_id  = local.net_vnet_id
  inbound_subnet_id   = local.net_subnet_ids.dns_resolver_in
  outbound_subnet_id  = local.net_subnet_ids.dns_resolver_out
  inbound_endpoint_ip = cidrhost(var.subnet_cidrs.dns_resolver_in, 4)

  forwarding_rules = var.dns_forwarding_rules
  forwarding_ruleset_vnet_links = {
    workload = local.net_vnet_id
  }
}

###############################################################################
# Observability — Log Analytics workspace (Phase 1)
###############################################################################
module "observability" {
  source = "./modules/observability"

  resource_group_name         = local.resource_group_name
  location                    = local.resource_group_location
  log_analytics_name          = local.names.log_analytics
  ampls_name                  = local.names.ampls
  ampls_private_endpoint_name = local.names.pep_ampls
  retention_in_days           = var.log_analytics_retention_days
  internet_ingestion_enabled  = var.log_analytics_internet_ingestion_enabled
  internet_query_enabled      = var.log_analytics_internet_query_enabled
  ampls_enabled               = var.ampls_enabled
  ampls_ingestion_access_mode = var.ampls_ingestion_access_mode
  ampls_query_access_mode     = var.ampls_query_access_mode
  private_endpoint_subnet_id  = local.net_subnet_ids.private_endpoints
  ampls_private_dns_zone_ids = {
    monitor  = local.net_dns_zone_ids["monitor"]
    oms      = local.net_dns_zone_ids["oms"]
    ods      = local.net_dns_zone_ids["ods"]
    agentsvc = local.net_dns_zone_ids["agentsvc"]
    blob     = local.net_dns_zone_ids["blob"]
  }
  tags = var.tags
}

###############################################################################
# Storage — public access disabled, AAD-only, private endpoints (blob, dfs) (Phase 1)
###############################################################################
module "storage" {
  source = "./modules/storage"

  resource_group_name  = local.resource_group_name
  location             = local.resource_group_location
  storage_account_name = local.names.storage_account
  subscription_id      = var.azure_subscription_id
  tenant_id            = var.azure_tenant_id
  container_name       = "${var.project}-${var.environment}-blob"
  replication_type     = var.storage_replication_type
  cors_rule            = var.storage_cors_rule

  pe_subnet_id = local.net_subnet_ids.private_endpoints
  pe_dns_zone_ids = {
    blob = local.net_dns_zone_ids["blob"]
    dfs  = local.net_dns_zone_ids["dfs"]
  }

  log_analytics_workspace_id  = module.observability.log_analytics_workspace_id
  diagnostic_settings_enabled = var.storage_diagnostic_settings_enabled != null ? var.storage_diagnostic_settings_enabled : var.terraform_managed_diagnostic_settings_enabled
  tags                        = var.tags
}

###############################################################################
# Identity — User-assigned MI for Anyscale operator (Phase 1)
# Federated credential is wired in Phase 2 once the AKS OIDC issuer URL exists.
###############################################################################
module "identity" {
  source = "./modules/identity"

  resource_group_name   = local.resource_group_name
  location              = local.resource_group_location
  name                  = local.names.user_assigned_id
  operator_identity     = var.anyscale_operator_identity
  storage_data_scope_id = module.storage.container_id
  tags                  = var.tags
}

###############################################################################
# Azure Firewall — egress lockdown for AKS (Phase 1)
# Docs: https://learn.microsoft.com/azure/aks/limit-egress-traffic
#       https://learn.microsoft.com/azure/aks/outbound-rules-control-egress
###############################################################################
module "firewall" {
  source = "./modules/firewall"

  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  tags                = var.tags

  pip_name             = local.names.pip_firewall
  firewall_name        = local.names.firewall
  firewall_policy_name = local.names.firewall_policy
  rcg_name             = local.names.firewall_rcg

  firewall_subnet_id = local.net_subnet_ids.firewall

  aks_nodes_cidr           = var.subnet_cidrs.aks_nodes
  anyscale_fqdns           = var.anyscale_fqdns
  azure_identity_fqdns     = var.azure_identity_fqdns
  azure_monitor_fqdns      = var.azure_monitor_fqdns
  container_registry_fqdns = var.container_registry_fqdns
  jump_host_cidrs          = [var.subnet_cidrs.jump_host]
  tool_bootstrap_fqdns     = var.tool_bootstrap_fqdns
  dns_proxy_enabled        = true
  dns_servers              = []

  log_analytics_workspace_id  = module.observability.log_analytics_workspace_id
  diagnostic_settings_enabled = var.terraform_managed_diagnostic_settings_enabled
}

resource "azurerm_virtual_network_dns_servers" "workload" {
  virtual_network_id = local.net_vnet_id
  dns_servers        = [local.net_firewall_private_ip]
}

###############################################################################
# Routing — UDR with default route -> Azure Firewall private IP (Phase 2)
# Required by AKS outboundType=userDefinedRouting.
###############################################################################
module "routing" {
  source = "./modules/routing"

  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  tags                = var.tags

  route_table_name    = local.names.route_table_aks
  firewall_private_ip = local.net_firewall_private_ip

  subnet_ids_to_associate = {
    aks_nodes = local.net_subnet_ids.aks_nodes
    jump_host = local.net_subnet_ids.jump_host
  }

  depends_on = [azurerm_virtual_network_dns_servers.workload]
}

###############################################################################
# Azure Container Registry (Premium) + private endpoint (Phase 2)
###############################################################################
module "acr" {
  source = "./modules/acr"

  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  tags                = var.tags

  name           = local.names.acr
  pe_subnet_id   = local.net_subnet_ids.private_endpoints
  pe_dns_zone_id = local.net_dns_zone_ids["acr"]

  zone_redundancy_enabled     = var.acr_zone_redundancy_enabled
  log_analytics_workspace_id  = module.observability.log_analytics_workspace_id
  diagnostic_settings_enabled = var.terraform_managed_diagnostic_settings_enabled
}

###############################################################################
# Azure Bastion (Standard, native client tunneling) (Phase 2)
###############################################################################
module "bastion" {
  source = "./modules/bastion"

  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  tags                = var.tags

  bastion_name = local.names.bastion
  pip_name     = local.names.pip_bastion
  subnet_id    = local.net_subnet_ids.bastion

  log_analytics_workspace_id  = module.observability.log_analytics_workspace_id
  diagnostic_settings_enabled = var.terraform_managed_diagnostic_settings_enabled

  depends_on = [azurerm_virtual_network_dns_servers.workload]
}

###############################################################################
# Linux automation jump host and optional Windows browser host (Phase 2)
###############################################################################
module "jump_host" {
  source = "./modules/jump_host"

  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  tags                = var.tags

  name                 = local.names.jump_host
  subnet_id            = local.net_subnet_ids.jump_host
  vm_size              = var.linux_jump_host_vm_size
  admin_username       = var.linux_jump_host_admin_username
  admin_ssh_public_key = var.linux_jump_host_admin_ssh_public_key
  custom_data          = var.linux_jump_host_custom_data

  depends_on = [module.routing, module.firewall, azurerm_virtual_network_dns_servers.workload]
}

module "browser_jump_host" {
  source = "./modules/browser_jump_host"

  enabled = var.enable_browser_host

  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  tags                = var.tags

  name           = local.names.browser_jump_host
  subnet_id      = local.net_subnet_ids.browser_jump_host
  vm_size        = var.windows_browser_jump_host_vm_size
  admin_username = var.windows_browser_jump_host_admin_username
  admin_password = var.windows_browser_jump_host_admin_password

  vm_user_login_principal_ids  = var.browser_host_vm_user_login_principal_ids
  vm_admin_login_principal_ids = var.browser_host_vm_admin_login_principal_ids

  depends_on = [module.routing, module.firewall, azurerm_virtual_network_dns_servers.workload]
}

resource "azurerm_role_assignment" "jump_host_contributor" {
  count = var.assign_jump_host_subscription_contributor ? 1 : 0

  scope                = local.jump_host_rbac_scope
  role_definition_name = "Contributor"
  principal_id         = module.jump_host.principal_id
}

resource "azurerm_role_assignment" "jump_host_rbac_admin" {
  count = var.assign_jump_host_rbac_admin ? 1 : 0

  scope                = local.jump_host_rbac_scope
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = module.jump_host.principal_id
}

###############################################################################
# Private AKS cluster (Phase 2)
# - Private cluster + API Server VNet integration
# - outboundType = userDefinedRouting (egress via Azure Firewall)
# - Workload identity + federated cred for the Anyscale operator UAMI
# - Container Insights via OMS agent (msi auth)
###############################################################################
module "aks" {
  source = "./modules/aks"

  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  tags                = var.tags

  cluster_name = local.names.aks
  dns_prefix   = local.names.aks_dns_prefix

  azure_tenant_id    = var.azure_tenant_id
  kubernetes_version = var.kubernetes_version
  service_cidr       = var.service_cidr
  dns_service_ip     = var.dns_service_ip

  nodes_subnet_id     = local.net_subnet_ids.aks_nodes
  apiserver_subnet_id = local.net_subnet_ids.aks_apiserver
  private_dns_zone_id = local.net_dns_zone_ids["aks"]

  system_vm_size             = var.system_vm_size
  availability_zones         = var.availability_zones
  sku_tier                   = var.aks_sku_tier
  system_node_pool_min_count = var.system_node_pool_min_count
  system_node_pool_max_count = var.system_node_pool_max_count
  cpu_vm_size                = var.cpu_vm_size
  gpu_pool_configs           = var.gpu_pool_configs

  log_analytics_workspace_id                  = module.observability.log_analytics_workspace_id
  container_insights_v2_enabled               = var.container_insights_v2_enabled
  container_insights_streams                  = var.container_insights_streams
  container_insights_data_collection_interval = var.container_insights_data_collection_interval
  container_insights_namespace_filtering_mode = var.container_insights_namespace_filtering_mode
  container_insights_namespaces               = var.container_insights_namespaces
  ampls_enabled                               = var.ampls_enabled
  ampls_scope_name                            = module.observability.ampls_scope_name
  ampls_resource_group_name                   = local.resource_group_name
  diagnostic_settings_enabled                 = var.terraform_managed_diagnostic_settings_enabled
  anyscale_operator_identity_id               = module.identity.id
  anyscale_operator_namespace                 = var.anyscale_operator_namespace
  anyscale_operator_serviceaccount            = var.anyscale_operator_serviceaccount
  acr_id                                      = module.acr.acr_id
  azure_policy_enabled                        = var.azure_policy_enabled
  automatic_upgrade_channel                   = var.automatic_upgrade_channel
  node_os_upgrade_channel                     = var.node_os_upgrade_channel
  local_account_disabled                      = var.local_account_disabled
  defender_enabled                            = var.defender_enabled
  key_vault_secrets_provider_enabled          = var.key_vault_secrets_provider_enabled

  assign_current_principal_cluster_access = var.assign_current_principal_cluster_access
  cluster_admin_principal_ids = merge(
    var.aks_cluster_admin_principal_ids,
    # The Module 3 bootstrap runs bootstrap-k8s.sh on the Linux jump host, where
    # kubectl authenticates as the jump host's managed identity via Entra
    # (kubelogin -l azurecli). That identity therefore needs the AKS data-plane
    # "RBAC Cluster Admin" role. Terraform may run from the workstation (which
    # grants the workstation principal instead), so grant the jump host MI
    # explicitly whenever it is provisioned with elevated cluster access.
    var.assign_jump_host_subscription_contributor ? {
      jump_host = module.jump_host.principal_id
    } : {}
  )
  cluster_user_principal_ids = var.aks_cluster_user_principal_ids

  # The cluster needs the UDR in place AND the firewall egress allow-list
  # (rule collection group) created before nodes come up — outboundType
  # = userDefinedRouting otherwise blocks all bootstrap traffic.
  depends_on = [module.routing, module.firewall, azurerm_virtual_network_dns_servers.workload]
}

###############################################################################
# Container image signing + verification
# - Key Vault holds the Notation signing certificate (private endpoint only).
# - AKS Image Integrity (Preview) verifies image signatures via Ratify + Azure
#   Policy. Audit-only by design: unsigned images are flagged non-compliant,
#   not blocked.
# Docs:
# - https://learn.microsoft.com/azure/container-registry/container-registry-tutorial-sign-build-push
# - https://learn.microsoft.com/azure/aks/image-integrity
###############################################################################

module "keyvault" {
  source = "./modules/keyvault"

  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  tags                = var.tags

  name           = local.names.key_vault
  tenant_id      = var.azure_tenant_id
  pe_subnet_id   = local.net_subnet_ids.private_endpoints
  pe_dns_zone_id = local.net_dns_zone_ids["vaultcore"]

  purge_protection_enabled   = var.key_vault_purge_protection_enabled
  soft_delete_retention_days = var.key_vault_soft_delete_retention_days

}

module "image_integrity" {
  source = "./modules/image_integrity"

  resource_group_name = local.resource_group_name
  resource_group_id   = local.resource_group_id
  location            = local.resource_group_location
  tags                = var.tags

  name_suffix     = local.suffix
  oidc_issuer_url = module.aks.oidc_issuer_url
}

# Jump host signs images: read the signing certificate + sign with its key.
resource "azurerm_role_assignment" "jump_host_kv_cert_officer" {
  count = var.assign_jump_host_subscription_contributor ? 1 : 0

  scope                = module.keyvault.key_vault_id
  role_definition_name = "Key Vault Certificates Officer"
  principal_id         = module.jump_host.principal_id
}

resource "azurerm_role_assignment" "jump_host_kv_crypto_user" {
  count = var.assign_jump_host_subscription_contributor ? 1 : 0

  scope                = module.keyvault.key_vault_id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = module.jump_host.principal_id
}

resource "azurerm_role_assignment" "jump_host_kv_secrets_user" {
  count = var.assign_jump_host_subscription_contributor ? 1 : 0

  scope                = module.keyvault.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.jump_host.principal_id
}

# Ratify reads the signing certificate chain to verify signatures.
resource "azurerm_role_assignment" "ratify_kv_secrets_user" {
  scope                            = module.keyvault.key_vault_id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = module.image_integrity.ratify_principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# Ratify reads images and Notation signature referrers from the private ACR.
resource "azurerm_role_assignment" "ratify_acr_pull" {
  scope                            = module.acr.acr_id
  role_definition_name             = "AcrPull"
  principal_id                     = module.image_integrity.ratify_principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
