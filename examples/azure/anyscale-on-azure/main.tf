###############################################################################
# Global-uniqueness suffix
#
# Storage accounts and container registries share a *global* DNS namespace
# across all of Azure, so a generic name like `anyscaledemosa` derived from the
# default `aks_cluster_name` is almost guaranteed to collide with another
# tenant's deployment. Append a short random suffix when the user has not
# supplied an explicit override.
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
  name_suffix               = random_string.name_suffix.result
  storage_account_name_base = replace(var.aks_cluster_name, "-", "")
  # 24-char limit on storage account names. Reserve 2 for "sa" + 5 for suffix = 17 chars for the base.
  storage_account_name_base_sa = length(local.storage_account_name_base) > 17 ? substr(local.storage_account_name_base, 0, 17) : local.storage_account_name_base
  # Reserve 3 for "nfs" + 5 for suffix = 16 chars for the base.
  storage_account_name_base_nfs = length(local.storage_account_name_base) > 16 ? substr(local.storage_account_name_base, 0, 16) : local.storage_account_name_base
  storage_account_name          = coalesce(var.storage_account_name, "${local.storage_account_name_base_sa}sa${local.name_suffix}")
  storage_account_name_nfs      = coalesce(var.storage_account_name_nfs, "${local.storage_account_name_base_nfs}nfs${local.name_suffix}")
}

############################################
# resource group
############################################
resource "azurerm_resource_group" "rg" {
  name     = coalesce(var.azure_resource_group_name, "${var.aks_cluster_name}-rg")
  location = var.azure_location
  tags     = var.tags
}

############################################
# storage (blob / ADLS Gen2)
#
# HNS is enabled (from the awesome-aks demo) so the container is addressable
# as ADLS Gen2 via abfss:// — the Anyscale cloud resource registers the
# bucket with the dfs endpoint (see anyscale.tf).
############################################
resource "azurerm_storage_account" "sa" {

  #checkov:skip=CKV_AZURE_33: "Ensure Storage logging is enabled for Queue service for read, write and delete requests"
  #checkov:skip=CKV_AZURE_59: "Ensure that Storage accounts disallow public access"
  #checkov:skip=CKV_AZURE_244: "Avoid the use of local users for Azure Storage unless necessary"
  #checkov:skip=CKV_AZURE_206: "Ensure that Storage Accounts use replication"
  #checkov:skip=CKV2_AZURE_41: "Ensure storage account is configured with SAS expiration policy"
  #checkov:skip=CKV2_AZURE_38: "Ensure soft-delete is enabled on Azure storage account"
  #checkov:skip=CKV2_AZURE_1: "Ensure storage for critical data are encrypted with Customer Managed Key"
  #checkov:skip=CKV2_AZURE_33: "Ensure storage account is configured with private endpoint"
  #checkov:skip=CKV2_AZURE_40: "Ensure storage account is not configured with Shared Key authorization"
  #checkov:skip=CKV2_AZURE_21: "Ensure Storage logging is enabled for Blob service for read requests"

  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  access_tier              = "Hot"

  # hardening grafted from the awesome-aks demo
  is_hns_enabled                  = true
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false

  tags = var.tags

  blob_properties {
    cors_rule {
      allowed_headers    = var.cors_rule.allowed_headers
      allowed_methods    = var.cors_rule.allowed_methods
      allowed_origins    = var.cors_rule.allowed_origins
      exposed_headers    = var.cors_rule.expose_headers
      max_age_in_seconds = var.cors_rule.max_age_in_seconds
    }
  }
}

# Storage bucket (similar to S3)
resource "azurerm_storage_container" "blob" {

  #checkov:skip=CKV2_AZURE_21: "Ensure Storage logging is enabled for Blob service for read requests"

  name                  = "${var.aks_cluster_name}-blob"
  storage_account_id    = azurerm_storage_account.sa.id
  container_access_type = "private" # blobs are private but reachable via the public endpoint
}

############################################
# storage (nfs) - optional
############################################
resource "azurerm_storage_account" "nfs" {
  count = var.enable_nfs ? 1 : 0

  name                       = local.storage_account_name_nfs
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  account_kind               = "FileStorage"
  account_tier               = "Premium"
  account_replication_type   = "ZRS"
  https_traffic_only_enabled = false

  allow_nested_items_to_be_public = false

  network_rules {
    default_action             = "Deny"
    virtual_network_subnet_ids = [azurerm_subnet.nodes.id]
    bypass                     = ["AzureServices"]
  }

  tags = var.tags
}

############################################
# networking (vnet and subnet)
#
# Customer-owned VNet is deliberate: it is the prerequisite for every
# production hardening step (private endpoints, internal gateway LB,
# private API server). With Azure CNI overlay (aks.tf), pods do NOT consume
# IPs from this subnet, so it only needs to be sized for nodes.
############################################
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.aks_cluster_name}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

# Subnet for AKS nodes
resource "azurerm_subnet" "nodes" {

  #checkov:skip=CKV2_AZURE_31: "Ensure VNET subnet is configured with a Network Security Group (NSG)"

  name                 = "aks-nodes"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.nodes_subnet_cidr]
  service_endpoints    = ["Microsoft.Storage"]
}
