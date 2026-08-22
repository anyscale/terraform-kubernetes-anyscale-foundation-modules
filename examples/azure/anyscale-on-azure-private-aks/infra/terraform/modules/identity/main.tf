###############################################################################
# User-assigned managed identity for the Anyscale operator
# Federated identity credential is created in the AKS module (Phase 2) once
# the OIDC issuer URL is known.
###############################################################################
locals {
  mode                  = var.operator_identity.mode
  create_identity       = local.mode == "create"
  manage_storage_rbac   = coalesce(var.operator_identity.manage_storage_rbac, local.mode != "existing-external-rbac")
  storage_role_name     = "Storage Blob Data Contributor"
  existing_name_from_id = try(regex("[^/]+$", var.operator_identity.id), null)

  identity_id           = local.create_identity ? azurerm_user_assigned_identity.this[0].id : var.operator_identity.id
  identity_client_id    = local.create_identity ? azurerm_user_assigned_identity.this[0].client_id : var.operator_identity.client_id
  identity_principal_id = local.create_identity ? azurerm_user_assigned_identity.this[0].principal_id : var.operator_identity.principal_id
  identity_name         = local.create_identity ? azurerm_user_assigned_identity.this[0].name : coalesce(var.operator_identity.name, local.existing_name_from_id)
}

resource "azurerm_user_assigned_identity" "this" {
  count = local.create_identity ? 1 : 0

  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "blob_contrib" {
  count = local.manage_storage_rbac ? 1 : 0

  scope                = var.storage_data_scope_id
  role_definition_name = local.storage_role_name
  principal_id         = local.identity_principal_id
  principal_type       = "ServicePrincipal"
  # Workload identity principals can be immediately valid for RBAC even while the
  # matching service principal object is still replicating through Entra ID.
  skip_service_principal_aad_check = true
  description                      = "Anyscale operator workload identity read/write access to the default storage container."
}
