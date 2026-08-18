###############################################################################
# Azure Container Registry - private endpoint only.
#
# Two roles in this example:
#
#   1. Image build target for Anyscale cluster environments. The operator's
#      image builder pushes built images (AcrPush) and drives ACR Tasks builds
#      (Container Registry Tasks Contributor).
#
#   2. The mirror for platform images when egress is locked down. With
#      `block_public_internet_egress = true`, non-Azure registries are
#      unreachable from the nodes subnet - ingress-nginx from registry.k8s.io,
#      the Anyscale operator image, anything on Docker Hub. Cache rules pull
#      them into this registry instead.
#
# Premium SKU is not a preference here - private endpoints require it.
###############################################################################

locals {
  acr_name_base = replace(var.aks_cluster_name, "-", "")
  # ACR names are globally unique and capped at 50 characters. Reserve 3 for
  # "acr" plus 5 for the shared suffix.
  acr_name = coalesce(
    var.acr_name,
    "${substr(local.acr_name_base, 0, 42)}acr${local.name_suffix}"
  )

  acr_private_dns_zone_name = "privatelink.azurecr.io"
}

resource "azurerm_container_registry" "acr" {
  count = var.enable_acr ? 1 : 0

  #checkov:skip=CKV_AZURE_164: "Ensure ACR uses signed/trusted images"
  #checkov:skip=CKV_AZURE_233: "Ensure Azure Container Registry (ACR) is zone redundant"
  #checkov:skip=CKV_AZURE_237: "Ensure dedicated data endpoints are enabled"

  name                = local.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  # Private endpoints, cache rules and zone redundancy are all Premium-only.
  sku           = "Premium"
  admin_enabled = false

  # Reached over the private endpoint below. Note that this governs INBOUND
  # access to the registry only - it does not affect ACR's own outbound fetches
  # for the cache rules further down.
  public_network_access_enabled = false

  # Lets trusted Azure services reach the registry despite the network
  # restriction. ACR Tasks - which the Anyscale operator's image builder drives
  # - runs on shared Azure infrastructure and fails against a fully locked-down
  # registry without this.
  network_rule_bypass_option = "AzureServices"

  tags = var.tags
}

###############################################################################
# Private endpoint + private DNS zone.
#
# The registry endpoint and its data endpoints (<registry>.<region>.data.
# azurecr.io) both live under privatelink.azurecr.io. Using a
# private_dns_zone_group registers all of the required records automatically -
# hand-writing A records here is a common way to end up with manifests
# resolving privately while layer pulls still try to leave the VNet.
###############################################################################
resource "azurerm_private_dns_zone" "acr" {
  count = var.enable_acr ? 1 : 0

  name                = local.acr_private_dns_zone_name
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  count = var.enable_acr ? 1 : 0

  name                  = "${var.aks_cluster_name}-acr"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.acr[0].name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "acr" {
  count = var.enable_acr ? 1 : 0

  name                = "${var.aks_cluster_name}-acr-pe"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.private_endpoints.id

  private_service_connection {
    name                           = "${var.aks_cluster_name}-acr"
    private_connection_resource_id = azurerm_container_registry.acr[0].id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr[0].id]
  }

  tags = var.tags
}

###############################################################################
# Cache rules - mirror upstream images into this registry.
#
# On the first pull of <acr>.azurecr.io/<target_repo>:<tag>, ACR fetches the
# image from source_repo and caches it.
#
# The reason this works with egress blocked: ACR performs the upstream fetch
# from its own service infrastructure, not from your VNet. The nodes pull from
# ACR over the private endpoint; the upstream hop never touches the nodes
# subnet, so the Deny Internet rule does not apply to it.
#
#   registry.k8s.io ──(ACR's egress)──> ACR ──(private endpoint)──> nodes
#
# Anonymous cache rules are subject to upstream rate limits. Docker Hub
# throttles unauthenticated pulls in particular - attach a credential set if
# you start seeing 429s.
###############################################################################
resource "azurerm_container_registry_cache_rule" "cache" {
  for_each = var.enable_acr ? var.acr_cache_rules : {}

  name                  = each.key
  container_registry_id = azurerm_container_registry.acr[0].id
  source_repo           = each.value.source_repo
  target_repo           = each.value.target_repo
}

###############################################################################
# Role assignments.
#
# kubelet pulls images; the operator's image builder pushes them and runs
# ACR Tasks builds.
###############################################################################
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  count = var.enable_acr ? 1 : 0

  scope                = azurerm_container_registry.acr[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "operator_acr_push" {
  count = var.enable_acr ? 1 : 0

  scope                            = azurerm_container_registry.acr[0].id
  role_definition_name             = "AcrPush"
  principal_id                     = azurerm_user_assigned_identity.anyscale_operator.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "operator_acr_tasks" {
  count = var.enable_acr ? 1 : 0

  scope                            = azurerm_container_registry.acr[0].id
  role_definition_name             = "Container Registry Tasks Contributor"
  principal_id                     = azurerm_user_assigned_identity.anyscale_operator.principal_id
  skip_service_principal_aad_check = true
}
