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

output "azure_aks_cluster_name" {
  value       = azurerm_kubernetes_automatic_cluster.aks.name
  description = "Name of the AKS Automatic cluster."
}

output "azure_aks_fqdn" {
  value       = azurerm_kubernetes_automatic_cluster.aks.fully_qualified_domain_name
  description = "API server FQDN of the AKS Automatic cluster."
}

output "azure_aks_oidc_issuer_url" {
  value       = azurerm_kubernetes_automatic_cluster.aks.oidc_issuer_url
  description = "OIDC issuer URL of the AKS cluster (used by workload-identity federation)."
}

output "azure_aks_node_resource_group_id" {
  value       = azurerm_kubernetes_automatic_cluster.aks.node_resource_group_id
  description = "Resource ID of the AKS-managed node resource group (where Karpenter-provisioned VMs and the gateway load balancer live)."
}

output "azure_vnet_id" {
  value       = azurerm_virtual_network.vnet.id
  description = "Resource ID of the VNet holding the API-server, node, and system-node subnets."
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

# The name the Anyscale CLI knows this cloud by is NOT `anyscale_cloud_name` —
# it is the full ARM resource ID, lowercased. Passing the Azure resource name to
# `--cloud` fails with:
#
#   API Exception (404) ... "Cloud with name <name> does not exist."
#
# Verified against a live deployment. Use this output for `anyscale job submit
# --cloud`, `anyscale service deploy --cloud`, etc.
output "anyscale_cloud_cli_name" {
  value       = lower(local.anyscale_cloud_arm_id)
  description = "Cloud name to pass to the Anyscale CLI's --cloud flag (the lowercased ARM resource ID, which is what the control plane registers as the cloud's name)."
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

output "gateway_class_name" {
  value       = local.app_routing_gateway_class_name
  description = "GatewayClass backing the Anyscale gateway. Fixed at `approuting-istio` — the managed Istio implementation AKS Automatic installs."
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
# GPU outputs
###############################################################################
output "gpu_nodepool_names" {
  value       = [for v in local.gpu_nodepool_variants : v.pool_name]
  description = "Karpenter NodePool names rendered from gpu_nodepool_configs (empty on a CPU-only deploy — Automatic's built-in `default` NodePool covers CPU)."
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

output "otlp_logs_endpoint" {
  value       = var.enable_monitoring && var.enable_otlp_app_insights ? azapi_resource.otel_app_insights[0].output.properties.OTLPLogsEndpoint : null
  description = "OTLP logs ingestion endpoint (flat form, matching the upstream awesome-aks outputs)."
}

output "otlp_metrics_endpoint" {
  value       = var.enable_monitoring && var.enable_otlp_app_insights ? azapi_resource.otel_app_insights[0].output.properties.OTLPMetricsEndpoint : null
  description = "OTLP metrics ingestion endpoint (flat form, matching the upstream awesome-aks outputs)."
}

output "otlp_traces_endpoint" {
  value       = var.enable_monitoring && var.enable_otlp_app_insights ? azapi_resource.otel_app_insights[0].output.properties.OTLPTracesEndpoint : null
  description = "OTLP traces ingestion endpoint (flat form, matching the upstream awesome-aks outputs)."
}

###############################################################################
# Convenience commands
#
# Note the `kubelogin convert-kubeconfig` step — AKS Automatic disables local
# accounts, so `az aks get-credentials` on its own produces a kubeconfig that
# kubectl cannot authenticate with until the exec plugin is converted.
###############################################################################
output "aks_get_credentials_command" {
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_automatic_cluster.aks.name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
  description = "Refresh local kubeconfig against the deployed AKS Automatic cluster (includes the required kubelogin conversion)."
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
      location           = local.anyscale_cloud_location
      console_url        = var.anyscale_platform.control_plane_url
      operator_namespace = var.anyscale_operator_namespace
      extension_id       = azurerm_kubernetes_cluster_extension.anyscale_operator.id
    }
    azure = {
      resource_group      = azurerm_resource_group.rg.name
      aks_cluster         = azurerm_kubernetes_automatic_cluster.aks.name
      aks_flavor          = "Automatic"
      aks_fqdn            = azurerm_kubernetes_automatic_cluster.aks.fully_qualified_domain_name
      node_resource_group = azurerm_kubernetes_automatic_cluster.aks.node_resource_group_id
      oidc_issuer_url     = azurerm_kubernetes_automatic_cluster.aks.oidc_issuer_url
      storage_account     = azurerm_storage_account.sa.name
      storage_container   = azurerm_storage_container.blob.name
      acr_login_server    = var.enable_acr ? azurerm_container_registry.acr[0].login_server : null
    }
    operator_identity = {
      client_id    = azurerm_user_assigned_identity.anyscale_operator.client_id
      principal_id = azurerm_user_assigned_identity.anyscale_operator.principal_id
    }
    gateway = {
      hostname                   = local.gateway_hostname
      class_name                 = local.app_routing_gateway_class_name
      certificate_secret         = local.anyscale_gateway_certificate_secret_name
      service_certificate_secret = local.anyscale_gateway_service_certificate_secret_name
    }
    gpu_nodepools = [for v in local.gpu_nodepool_variants : v.pool_name]
    commands = {
      get_credentials = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_automatic_cluster.aks.name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
    }
  })
}
