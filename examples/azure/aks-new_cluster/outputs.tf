output "azure_resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "Name of the Azure Resource Group created for the cluster."
}

output "azure_storage_account_name" {
  value       = var.enable_operator_infrastructure ? azurerm_storage_account.sa[0].name : null
  description = "Name of the Azure Storage Account created for the cluster."
}

output "azure_storage_container_name" {
  value       = var.enable_operator_infrastructure ? azurerm_storage_container.blob[0].name : null
  description = "Name of the Azure Storage Container created for the cluster."
}

output "azure_nfs_storage_account_name" {
  value       = var.enable_nfs ? azurerm_storage_account.nfs["enabled"].name : null
  description = "Name of the Azure NFS Storage Account created for the cluster."
}

output "azure_aks_cluster_name" {
  value       = azurerm_kubernetes_cluster.aks.name
  description = "Name of the Azure AKS cluster created for the cluster."
}

output "anyscale_operator_client_id" {
  value       = var.enable_operator_infrastructure ? azurerm_user_assigned_identity.anyscale_operator[0].client_id : null
  description = "Client ID of the Azure User Assigned Identity created for the cluster."
}

output "anyscale_operator_principal_id" {
  value       = var.enable_operator_infrastructure ? azurerm_user_assigned_identity.anyscale_operator[0].principal_id : null
  description = "Principal ID of the Azure User Assigned Identity created for the cluster."
}

data "azurerm_location" "example" {
  location = var.azure_location
}

locals {
  registration_command_parts = var.enable_operator_infrastructure ? compact([
    "anyscale cloud register",
    "--name <anyscale_cloud_name>",
    "--region ${data.azurerm_location.example.location}",
    "--provider azure",
    "--compute-stack k8s",
    "--azure-tenant-id ${var.azure_tenant_id}",
    "--anyscale-operator-iam-identity ${azurerm_user_assigned_identity.anyscale_operator[0].principal_id}",
    "--cloud-storage-bucket-name 'azure://${azurerm_storage_container.blob[0].name}'",
    "--cloud-storage-bucket-endpoint 'https://${azurerm_storage_account.sa[0].name}.blob.core.windows.net'",
  ]) : []
}

output "anyscale_registration_command" {
  description = "The Anyscale registration command."
  value       = length(local.registration_command_parts) > 0 ? join(" \\\n\t", local.registration_command_parts) : null
}

locals {
  helm_upgrade_command_parts = var.enable_operator_infrastructure ? [
    "helm upgrade anyscale-operator anyscale/anyscale-operator",
    "--set-string anyscaleCliToken=<anyscale-cli-token>",
    "--set-string cloudDeploymentId=<cloud-deployment-id>",
    "--set-string cloudProvider=azure",
    "--set-string operatorIamIdentity=${azurerm_user_assigned_identity.anyscale_operator[0].client_id}",
    "--set-string workloadServiceAccountName=anyscale-operator",
    "--namespace ${var.anyscale_operator_namespace}",
    "--create-namespace",
    "-i"
  ] : []
}

output "helm_upgrade_command" {
  description = "The helm upgrade command for installing the Anyscale operator."
  value       = length(local.helm_upgrade_command_parts) > 0 ? join(" \\\n\t", local.helm_upgrade_command_parts) : null
}
