###############################################################################
# Anyscale cloud storage - ADLS Gen2, reached over private endpoints.
#
# This is the Azure counterpart of the S3 bucket (and optional EFS file system)
# in examples/aws/eks-private-cpu.
#
# HNS is enabled so the container is addressable as ADLS Gen2 over abfss://,
# which is the form the Anyscale cloud registration expects. That is also why
# BOTH a blob and a dfs private endpoint are created: registration references
# `abfss://<container>@<account>.dfs.core.windows.net` for data and
# `https://<account>.blob.core.windows.net` as the endpoint. Create only one and
# half the traffic still leaves the VNet.
###############################################################################

locals {
  storage_account_name_base = replace(var.aks_cluster_name, "-", "")

  # Storage account names are globally unique, lowercase alphanumeric, and
  # capped at 24 characters. Reserve 2 for "sa" plus 5 for the shared suffix,
  # leaving 17 for the base.
  storage_account_name = coalesce(
    var.storage_account_name,
    "${substr(local.storage_account_name_base, 0, 17)}sa${local.name_suffix}"
  )

  # Reserve 3 for "nfs" plus 5 for the suffix, leaving 16 for the base.
  storage_account_name_nfs = coalesce(
    var.storage_account_name_nfs,
    "${substr(local.storage_account_name_base, 0, 16)}nfs${local.name_suffix}"
  )

  # One zone per subresource. The `file` zone only exists when NFS is enabled.
  storage_private_dns_zones = merge(
    {
      blob = "privatelink.blob.core.windows.net"
      dfs  = "privatelink.dfs.core.windows.net"
    },
    var.enable_nfs ? { file = "privatelink.file.core.windows.net" } : {}
  )
}

###############################################################################
# Private DNS zones.
#
# Linked to the VNet, so these names resolve to private IPs from inside the
# VNet and continue to resolve publicly from anywhere else. That split is what
# lets the Anyscale UI keep reading logs from a browser while cluster traffic
# stays internal - provided the public endpoint is left enabled.
###############################################################################
resource "azurerm_private_dns_zone" "storage" {
  for_each = local.storage_private_dns_zones

  name                = each.value
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage" {
  for_each = local.storage_private_dns_zones

  name                  = "${var.aks_cluster_name}-${each.key}"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.storage[each.key].name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
  tags                  = var.tags
}

###############################################################################
# Storage account and container.
###############################################################################
#trivy:ignore:avd-azu-0010
resource "azurerm_storage_account" "sa" {
  #checkov:skip=CKV_AZURE_33: "Ensure Storage logging is enabled for Queue service for read, write and delete requests"
  #checkov:skip=CKV_AZURE_59: "Ensure that Storage accounts disallow public access"
  #checkov:skip=CKV_AZURE_244: "Avoid the use of local users for Azure Storage unless necessary"
  #checkov:skip=CKV_AZURE_206: "Ensure that Storage Accounts use replication"
  #checkov:skip=CKV2_AZURE_41: "Ensure storage account is configured with SAS expiration policy"
  #checkov:skip=CKV2_AZURE_38: "Ensure soft-delete is enabled on Azure storage account"
  #checkov:skip=CKV2_AZURE_1: "Ensure storage for critical data are encrypted with Customer Managed Key"
  #checkov:skip=CKV2_AZURE_40: "Ensure storage account is not configured with Shared Key authorization"
  #checkov:skip=CKV2_AZURE_21: "Ensure Storage logging is enabled for Blob service for read requests"

  name                = local.storage_account_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  access_tier              = "Hot"

  is_hns_enabled                  = true
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  # Reached over the blob/dfs private endpoints below. See the variable docs for
  # what turning the public endpoint off costs you - principally, log viewing in
  # the Anyscale UI, which fetches blobs directly from the browser.
  public_network_access_enabled = var.storage_public_network_access_enabled

  blob_properties {
    cors_rule {
      allowed_headers    = var.cors_rule.allowed_headers
      allowed_methods    = var.cors_rule.allowed_methods
      allowed_origins    = var.cors_rule.allowed_origins
      exposed_headers    = var.cors_rule.expose_headers
      max_age_in_seconds = var.cors_rule.max_age_in_seconds
    }
  }

  tags = var.tags
}

