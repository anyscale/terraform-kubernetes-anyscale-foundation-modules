###############################################################################
# Azure infra outputs
###############################################################################
output "azure_resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "Name of the Azure Resource Group."
}

output "azure_storage_account_name" {
  value       = azurerm_storage_account.sa.name
  description = "Name of the Azure Storage Account (HNS/ADLS Gen2 enabled)."
}

output "azure_storage_container_name" {
  value       = azurerm_storage_container.blob.name
  description = "Name of the Azure Storage Container."
}

output "azure_nfs_storage_account_name" {
  value       = var.enable_nfs ? azurerm_storage_account.nfs[0].name : null
  description = "Name of the optional Azure NFS Storage Account."
}

output "shared_pvc_name" {
  value       = var.enable_shared_pvc ? kubernetes_persistent_volume_claim_v1.shared_pvc[0].metadata[0].name : null
  description = "Name of the shared ReadWriteMany PVC for Ray pods. Null when enable_shared_pvc=false."
}

locals {
  shared_pvc_registration_instructions = <<-EOT
    The PVC "${var.shared_pvc_name}" exists in namespace "${var.anyscale_operator_namespace}",
    but Anyscale does not yet attach it to workloads. There is no `anyscale cloud update` flag
    for this — it is set through the cloud resource YAML. Add to your resources file:

        file_storage:
          persistent_volume_claim: ${var.shared_pvc_name}

    then apply it:

        anyscale cloud update --name ${local.anyscale_cloud_name} --resources-file <file>.yaml

    The resources file must be a COMPLETE cloud resource spec — passing a fragment containing
    only file_storage may clear other fields. Schema: https://docs.anyscale.com/reference/cloud#cloudresource

    Alternatively, skip cloud-wide registration and mount the PVC per workload via
    advanced_instance_config in a compute config.
  EOT
}

output "shared_pvc_registration_instructions" {
  value       = var.enable_shared_pvc ? local.shared_pvc_registration_instructions : null
  description = "How to register the shared PVC with the Anyscale cloud after apply. Null when enable_shared_pvc=false."
}

output "azure_aks_cluster_name" {
  value       = azurerm_kubernetes_cluster.aks.name
  description = "Name of the AKS cluster."
}

output "azure_aks_oidc_issuer_url" {
  value       = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  description = "OIDC issuer URL of the AKS cluster (used by workload-identity federation)."
}

output "acr_login_server" {
  value       = var.enable_acr ? azurerm_container_registry.acr[0].login_server : null
  description = "Login server (e.g. myacr.azurecr.io) for the customer-owned ACR. Null when enable_acr=false."
}

output "anyscale_operator_client_id" {
  value       = azurerm_user_assigned_identity.anyscale_operator.client_id
  description = "Client ID of the Anyscale operator user-assigned managed identity."
}

###############################################################################
# Anyscale Azure-managed cloud outputs
###############################################################################
output "anyscale_cloud_name" {
  value       = local.anyscale_cloud_name
  description = "Name of the registered Anyscale cloud (visible in console.azure.anyscale.com)."
}

output "anyscale_cloud_arm_id" {
  value       = local.anyscale_cloud_arm_id
  description = "Full ARM resource ID of the Anyscale.Platform/clouds resource."
}

output "anyscale_cloud_resource_id" {
  value       = local.anyscale_cloud_resource_id
  description = "Anyscale cloud resource ID (`cldrsrc_…`). Surfaced in the Anyscale console's cloud settings page."
}

output "anyscale_cloud_sso_url" {
  value       = azapi_resource.anyscale_cloud.output.properties.ssoUrl
  description = "SSO URL for the Anyscale cloud."
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
# Gateway outputs
###############################################################################
output "gateway_hostname" {
  value       = local.gateway_hostname
  description = "Hostname registered with the Anyscale control plane. Deterministic DNS-label hostname on the public path; private LB IP when internal_gateway=true."
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
# Observability outputs
###############################################################################
output "azure_monitor_workspace_id" {
  value       = var.enable_monitoring ? azurerm_monitor_workspace.prometheus[0].id : null
  description = "Azure Monitor workspace (managed Prometheus) resource ID. Null when enable_monitoring=false."
}

output "log_analytics_workspace_id" {
  value       = var.enable_monitoring ? azurerm_log_analytics_workspace.logs[0].id : null
  description = "Log Analytics workspace resource ID. Null when enable_monitoring=false."
}

output "otlp_endpoints" {
  value = var.enable_monitoring && var.enable_otlp_app_insights ? {
    logs    = azapi_resource.otel_app_insights[0].output.properties.OTLPLogsEndpoint
    metrics = azapi_resource.otel_app_insights[0].output.properties.OTLPMetricsEndpoint
    traces  = azapi_resource.otel_app_insights[0].output.properties.OTLPTracesEndpoint
  } : null
  description = "OTLP ingestion endpoints for Ray application telemetry. Null unless enable_otlp_app_insights=true."
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
      arm_id             = local.anyscale_cloud_arm_id
      console_url        = var.anyscale_platform.control_plane_url
      operator_namespace = var.anyscale_operator_namespace
      extension_id       = azurerm_kubernetes_cluster_extension.anyscale_operator.id
    }
    azure = {
      resource_group    = azurerm_resource_group.rg.name
      aks_cluster       = azurerm_kubernetes_cluster.aks.name
      oidc_issuer_url   = azurerm_kubernetes_cluster.aks.oidc_issuer_url
      storage_account   = azurerm_storage_account.sa.name
      storage_container = azurerm_storage_container.blob.name
      acr_login_server  = var.enable_acr ? azurerm_container_registry.acr[0].login_server : null
    }
    operator_identity = {
      client_id    = azurerm_user_assigned_identity.anyscale_operator.client_id
      principal_id = azurerm_user_assigned_identity.anyscale_operator.principal_id
    }
    gateway = {
      hostname                   = local.gateway_hostname
      certificate_secret         = local.anyscale_gateway_certificate_secret_name
      service_certificate_secret = local.anyscale_gateway_service_certificate_secret_name
    }
    commands = {
      get_credentials = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing"
    }
  })
}
