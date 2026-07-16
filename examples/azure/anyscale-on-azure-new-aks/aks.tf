###############################################################################
# AKS CLUSTER – control-plane + "system" pool
#
# GA `azurerm_kubernetes_cluster` (from the Anyscale reference example) with
# the awesome-aks demo's dataplane grafted in: Azure CNI **overlay** + Cilium
# network policy. Overlay keeps pod IPs out of the BYO node subnet; Cilium
# gives real NetworkPolicy enforcement. Both GA.
###############################################################################
#trivy:ignore:avd-azu-0040
#trivy:ignore:avd-azu-0041
#trivy:ignore:avd-azu-0042
resource "azurerm_kubernetes_cluster" "aks" {

  #checkov:skip=CKV_AZURE_170: "Ensure that AKS use the Paid Sku for its SLA"
  #checkov:skip=CKV_AZURE_172: "Ensure autorotation of Secrets Store CSI Driver secrets for AKS clusters"
  #checkov:skip=CKV_AZURE_141: "Ensure AKS local admin account is disabled"
  #checkov:skip=CKV_AZURE_115: "Ensure that AKS enables private clusters"
  #checkov:skip=CKV_AZURE_117: "Ensure that AKS uses disk encryption set"
  #checkov:skip=CKV_AZURE_232: "Ensure that only critical system pods run on system nodes"
  #checkov:skip=CKV_AZURE_226: "Ensure ephemeral disks are used for OS disks"
  #checkov:skip=CKV_AZURE_116: "Ensure that AKS uses Azure Policies Add-on"
  #checkov:skip=CKV_AZURE_6: "Ensure AKS has an API Server Authorized IP Ranges enabled"
  #checkov:skip=CKV_AZURE_171: "Ensure AKS cluster upgrade channel is chosen"
  #checkov:skip=CKV_AZURE_168: "Ensure Azure Kubernetes Cluster (AKS) nodes should use a minimum number of 50 pods"
  #checkov:skip=CKV_AZURE_227: "Ensure that the AKS cluster encrypt temp disks, caches, and data flows between Compute and Storage resources"

  name                = var.aks_cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # lets kubectl talk to the API over the public FQDN
  dns_prefix = "${var.aks_cluster_name}-dns"

  # workload identity federation
  oidc_issuer_enabled       = true # publishes an OIDC issuer URL
  workload_identity_enabled = true # lets pods use AAD tokens

  #########################################################################
  # default (system) node‑pool
  #########################################################################
  default_node_pool {
    name            = "sys"
    vm_size         = var.system_vm_size
    vnet_subnet_id  = azurerm_subnet.nodes.id
    os_disk_size_gb = 64
    type            = "VirtualMachineScaleSets"

    # autoscaler
    auto_scaling_enabled = true
    min_count            = 1
    max_count            = 3
  }

  #########################################################################
  # identities, networking, addons, tags
  #########################################################################
  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = var.aks_pod_cidr
    service_cidr        = var.aks_service_cidr
    dns_service_ip      = coalesce(var.aks_cluster_dns_address, cidrhost(var.aks_service_cidr, 2))
  }

  storage_profile {
    blob_driver_enabled = var.enable_blob_driver
  }

  # Container Insights agent → Log Analytics (from the awesome-aks demo's
  # omsagent addon; MSI auth = the demo's useAADAuth=true).
  dynamic "oms_agent" {
    for_each = var.enable_monitoring ? [1] : []
    content {
      log_analytics_workspace_id      = azurerm_log_analytics_workspace.logs[0].id
      msi_auth_for_monitoring_enabled = true
    }
  }

  # Managed Prometheus metrics profile (azureMonitorProfile.metrics in the
  # demo). The DCE/DCR wiring that routes these metrics to the Azure Monitor
  # workspace lives in prometheus.tf.
  dynamic "monitor_metrics" {
    for_each = var.enable_monitoring ? [1] : []
    content {
      annotations_allowed = null
      labels_allowed      = null
    }
  }

  lifecycle {
    ignore_changes = [default_node_pool[0].upgrade_settings]
  }

  tags = var.tags
}

###############################################################################
# NODE AUTO PROVISIONING (opt-in, PREVIEW) — from the awesome-aks demo.
#
# Layered as an azapi patch so the cluster itself stays on the GA typed
# resource. Requires the NodeAutoProvisioningPreview feature flag. NAP
# requires the Cilium overlay dataplane, which this cluster already uses.
###############################################################################
resource "azapi_update_resource" "node_auto_provisioning" {
  count = var.enable_node_auto_provisioning ? 1 : 0

  type        = "Microsoft.ContainerService/managedClusters@2025-03-02-preview"
  resource_id = azurerm_kubernetes_cluster.aks.id

  body = {
    properties = {
      nodeProvisioningProfile = {
        mode = "Auto"
      }
    }
  }
}

