output "azure_resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "Name of the Azure Resource Group created for the cluster."
}

output "azure_storage_account_name" {
  value       = azurerm_storage_account.sa.name
  description = "Name of the Azure Storage Account created for the cluster."
}

output "azure_aks_cluster_name" {
  value       = azurerm_kubernetes_cluster.aks.name
  description = "Name of the Azure AKS cluster created for the cluster."
}

output "anyscale_operator_client_id" {
  value       = azurerm_user_assigned_identity.anyscale_operator.client_id
  description = "Client ID of the Azure User Assigned Identity created for the cluster."
}

data "azurerm_location" "example" {
  location = var.azure_location
}

locals {
  registration_command_parts = compact([
    "anyscale cloud register",
    "--name <anyscale_cloud_name>",
    "--region ${data.azurerm_location.example.location}",
    "--provider azure",
    "--compute-stack k8s",
    "--cloud-storage-bucket-name 'azure://${azurerm_storage_container.blob.name}'",
    "--cloud-storage-bucket-endpoint 'https://${azurerm_storage_account.sa.name}.blob.core.windows.net'",
  ])

  helm_upgrade_command_parts = compact([
    "helm upgrade anyscale-operator anyscale/anyscale-operator",
    "--set-string anyscaleCliToken=<anyscale-cli-token>",
    "--set-string cloudDeploymentId=<cloud-deployment-id>",
    "--set-string cloudProvider=azure",
    "--set-string operatorIamIdentity=${azurerm_user_assigned_identity.anyscale_operator.client_id}",
    "--set-string workloadServiceAccountName=anyscale-operator",
    "--namespace ${var.anyscale_operator_namespace}",
    "--create-namespace",
    "-i"
  ])
}

output "anyscale_registration_command" {
  description = "The Anyscale registration command."
  value       = join(" \\\n\t", local.registration_command_parts)
}

output "helm_upgrade_command" {
  description = "The helm upgrade command."
  value       = join(" \\\n\t", local.helm_upgrade_command_parts)
}
