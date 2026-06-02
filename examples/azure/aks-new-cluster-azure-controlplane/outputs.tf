###############################################################################
# Azure infra outputs (mirrors examples/azure/aks-new_cluster)
###############################################################################
output "azure_resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "Name of the Azure Resource Group."
}

output "azure_storage_account_name" {
  value       = var.enable_operator_infrastructure ? azurerm_storage_account.sa[0].name : null
  description = "Name of the Azure Storage Account."
}

output "azure_storage_container_name" {
  value       = var.enable_operator_infrastructure ? azurerm_storage_container.blob[0].name : null
  description = "Name of the Azure Storage Container."
}

output "azure_nfs_storage_account_name" {
  value       = var.enable_nfs ? azurerm_storage_account.nfs[0].name : null
  description = "Name of the optional Azure NFS Storage Account."
}

output "azure_aks_cluster_name" {
  value       = azurerm_kubernetes_cluster.aks.name
  description = "Name of the AKS cluster."
}

output "azure_aks_oidc_issuer_url" {
  value       = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  description = "OIDC issuer URL of the AKS cluster (used by workload-identity federation)."
}

output "acr_id" {
  value       = var.enable_acr ? azurerm_container_registry.acr[0].id : null
  description = "Full resource ID of the customer-owned ACR. Null when enable_acr=false."
}

output "acr_name" {
  value       = var.enable_acr ? azurerm_container_registry.acr[0].name : null
  description = "Name of the customer-owned ACR. Null when enable_acr=false."
}

output "acr_login_server" {
  value       = var.enable_acr ? azurerm_container_registry.acr[0].login_server : null
  description = "Login server (e.g. myacr.azurecr.io) for the customer-owned ACR. Null when enable_acr=false."
}

output "anyscale_operator_client_id" {
  value       = var.enable_operator_infrastructure ? azurerm_user_assigned_identity.anyscale_operator[0].client_id : null
  description = "Client ID of the Anyscale operator user-assigned managed identity."
}

output "anyscale_operator_principal_id" {
  value       = var.enable_operator_infrastructure ? azurerm_user_assigned_identity.anyscale_operator[0].principal_id : null
  description = "Principal ID of the Anyscale operator user-assigned managed identity."
}

###############################################################################
# Anyscale Azure-managed cloud outputs
###############################################################################
output "anyscale_cloud_name" {
  value       = local.anyscale_cloud_name
  description = "Name of the registered Anyscale cloud (visible in console.azure.anyscale.com)."
}

output "anyscale_cloud_arm_id" {
  value       = "${azurerm_resource_group.rg.id}/providers/Anyscale.Platform/clouds/${local.anyscale_cloud_name}"
  description = "Full ARM resource ID of the Anyscale.Platform/clouds resource."
}

output "anyscale_cloud_resource_id" {
  value       = local.anyscale_cloud_resource_id
  description = "Anyscale cloud resource ID (`cldrsrc_…`). Surfaced in the Anyscale console's cloud settings page."
}

output "anyscale_extension_resource_id" {
  value       = azurerm_kubernetes_cluster_extension.anyscale_operator.id
  description = "Full resource ID of the Anyscale.AKS.Operator AKS extension."
}

output "anyscale_operator_namespace" {
  value       = var.anyscale_operator_namespace
  description = "Kubernetes namespace where the Anyscale operator runs."
}

###############################################################################
# Envoy Gateway outputs
###############################################################################
output "gateway_lb_hostname" {
  value       = data.external.gateway_lb.result.address
  description = "Address (DNS or IP) assigned to the Envoy Gateway LoadBalancer. Baked into the operator extension's networking.gateway.hostname."
}

output "gateway_certificate_secret_name" {
  value       = local.anyscale_gateway_certificate_secret_name
  description = "Name of the TLS Secret the operator creates for `*.i.azure.anyscaleuserdata.com`."
}

output "gateway_service_certificate_secret_name" {
  value       = local.anyscale_gateway_service_certificate_secret_name
  description = "Name of the TLS Secret the operator creates for `*.s.azure.anyscaleuserdata.com`."
}

###############################################################################
# Convenience commands
###############################################################################
output "aks_get_credentials_command" {
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing"
  description = "Refresh local kubeconfig against the deployed AKS cluster."
}

output "anyscale_console_url" {
  value       = var.anyscale_platform.control_plane_url
  description = "URL of the Anyscale console where the registered cloud is visible."
}

###############################################################################
# Deployment summary file
#
# Writes a YAML summary of the deployment to anyscale-aks-cloud.yaml when the
# apply completes. Because the content references the cloud, operator-extension
# and gateway resources, Terraform schedules this write after they exist — so
# the file reflects the finished deployment. The file embeds ARM resource IDs
# (which include the subscription ID), so it is gitignored.
###############################################################################
resource "local_file" "cloud_summary" {
  filename        = "${path.module}/anyscale-aks-cloud.yaml"
  file_permission = "0600"

  content = yamlencode({
    anyscale_cloud = {
      name               = local.anyscale_cloud_name
      resource_id        = local.anyscale_cloud_resource_id
      arm_id             = "${azurerm_resource_group.rg.id}/providers/Anyscale.Platform/clouds/${local.anyscale_cloud_name}"
      console_url        = var.anyscale_platform.control_plane_url
      operator_namespace = var.anyscale_operator_namespace
      extension_id       = azurerm_kubernetes_cluster_extension.anyscale_operator.id
    }
    azure = {
      resource_group    = azurerm_resource_group.rg.name
      aks_cluster       = azurerm_kubernetes_cluster.aks.name
      oidc_issuer_url   = azurerm_kubernetes_cluster.aks.oidc_issuer_url
      storage_account   = var.enable_operator_infrastructure ? azurerm_storage_account.sa[0].name : null
      storage_container = var.enable_operator_infrastructure ? azurerm_storage_container.blob[0].name : null
      acr_login_server  = var.enable_acr ? azurerm_container_registry.acr[0].login_server : null
    }
    operator_identity = {
      client_id    = var.enable_operator_infrastructure ? azurerm_user_assigned_identity.anyscale_operator[0].client_id : null
      principal_id = var.enable_operator_infrastructure ? azurerm_user_assigned_identity.anyscale_operator[0].principal_id : null
    }
    gateway = {
      lb_hostname                = data.external.gateway_lb.result.address
      certificate_secret         = local.anyscale_gateway_certificate_secret_name
      service_certificate_secret = local.anyscale_gateway_service_certificate_secret_name
    }
    commands = {
      get_credentials = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing"
    }
  })
}
