###############################################################################
# AKS CLUSTER - private API server, CPU only
#
# This is the Azure counterpart of the EKS cluster in
# examples/aws/eks-private-cpu/eks.tf.
#
# Two things worth understanding about what "private" means here:
#
#   1. `private_cluster_enabled` makes the API SERVER private and nothing else.
#      It is the analog of `cluster_endpoint_public_access = false` on EKS. The
#      nodes still egress - see the NSG in main.tf for what they reach and how
#      that is bounded.
#
#   2. There is no Azure analog of the AWS example's `api_server_allowed_cidrs`.
#      On AKS, `api_server_access_profile.authorized_ip_ranges` applies only to
#      PUBLIC clusters and is mutually exclusive with private ones. Reaching the
#      private endpoint is purely a network and DNS problem - see the README.
###############################################################################

locals {
  # One on-demand and one spot pool per entry in var.cpu_instance_types.
  # Each size gets its own pool so the cluster autoscaler sees homogeneous
  # capacity - it assumes every node in a pool has identical CPU and memory.
  #
  # AKS node pool names are capped at 12 characters, lowercase alphanumeric,
  # starting with a letter, which is why these are `od8cpu` / `spot8cpu` rather
  # than the `ondemand_8cpu` / `spot_8cpu` the AWS example uses.
  cpu_node_pools = merge(
    {
      for size_name, cfg in var.cpu_instance_types : "od${size_name}" => {
        vm_size         = cfg.vm_size
        min_count       = cfg.min_count
        max_count       = cfg.max_count
        priority        = "Regular"
        eviction_policy = null
        node_labels     = {}
        node_taints = [
          "node.anyscale.com/capacity-type=ON_DEMAND:NoSchedule",
        ]
      }
    },
    {
      for size_name, cfg in var.cpu_instance_types : "spot${size_name}" => {
        vm_size         = cfg.vm_size
        min_count       = cfg.min_count
        max_count       = cfg.max_count
        priority        = "Spot"
        eviction_policy = "Delete"
        node_labels = {
          "kubernetes.azure.com/scalesetpriority" = "spot"
        }
        node_taints = [
          "node.anyscale.com/capacity-type=SPOT:NoSchedule",
          "kubernetes.azure.com/scalesetpriority=spot:NoSchedule",
        ]
      }
    }
  )
}

