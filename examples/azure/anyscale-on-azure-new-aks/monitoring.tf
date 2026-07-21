###############################################################################
# Observability workspaces (ported from the awesome-aks demo).
#
# - Azure Monitor workspace: destination for AKS managed-Prometheus metrics
#   (data-collection wiring in prometheus.tf).
# - Log Analytics workspace: destination for Container Insights (the omsagent
#   addon on the cluster in aks.tf).
# - App Insights with OTLP endpoints (opt-in, PREVIEW API): ingestion targets
#   for Ray application logs/metrics/traces.
###############################################################################

resource "azurerm_monitor_workspace" "prometheus" {
  count = var.enable_monitoring ? 1 : 0

  name                = "metrics-${var.aks_cluster_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "azurerm_log_analytics_workspace" "logs" {
  count = var.enable_monitoring ? 1 : 0

  name                = "logs-${var.aks_cluster_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  retention_in_days   = var.log_analytics_retention_days
  sku                 = "PerGB2018"
  tags                = var.tags
}

###############################################################################
# Application Insights with OTLP ingestion (PREVIEW Microsoft.Insights API).
# Exports the OTLP logs/metrics/traces endpoints for Ray telemetry pipelines.
###############################################################################
resource "azapi_resource" "otel_app_insights" {
  count = var.enable_monitoring && var.enable_otlp_app_insights ? 1 : 0

  type      = "Microsoft.Insights/components@2025-01-23-preview"
  name      = "otel-${var.aks_cluster_name}"
  parent_id = azurerm_resource_group.rg.id
  location  = azurerm_resource_group.rg.location

  # required while the azapi local schema catalog lags the preview API version
  schema_validation_enabled = false

  body = {
    kind = "web"
    properties = {
      ApplicationId                      = "otel-${var.aks_cluster_name}"
      Application_Type                   = "web"
      Flow_Type                          = "Redfield"
      Request_Source                     = "IbizaAIExtension"
      IngestionMode                      = "LogAnalytics"
      WorkspaceResourceId                = azurerm_log_analytics_workspace.logs[0].id
      AzureMonitorWorkspaceResourceId    = azurerm_monitor_workspace.prometheus[0].id
      AzureMonitorWorkspaceIngestionMode = "Enabled"
      publicNetworkAccessForIngestion    = "Enabled"
      publicNetworkAccessForQuery        = "Enabled"
    }
  }

  response_export_values = [
    "properties.OTLPLogsEndpoint",
    "properties.OTLPMetricsEndpoint",
    "properties.OTLPTracesEndpoint",
  ]

  tags = var.tags
}
