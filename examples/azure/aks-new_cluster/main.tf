locals {
  vnet_cidr         = "10.42.0.0/16"
  nodes_subnet_cidr = "10.42.1.0/24"
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
# storage (blob)
############################################
resource "azurerm_storage_account" "sa" {

  #checkov:skip=CKV_AZURE_33: "Ensure Storage logging is enabled for Queue service for read, write and delete requests"
  #checkov:skip=CKV_AZURE_59: "Ensure that Storage accounts disallow public access"
  #checkov:skip=CKV_AZURE_244: "Avoid the use of local users for Azure Storage unless necessary"
  #checkov:skip=CKV_AZURE_44: "Ensure Storage Account is using the latest version of TLS encryption"
  #checkov:skip=CKV_AZURE_206: "Ensure that Storage Accounts use replication"
  #checkov:skip=CKV2_AZURE_41: "Ensure storage account is configured with SAS expiration policy"
  #checkov:skip=CKV2_AZURE_38: "Ensure soft-delete is enabled on Azure storage account"
  #checkov:skip=CKV2_AZURE_1: "Ensure storage for critical data are encrypted with Customer Managed Key"
  #checkov:skip=CKV2_AZURE_33: "Ensure storage account is configured with private endpoint"
  #checkov:skip=CKV2_AZURE_40: "Ensure storage account is not configured with Shared Key authorization"
  #checkov:skip=CKV2_AZURE_21: "Ensure Storage logging is enabled for Blob service for read requests"
  #checkov:skip=CKV2_AZURE_31: "Ensure VNET subnet is configured with a Network Security Group (NSG)"

  name                     = replace("${var.aks_cluster_name}sa", "-", "") # demo-aks --> demoakssa
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # still blocks "anonymous blob" catches
  allow_nested_items_to_be_public = false
  tags                            = var.tags

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
# networking (vnet and subnet)
############################################
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.aks_cluster_name}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [local.vnet_cidr]
  tags                = var.tags
}

# Subnet for AKS nodes
resource "azurerm_subnet" "nodes" {

  #checkov:skip=CKV2_AZURE_31: "Ensure VNET subnet is configured with a Network Security Group (NSG)"

  name                 = "aks-nodes"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [local.nodes_subnet_cidr]
}
