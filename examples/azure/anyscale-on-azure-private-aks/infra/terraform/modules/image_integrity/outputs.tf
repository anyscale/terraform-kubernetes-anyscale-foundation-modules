output "ratify_client_id" {
  description = "Client ID of the Ratify workload identity (used in the Ratify Store/KMP CRDs)."
  value       = azurerm_user_assigned_identity.ratify.client_id
}

output "ratify_principal_id" {
  description = "Principal (object) ID of the Ratify workload identity (granted Key Vault read access)."
  value       = azurerm_user_assigned_identity.ratify.principal_id
}

output "policy_assignment_id" {
  value = azurerm_resource_group_policy_assignment.image_integrity.id
}
