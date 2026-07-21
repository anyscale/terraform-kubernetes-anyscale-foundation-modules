###############################################################################
# MANAGED IDENTITY FOR ANYSCALE OPERATOR
#
# The operator authenticates to the Anyscale control plane via Microsoft
# Entra workload identity: a user-assigned identity federated to the AKS
# OIDC issuer, bound to the operator's Kubernetes service account.
###############################################################################
resource "azurerm_user_assigned_identity" "anyscale_operator" {
  name                = "${var.aks_cluster_name}-anyscale-operator-mi"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

###############################################################################
# FEDERATED‑IDENTITY CREDENTIAL  (ServiceAccount --> User‑Assigned Identity)
###############################################################################
resource "azurerm_federated_identity_credential" "anyscale_operator_fic" {
  name                = "anyscale-operator-fic"
  resource_group_name = azurerm_resource_group.rg.name

  parent_id = azurerm_user_assigned_identity.anyscale_operator.id # user assigned identity
  issuer    = azurerm_kubernetes_cluster.aks.oidc_issuer_url      # OIDC issuer from AKS
  subject   = "system:serviceaccount:${var.anyscale_operator_namespace}:${var.anyscale_operator_serviceaccount}"
  audience  = ["api://AzureADTokenExchange"] # fixed value for AAD tokens
}

###############################################################################
# ROLE ASSIGNMENTS (IDENTITY ←→ STORAGE ACCOUNT)
###############################################################################
resource "azurerm_role_assignment" "anyscale_blob_contrib" {
  scope                            = azurerm_storage_account.sa.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_user_assigned_identity.anyscale_operator.principal_id
  skip_service_principal_aad_check = true
}
