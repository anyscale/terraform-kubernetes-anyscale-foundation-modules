output "id" {
  value = local.identity_id
}

output "client_id" {
  value = local.identity_client_id
}

output "principal_id" {
  value = local.identity_principal_id
}

output "name" {
  value = local.identity_name
}

output "storage_access" {
  description = "Storage data-plane RBAC assigned to the Anyscale operator managed identity."
  value = {
    mode                 = local.mode
    created_by_terraform = local.create_identity
    managed_by_terraform = local.manage_storage_rbac
    role_assignment_id   = local.manage_storage_rbac ? azurerm_role_assignment.blob_contrib[0].id : null
    principal_id         = local.identity_principal_id
    principal_type       = "ServicePrincipal"
    role_definition_name = local.storage_role_name
    scope                = var.storage_data_scope_id
  }
}