# Keyed by storage_account_id rather than storage_account_name, which routes
# creation through the Resource Manager API instead of the storage data plane -
# so this still works with the public endpoint disabled and Terraform running
# outside the VNet.
resource "azurerm_storage_container" "blob" {
  #checkov:skip=CKV2_AZURE_21: "Ensure Storage logging is enabled for Blob service for read requests"

  name                  = "${var.aks_cluster_name}-blob"
  storage_account_id    = azurerm_storage_account.sa.id
  container_access_type = "private"
}

# The private_dns_zone_group registers the A record automatically, so there is
# no hand-written record to drift from the endpoint's actual IP.
resource "azurerm_private_endpoint" "storage" {
  for_each = toset(["blob", "dfs"])

  name                = "${var.aks_cluster_name}-sa-${each.key}-pe"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${var.aks_cluster_name}-sa-${each.key}"
    private_connection_resource_id = azurerm_storage_account.sa.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage[each.key].id]
  }

  tags = var.tags
}

###############################################################################
# Private endpoint to the ANYSCALE-owned storage account (optional).
#
# The service tag rule in main.tf can only say "any storage account in this
# region". This narrows it to the one specific account, and keeps the traffic
# inside the VNet entirely.
#
# Cross-subscription, so `is_manual_connection = true` - the account's owner has
# to approve the request and the endpoint sits Pending until they do.
#
# The record lands in the same privatelink.blob.core.windows.net zone this
# example already creates. Because that zone is authoritative for the whole
# domain inside the VNet, any other *.blob.core.windows.net name the cluster
# needs will also require a record here once this is on.
###############################################################################
locals {
  anyscale_storage_account_id = var.anyscale_storage_account == null ? null : join("", [
    "/subscriptions/", var.anyscale_storage_account.subscription_id,
    "/resourceGroups/", var.anyscale_storage_account.resource_group_name,
    "/providers/Microsoft.Storage/storageAccounts/", var.anyscale_storage_account.name,
  ])
}

resource "azurerm_private_endpoint" "anyscale_storage" {
  count = var.enable_anyscale_storage_private_endpoint ? 1 : 0

  name                = "${var.aks_cluster_name}-anyscale-sa-pe"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${var.aks_cluster_name}-anyscale-sa"
    private_connection_resource_id = local.anyscale_storage_account_id
    subresource_names              = ["blob"]
    is_manual_connection           = true
    request_message                = "Anyscale image and dependency access for AKS cluster ${var.aks_cluster_name}"
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage["blob"].id]
  }

  tags = var.tags
}

###############################################################################
# Shared filesystem - Premium Files with NFS 4.1 (optional).
#
# The rough Azure equivalent of the EFS file system in the AWS examples.
###############################################################################
resource "azurerm_storage_account" "nfs" {
  count = var.enable_nfs ? 1 : 0

  #checkov:skip=CKV_AZURE_33: "Ensure Storage logging is enabled for Queue service"
  #checkov:skip=CKV_AZURE_44: "Ensure Storage Account is using the latest version of TLS encryption"
  #checkov:skip=CKV2_AZURE_41: "Ensure storage account is configured with SAS expiration policy"

  name                = local.storage_account_name_nfs
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  account_kind             = "FileStorage"
  account_tier             = "Premium"
  account_replication_type = "ZRS"

  # NFS shares are mounted without TLS, so HTTPS-only must be off.
  https_traffic_only_enabled      = false
  allow_nested_items_to_be_public = false

  # Reached over the file private endpoint below.
  public_network_access_enabled = false

  tags = var.tags
}

resource "azurerm_private_endpoint" "nfs" {
  count = var.enable_nfs ? 1 : 0

  name                = "${var.aks_cluster_name}-nfs-pe"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${var.aks_cluster_name}-nfs"
    private_connection_resource_id = azurerm_storage_account.nfs[0].id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage["file"].id]
  }

  tags = var.tags
}
