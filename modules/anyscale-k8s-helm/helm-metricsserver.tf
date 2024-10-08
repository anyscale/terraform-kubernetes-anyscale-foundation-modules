# Description: This file contains the terraform configuration to deploy the metrics server helm chart.
resource "helm_release" "feature_metrics_server" {
  count = local.module_enabled && var.anyscale_metrics_server_chart.enabled ? 1 : 0

  name       = var.anyscale_metrics_server_chart.name
  repository = var.anyscale_metrics_server_chart.repository
  chart      = var.anyscale_metrics_server_chart.chart
  namespace  = var.anyscale_metrics_server_chart.namespace
  version    = var.anyscale_metrics_server_chart.chart_version

  create_namespace = true

  dynamic "set" {
    for_each = var.anyscale_metrics_server_chart.values
    content {
      name  = set.key
      value = set.value
    }
  }
}
