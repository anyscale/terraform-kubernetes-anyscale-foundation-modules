###############################################################################
# Azure infrastructure
###############################################################################
output "azure_resource_group_name" {
  description = "Name of the resource group."
  value       = azurerm_resource_group.rg.name
}

output "azure_aks_cluster_name" {
  description = "Name of the AKS cluster."
  value       = azurerm_kubernetes_cluster.aks.name
}

output "azure_aks_oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster, used by workload identity federation."
  value       = azurerm_kubernetes_cluster.aks.oidc_issuer_url
}

output "azure_storage_account_name" {
  description = "Name of the ADLS Gen2 storage account."
  value       = azurerm_storage_account.sa.name
}

output "azure_storage_container_name" {
  description = "Name of the blob container backing the Anyscale cloud storage."
  value       = azurerm_storage_container.blob.name
}

output "azure_nfs_storage_account_name" {
  description = "Name of the optional NFS storage account, or null when enable_nfs is false."
  value       = var.enable_nfs ? azurerm_storage_account.nfs[0].name : null
}

output "acr_login_server" {
  description = "Login server for the private ACR, or null when enable_acr is false."
  value       = var.enable_acr ? azurerm_container_registry.acr[0].login_server : null
}

output "anyscale_operator_client_id" {
  description = "Client ID of the operator's user-assigned managed identity. Used as global.auth.iamIdentity."
  value       = azurerm_user_assigned_identity.anyscale_operator.client_id
}

output "anyscale_operator_principal_id" {
  description = "Principal (object) ID of the operator's managed identity. Used as --anyscale-operator-iam-identity."
  value       = azurerm_user_assigned_identity.anyscale_operator.principal_id
}

###############################################################################
# Values consumed by the ARM registration flow
#
# The Anyscale cloud and the operator are BOTH created through ARM
# (Anyscale.Platform/clouds + the Anyscale.AKS.Operator cluster extension),
# outside this example. Terraform's job here is the Azure infrastructure - but
# several of the values that flow needs exist only because Terraform created
# them, so they are surfaced below rather than left to be looked up by hand.
#
# There is deliberately no `anyscale cloud register` or `helm upgrade` output:
# neither path is used when registration and the operator come from ARM.
###############################################################################
data "azurerm_location" "current" {
  location = var.azure_location
}

output "anyscale_cloud_registration_values" {
  description = "Values for the Anyscale.Platform/clouds + cloudResources ARM resources."
  value = {
    region        = data.azurerm_location.current.location
    tenant_id     = var.azure_tenant_id
    compute_stack = "K8S"
    provider_name = "Azure"

    # cloudResources.properties.anyscaleOperatorIamIdentity
    anyscale_operator_iam_identity = azurerm_user_assigned_identity.anyscale_operator.principal_id

    # cloudResources.properties.cloudStorageBucketName / …BucketEndpoint.
    # Both forms are required: the abfss:// URI addresses the container as ADLS
    # Gen2 over the dfs endpoint, the other is the blob endpoint. That is also
    # why storage.tf creates BOTH a blob and a dfs private endpoint.
    cloud_storage_bucket_name     = "abfss://${azurerm_storage_container.blob.name}@${azurerm_storage_account.sa.name}.dfs.core.windows.net"
    cloud_storage_bucket_endpoint = "https://${azurerm_storage_account.sa.name}.blob.core.windows.net"

    # clouds.properties.acrResourceId - the registry the operator's image
    # builder pushes cluster-environment images to.
    acr_resource_id = var.enable_acr ? azurerm_container_registry.acr[0].id : null
  }
}

output "anyscale_operator_extension_settings" {
  description = <<-EOT
    configuration_settings for the Anyscale.AKS.Operator cluster extension.

    `global.cloudDeploymentId` is deliberately absent - it is returned BY cloud
    registration, so Terraform cannot know it. Add it alongside these when
    creating the extension.
  EOT
  value = {
    "global.controlPlaneURL"        = var.anyscale_control_plane_url
    "global.auth.iamIdentity"       = azurerm_user_assigned_identity.anyscale_operator.client_id
    "global.auth.audience"          = var.anyscale_auth_audience
    "workloads.serviceAccount.name" = var.anyscale_operator_serviceaccount
  }
}

output "aks_command_invoke_example" {
  description = "How to run kubectl or helm against the private API server."
  value = join(" ", [
    "az aks command invoke",
    "--resource-group ${azurerm_resource_group.rg.name}",
    "--name ${azurerm_kubernetes_cluster.aks.name}",
    "--command 'kubectl get nodes'",
  ])
}

output "aks_get_credentials_command" {
  description = "Fetch a kubeconfig. Only usable from inside the VNet or a peered network with the AKS private DNS zone linked."
  value = join(" ", [
    "az aks get-credentials",
    "--resource-group ${azurerm_resource_group.rg.name}",
    "--name ${azurerm_kubernetes_cluster.aks.name}",
    "--overwrite-existing",
  ])
}
