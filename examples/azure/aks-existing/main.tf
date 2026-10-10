# ---------------------------------------------------------------------------------------------------------------------
# Example Anyscale K8s Resources - Existing AKS Cluster
#   This template creates resources for Anyscale on an existing Azure AKS cluster.
#
#   It assumes the following already exist:
#     - Resource Group
#     - VNet and Subnet
#     - AKS Cluster (with OIDC issuer and workload identity enabled)
#     - Node pools with appropriate taints and labels
#
#   It creates:
#     - Storage Account
#     - Storage Container (Blob)
#     - User Assigned Managed Identity
#     - Federated Identity Credential
#     - Role Assignment (Storage Blob Data Contributor)
# ---------------------------------------------------------------------------------------------------------------------

############################################
# Data sources for existing resources
############################################
data "azurerm_resource_group" "existing" {
  name = var.existing_resource_group_name
}

data "azurerm_kubernetes_cluster" "existing" {
  name                = var.existing_aks_cluster_name
  resource_group_name = data.azurerm_resource_group.existing.name
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

  name                     = replace("${var.anyscale_cloud_name}sa", "-", "") # anyscale-demo --> anyscaledemo
  resource_group_name      = data.azurerm_resource_group.existing.name
  location                 = data.azurerm_resource_group.existing.location
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

  name                  = "${var.anyscale_cloud_name}-blob"
  storage_account_id    = azurerm_storage_account.sa.id
  container_access_type = "private" # blobs are private but reachable via the public endpoint
}

##############################################################################
# MANAGED IDENTITY FOR ANYSCALE OPERATOR
###############################################################################
resource "azurerm_user_assigned_identity" "anyscale_operator" {
  name                = "${var.anyscale_cloud_name}-anyscale-operator-mi"
  location            = data.azurerm_resource_group.existing.location
  resource_group_name = data.azurerm_resource_group.existing.name
}

###############################################################################
# FEDERATED-IDENTITY CREDENTIAL (ServiceAccount --> User-Assigned Identity)
###############################################################################
resource "azurerm_federated_identity_credential" "anyscale_operator_fic" {
  name                = "anyscale-operator-fic"
  resource_group_name = data.azurerm_resource_group.existing.name

  parent_id = azurerm_user_assigned_identity.anyscale_operator.id # user assigned identity
  issuer    = data.azurerm_kubernetes_cluster.existing.oidc_issuer_url
  subject   = "system:serviceaccount:${var.anyscale_operator_namespace}:anyscale-operator"
  audience  = ["api://AzureADTokenExchange"] # fixed value for AAD tokens
}

###############################################################################
# ROLE ASSIGNMENTS (IDENTITY <-> STORAGE ACCOUNT)
###############################################################################
resource "azurerm_role_assignment" "anyscale_blob_contrib" {
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.anyscale_operator.principal_id
}
