###############################################################################
# Azure Bastion (Standard SKU, native client tunneling enabled)
# Required for AKS private-cluster connect via Bastion (preview).
# Docs:
# - https://learn.microsoft.com/azure/bastion/bastion-connect-to-aks-private-cluster
# - https://learn.microsoft.com/azure/aks/private-cluster-connect
###############################################################################
resource "azurerm_public_ip" "bastion" {
  name                = var.pip_name
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "this" {
  name                = var.bastion_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  # Required for `az aks bastion` (native client tunneling).
  tunneling_enabled = true
  tags              = var.tags

  ip_configuration {
    name                 = "ipconfig"
    subnet_id            = var.subnet_id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

###############################################################################
# Diagnostic settings — Bastion audit logs and metrics.
###############################################################################
resource "azurerm_monitor_diagnostic_setting" "bastion" {
  count = var.diagnostic_settings_enabled ? 1 : 0

  name                       = "tfdiag-${var.bastion_name}"
  target_resource_id         = azurerm_bastion_host.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "BastionAuditLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