###############################################################################
# CPU NODE POOL – OnDemand
###############################################################################
resource "azurerm_kubernetes_cluster_node_pool" "ondemand_cpu" {

  #checkov:skip=CKV_AZURE_168: "Ensure Azure Kubernetes Cluster (AKS) nodes should use a minimum number of 50 pods"
  #checkov:skip=CKV_AZURE_227: "Ensure that the AKS cluster encrypt temp disks, caches, and data flows between Compute and Storage resources"

  name                        = "cpu16"
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.aks.id
  temporary_name_for_rotation = "cpu16tmp"

  vm_size        = var.cpu_vm_size
  mode           = "User"
  vnet_subnet_id = azurerm_subnet.nodes.id

  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 10

  node_taints = [
    "node.anyscale.com/capacity-type=ON_DEMAND:NoSchedule"
  ]

  lifecycle {
    ignore_changes = [upgrade_settings]
  }

  tags = var.tags
}

###############################################################################
# CPU NODE POOL – Spot
###############################################################################
resource "azurerm_kubernetes_cluster_node_pool" "spot_cpu" {

  #checkov:skip=CKV_AZURE_168: "Ensure Azure Kubernetes Cluster (AKS) nodes should use a minimum number of 50 pods"
  #checkov:skip=CKV_AZURE_227: "Ensure that the AKS cluster encrypt temp disks, caches, and data flows between Compute and Storage resources"

  name                        = "cpu16spot"
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.aks.id
  temporary_name_for_rotation = "cpu16sptmp"

  vm_size        = var.cpu_vm_size
  mode           = "User"
  vnet_subnet_id = azurerm_subnet.nodes.id

  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 10

  node_taints = [
    "node.anyscale.com/capacity-type=SPOT:NoSchedule",
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule",
  ]

  node_labels = {
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }
  priority        = "Spot"
  eviction_policy = "Delete"

  lifecycle {
    ignore_changes = [upgrade_settings]
  }

  tags = var.tags
}

###############################################################################
# GPU NODE POOLS – OnDemand
#
# `gpu_driver` implements the gpu_driver_mode switch:
#   "operator" → "None"    (NVIDIA GPU operator manages drivers; see gpu.tf)
#   "managed"  → "Install" (AKS installs the driver stack)
###############################################################################

#trivy:ignore:avd-azu-0168
#trivy:ignore:avd-azu-0227
resource "azurerm_kubernetes_cluster_node_pool" "gpu_ondemand" {
  #checkov:skip=CKV_AZURE_168
  #checkov:skip=CKV_AZURE_227

  for_each = var.gpu_pool_configs

  name                  = each.value.name
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id

  vm_size        = each.value.vm_size
  mode           = "User"
  vnet_subnet_id = azurerm_subnet.nodes.id
  gpu_driver     = var.gpu_driver_mode == "managed" ? "Install" : "None"

  # ── autoscaling (shared across all pools) ───────────────────────────────────
  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 10

  upgrade_settings { max_surge = "1" }

  # ── labels & taints ────────────────────────────────────────────────────────
  node_labels = {
    "nvidia.com/gpu.product" = each.value.product_name
    "nvidia.com/gpu.count"   = each.value.gpu_count
  }

  node_taints = [
    "node.anyscale.com/capacity-type=ON_DEMAND:NoSchedule",
    "nvidia.com/gpu=present:NoSchedule",
    "node.anyscale.com/accelerator-type=GPU:NoSchedule",
  ]

  lifecycle {
    ignore_changes = [upgrade_settings]
  }

  tags = var.tags
}

###############################################################################
# GPU NODE POOLS – Spot
###############################################################################
#trivy:ignore:avd-azu-0168
#trivy:ignore:avd-azu-0227
resource "azurerm_kubernetes_cluster_node_pool" "gpu_spot" {
  #checkov:skip=CKV_AZURE_168
  #checkov:skip=CKV_AZURE_227

  for_each = var.gpu_pool_configs

  name                  = "${each.value.name}spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id

  vm_size        = each.value.vm_size
  mode           = "User"
  vnet_subnet_id = azurerm_subnet.nodes.id
  gpu_driver     = var.gpu_driver_mode == "managed" ? "Install" : "None"

  # ── autoscaling (shared across all pools) ───────────────────────────────────
  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 10

  # ── labels & taints ────────────────────────────────────────────────────────
  node_labels = {
    "nvidia.com/gpu.product"                = each.value.product_name
    "nvidia.com/gpu.count"                  = each.value.gpu_count
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }

  node_taints = [
    "node.anyscale.com/capacity-type=SPOT:NoSchedule",
    "nvidia.com/gpu=present:NoSchedule",
    "node.anyscale.com/accelerator-type=GPU:NoSchedule",
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule",
  ]

  priority        = "Spot"
  eviction_policy = "Delete"

  lifecycle {
    ignore_changes = [upgrade_settings]
  }

  tags = var.tags
}