#trivy:ignore:avd-azu-0040
#trivy:ignore:avd-azu-0041
#trivy:ignore:avd-azu-0042
resource "azurerm_kubernetes_cluster" "aks" {
  #checkov:skip=CKV_AZURE_170: "Ensure that AKS use the Paid Sku for its SLA"
  #checkov:skip=CKV_AZURE_172: "Ensure autorotation of Secrets Store CSI Driver secrets for AKS clusters"
  #checkov:skip=CKV_AZURE_141: "Ensure AKS local admin account is disabled"
  #checkov:skip=CKV_AZURE_117: "Ensure that AKS uses disk encryption set"
  #checkov:skip=CKV_AZURE_232: "Ensure that only critical system pods run on system nodes"
  #checkov:skip=CKV_AZURE_226: "Ensure ephemeral disks are used for OS disks"
  #checkov:skip=CKV_AZURE_116: "Ensure that AKS uses Azure Policies Add-on"
  #checkov:skip=CKV_AZURE_6: "Ensure AKS has an API Server Authorized IP Ranges enabled"
  #checkov:skip=CKV_AZURE_171: "Ensure AKS cluster upgrade channel is chosen"
  #checkov:skip=CKV_AZURE_168: "Ensure AKS nodes should use a minimum number of 50 pods"
  #checkov:skip=CKV_AZURE_4: "Ensure AKS logging to Azure Monitoring is Configured"
  #checkov:skip=CKV_AZURE_227: "Ensure that the AKS cluster encrypt temp disks, caches, and data flows"

  name                = var.aks_cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  kubernetes_version  = var.kubernetes_version

  dns_prefix = "${var.aks_cluster_name}-dns"

  #########################################################################
  # Private API server.
  #
  # `private_dns_zone_id = "System"` has AKS create and manage
  # privatelink.<region>.azmk8s.io in the node resource group, and link it to
  # this VNet. Anything inside the VNet resolves the API server FQDN to the
  # private endpoint's IP.
  #
  # To reach it from a peered network you need BOTH a route and a
  # virtual-network-link from that zone to the peer VNet - routing alone gives
  # you a name that does not resolve.
  #########################################################################
  private_cluster_enabled             = true
  private_dns_zone_id                 = "System"
  private_cluster_public_fqdn_enabled = false

  # Workload identity federation. The Anyscale operator authenticates to the
  # control plane by exchanging its projected service account token for a
  # Microsoft Entra token - which is why the NSG must allow Entra egress.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  #########################################################################
  # default (system) node pool
  #
  # Untainted, so this is where CoreDNS, the Anyscale operator, ingress-nginx
  # and anything else without an Anyscale toleration lands.
  #########################################################################
  default_node_pool {
    name                        = "sys"
    vm_size                     = var.system_vm_size
    vnet_subnet_id              = azurerm_subnet.nodes.id
    type                        = "VirtualMachineScaleSets"
    temporary_name_for_rotation = "systmp"

    # The Dsv5 family has no local temp disk, so ephemeral OS disks are not
    # available - these are managed (network-attached) Premium SSDs.
    os_disk_type    = "Managed"
    os_disk_size_gb = var.system_node_pool_disk_size_gb

    auto_scaling_enabled = true
    min_count            = 1
    max_count            = 3
  }

  identity {
    type = "SystemAssigned"
  }

  #########################################################################
  # Azure CNI overlay + Cilium.
  #
  # Overlay keeps pod IPs out of the nodes subnet - each node consumes exactly
  # one subnet IP instead of `max_pods` of them. With node-subnet CNI a /24
  # would cap the cluster at roughly eight nodes; with overlay it holds ~250.
  #
  # `outbound_type` is deliberately left at its default of `loadBalancer`: AKS
  # provisions a Standard load balancer at creation time and wires SNAT itself.
  # See the egress note at the bottom of main.tf for why this example does not
  # use a NAT gateway, and what it would cost to add one.
  #########################################################################
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = var.aks_pod_cidr
    service_cidr        = var.aks_service_cidr
    dns_service_ip      = coalesce(var.aks_cluster_dns_address, cidrhost(var.aks_service_cidr, 10))
  }

  storage_profile {
    blob_driver_enabled = var.enable_blob_driver
  }

  lifecycle {
    ignore_changes = [default_node_pool[0].upgrade_settings]
  }

  tags = var.tags

  depends_on = [
    azurerm_subnet_network_security_group_association.nodes,
  ]
}

###############################################################################
# CPU node pools - one on-demand and one spot per entry in cpu_instance_types.
#
# All scale from zero and carry the Anyscale capacity-type taint, so nothing
# lands on them unless it tolerates the taint. Spot pools additionally carry
# the Azure scalesetpriority taint that AKS applies to spot nodes.
###############################################################################
resource "azurerm_kubernetes_cluster_node_pool" "cpu" {
  #checkov:skip=CKV_AZURE_168: "Ensure AKS nodes should use a minimum number of 50 pods"
  #checkov:skip=CKV_AZURE_227: "Ensure that the AKS cluster encrypt temp disks, caches, and data flows"

  for_each = local.cpu_node_pools

  name                        = each.key
  kubernetes_cluster_id       = azurerm_kubernetes_cluster.aks.id
  temporary_name_for_rotation = "${each.key}t"

  vm_size        = each.value.vm_size
  mode           = "User"
  vnet_subnet_id = azurerm_subnet.nodes.id

  os_disk_type    = "Managed"
  os_disk_size_gb = var.node_pool_disk_size_gb

  auto_scaling_enabled = true
  min_count            = each.value.min_count
  max_count            = each.value.max_count

  priority        = each.value.priority
  eviction_policy = each.value.eviction_policy

  node_labels = each.value.node_labels
  node_taints = each.value.node_taints

  lifecycle {
    ignore_changes = [upgrade_settings]
  }

  tags = var.tags
}

# The operator's managed identity, its federated credential, and the storage
# role assignment live in identity.tf.
