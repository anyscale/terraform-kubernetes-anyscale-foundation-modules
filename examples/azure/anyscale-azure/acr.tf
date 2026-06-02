###############################################################################
# Azure Container Registry — customer-owned registry for Anyscale workload
# images (cluster envs, fine-tuned models, ad-hoc Dockerfiles produced by the
# operator's image builder when `IMAGE_BUILD_BACKEND_ACR` is in effect).
#
# This is opt-in via `var.enable_acr` (default true). The AKS extension itself
# pulls the operator image from `arcmktplaceprod.azurecr.io` regardless — this
# ACR is for the workloads you launch from the Anyscale console, not for the
# operator binary.
###############################################################################

locals {
  acr_name_base = replace(var.aks_cluster_name, "-", "")
  acr_name      = coalesce(var.acr_name, "${substr(local.acr_name_base, 0, 47)}acr")
}

resource "azurerm_container_registry" "acr" {
  count = var.enable_acr ? 1 : 0

  name                = local.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = var.acr_sku
  admin_enabled       = false
  # Public network access — match the example's overall public-networking
  # posture. Premium SKU is required if you want to disable this and use
  # Private Link.
  public_network_access_enabled = true
  # zone_redundancy_enabled is a Premium-only feature; AzureRM accepts the
  # flag on lower SKUs but Azure ignores it. Force false on non-Premium so
  # there is no apply-time confusion.
  zone_redundancy_enabled = var.acr_sku == "Premium" ? var.acr_zone_redundancy_enabled : false

  tags = var.tags
}

###############################################################################
# Grant the AKS kubelet identity AcrPull on this registry so pods can pull
# images. `anyscale.tf` passes `manageAksKubeletAcrPullRoleAssignment=false`
# to the ARM template so we — not the Anyscale RP — own this role assignment.
###############################################################################
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  count = var.enable_acr ? 1 : 0

  scope                = azurerm_container_registry.acr[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}
