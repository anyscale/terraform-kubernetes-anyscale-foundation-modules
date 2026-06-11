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
  value       = var.enable_nfs ? azurerm_storage_account.nfs[0].name : null
  description = "Name of the Azure NFS Storage Account created for the cluster."
}

output "azure_aks_cluster_name" {
  value       = azurerm_kubernetes_cluster.aks.name
  description = "Name of the Azure AKS cluster created for the cluster."
}

output "aks_get_credentials_command" {
  description = "The command to get the AKS cluster credentials."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing"
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
    "--cloud-storage-bucket-name 'abfss://${azurerm_storage_container.blob[0].name}@${azurerm_storage_account.sa[0].name}.dfs.core.windows.net'",
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
    "--set-string global.cloudDeploymentId=<cloud-deployment-id>",
    "--set-string global.controlPlaneURL=${var.anyscale_control_plane_url}",
    "--set-string global.cloudProvider=azure",
    "--set-string global.auth.iamIdentity=${azurerm_user_assigned_identity.anyscale_operator[0].client_id}",
    "--set-string global.auth.audience=api://086bc555-6989-4362-ba30-fded273e432b/.default",
    "--set-string workloads.serviceAccount.name=anyscale-operator",
    "--set networking.gateway.enabled=true",
    "--set-string networking.gateway.name=gateway",
    "--set-string networking.gateway.namespace=${var.anyscale_operator_namespace}",
    "--set-string networking.gateway.apiVersion=gateway.networking.k8s.io/v1",
    "--set-string networking.gateway.hostname=<gateway-lb-address>",
    "--namespace ${var.anyscale_operator_namespace}",
    "--create-namespace",
    "-i"
  ] : []
}

output "helm_upgrade_command" {
  description = "The helm upgrade command for installing the Anyscale operator."
  value       = length(local.helm_upgrade_command_parts) > 0 ? join(" \\\n\t", local.helm_upgrade_command_parts) : null
}

output "pvc_apply_command" {
  description = <<-EOT
    Ready-to-run command to apply the sample Azure Blob CSI PVC manifest with
    placeholders substituted. Only emitted when enable_blob_driver = true.
    Requires the `anyscale-operator` namespace to already exist (the operator
    helm install creates it with --create-namespace).
  EOT
  value = !(var.enable_blob_driver && var.enable_operator_infrastructure) ? null : format(
    "sed -e 's/<storage-account>/%s/g' -e 's/<resource-group>/%s/g' sample-blob-pvc.yaml | kubectl apply -f -",
    azurerm_storage_account.sa[0].name,
    azurerm_resource_group.rg.name,
  )
}
