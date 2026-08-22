###############################################################################
# Azure Firewall (Standard) + Firewall Policy
# Egress lockdown for AKS — AKS subnet uses a UDR with next-hop = firewall
# private IP and outboundType=userDefinedRouting.
# Docs:
# - https://learn.microsoft.com/azure/aks/limit-egress-traffic
# - https://learn.microsoft.com/azure/aks/outbound-rules-control-egress
# - https://learn.microsoft.com/azure/aks/egress-outboundtype
###############################################################################
resource "azurerm_public_ip" "firewall" {
  name                = var.pip_name
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall_policy" "this" {
  name                = var.firewall_policy_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  tags                = var.tags

  dns {
    proxy_enabled = var.dns_proxy_enabled
    servers       = var.dns_servers
  }
}

resource "azurerm_firewall" "this" {
  name                = var.firewall_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.this.id
  tags                = var.tags

  ip_configuration {
    name                 = "ipconfig"
    subnet_id            = var.firewall_subnet_id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }
}

###############################################################################
# Rule Collection Group — AKS required egress + Anyscale FQDNs
###############################################################################
resource "azurerm_firewall_policy_rule_collection_group" "aks_egress" {
  name               = var.rcg_name
  firewall_policy_id = azurerm_firewall_policy.this.id
  priority           = 200

  ##########################################################################
  # Network rules — AKS required network egress
  # https://learn.microsoft.com/azure/aks/limit-egress-traffic#azure-firewall-outbound-rules-for-aks
  ##########################################################################
  network_rule_collection {
    name     = "aks-required-network"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "aks-tcp-9000"
      protocols             = ["TCP"]
      source_addresses      = [var.aks_nodes_cidr]
      destination_addresses = ["AzureCloud.${var.location}"]
      destination_ports     = ["9000"]
    }

    rule {
      name                  = "aks-udp-1194"
      protocols             = ["UDP"]
      source_addresses      = [var.aks_nodes_cidr]
      destination_addresses = ["AzureCloud.${var.location}"]
      destination_ports     = ["1194"]
    }
  }

  ##########################################################################
  # Application rules — AKS FQDN tag + container registries + Anyscale
  # The `AzureKubernetesService` FQDN tag is auto-maintained by Microsoft and
  # covers all AKS-required HTTP/S egress (MCR, packages.aks.azure.com, etc.).
  ##########################################################################
  application_rule_collection {
    name     = "aks-required-fqdns"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "aks-fqdn-tag"
      source_addresses      = [var.aks_nodes_cidr]
      destination_fqdn_tags = ["AzureKubernetesService"]
      protocols {
        type = "Https"
        port = 443
      }
      protocols {
        type = "Http"
        port = 80
      }
    }
  }

  application_rule_collection {
    name     = "container-registries"
    priority = 300
    action   = "Allow"

    rule {
      name              = "registries-https"
      source_addresses  = [var.aks_nodes_cidr]
      destination_fqdns = var.container_registry_fqdns
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  application_rule_collection {
    name     = "azure-identity"
    priority = 350
    action   = "Allow"

    rule {
      name              = "identity-token-exchange"
      source_addresses  = [var.aks_nodes_cidr]
      destination_fqdns = var.azure_identity_fqdns
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  application_rule_collection {
    name     = "azure-monitor"
    priority = 375
    action   = "Allow"

    rule {
      name              = "monitor-ingestion-query"
      source_addresses  = [var.aks_nodes_cidr]
      destination_fqdns = var.azure_monitor_fqdns
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  application_rule_collection {
    name     = "anyscale"
    priority = 400
    action   = "Allow"

    rule {
      name              = "anyscale-fqdns"
      source_addresses  = [var.aks_nodes_cidr]
      destination_fqdns = var.anyscale_fqdns
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  ##########################################################################
  # Application rules — Linux jump-host egress (bootstrap + operate)
  # Emitted only when jump_host_cidrs is set. Lets the in-VNet operator VM
  # install its toolchain and reach the Azure and Anyscale control planes
  # through the firewall instead of relying on direct internet egress.
  ##########################################################################
  dynamic "application_rule_collection" {
    for_each = length(var.jump_host_cidrs) > 0 ? [1] : []
    content {
      name     = "jump-host-egress"
      priority = 500
      action   = "Allow"

      # Tool bootstrap: apt mirrors use HTTP(80); installers/PyPI use HTTPS(443).
      rule {
        name              = "jump-host-tool-bootstrap"
        source_addresses  = var.jump_host_cidrs
        destination_fqdns = var.tool_bootstrap_fqdns
        protocols {
          type = "Https"
          port = 443
        }
        protocols {
          type = "Http"
          port = 80
        }
      }

      rule {
        name              = "jump-host-azure-identity"
        source_addresses  = var.jump_host_cidrs
        destination_fqdns = var.azure_identity_fqdns
        protocols {
          type = "Https"
          port = 443
        }
      }

      rule {
        name              = "jump-host-anyscale"
        source_addresses  = var.jump_host_cidrs
        destination_fqdns = var.anyscale_fqdns
        protocols {
          type = "Https"
          port = 443
        }
      }

      rule {
        name              = "jump-host-container-registries"
        source_addresses  = var.jump_host_cidrs
        destination_fqdns = var.container_registry_fqdns
        protocols {
          type = "Https"
          port = 443
        }
      }
    }
  }
}

###############################################################################
# Diagnostic settings — send firewall logs/metrics to Log Analytics
###############################################################################
resource "azurerm_monitor_diagnostic_setting" "firewall" {
  count = var.diagnostic_settings_enabled ? 1 : 0

  name                       = "tfdiag-${var.firewall_name}"
  target_resource_id         = azurerm_firewall.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
