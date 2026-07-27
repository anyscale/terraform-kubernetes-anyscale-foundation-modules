###############################################################################
# GPU CAPACITY — Karpenter NodePools, not AKS node pools.
#
# There are no `azurerm_kubernetes_cluster_node_pool` resources in this stack.
# AKS Automatic runs Node Auto Provisioning (managed Karpenter) unconditionally,
# so capacity is declared as Kubernetes CRs and provisioned on demand:
#
#   AKSNodeClass — the node image / OS / disk template, and the switch that
#                  asks AKS to manage the NVIDIA driver stack.
#   NodePool     — the SKU constraints, taints, labels, and disruption policy.
#
# CPU capacity needs nothing here: Automatic ships a built-in `default`
# NodePool that provisions general-purpose nodes. Only GPU needs declaring,
# because GPU SKUs need the driver treatment and the Anyscale taints.
#
# DRIVERS: the `EnableManagedGPUExperience` tag on the AKSNodeClass asks AKS to
# install and manage the driver, container toolkit, and device plugin. That
# replaces the entire NVIDIA GPU operator Helm release from the `new-aks`
# sibling (and its toleration gymnastics). It requires the preview feature:
#
#   az feature register --namespace Microsoft.ContainerService --name ManagedGPUExperiencePreview
#   az provider register --namespace Microsoft.ContainerService
#
# TAINTS: identical to the static GPU pools in `new-aks`, so the operator's
# `workloads.accelerator.tolerations.default[*]` settings in anyscale.tf match
# unchanged and Anyscale workloads schedule the same way on either stack.
###############################################################################

locals {
  ###########################################################################
  # One NodePool variant per (config entry x capacity type). Flattened first
  # so the manifest rendering below stays a single straightforward expression
  # — Terraform has no user-defined functions, so the on-demand/spot
  # difference is carried in the variant object rather than a helper.
  ###########################################################################
  gpu_nodepool_variants = flatten([
    for key, cfg in var.gpu_nodepool_configs : [
      for capacity_type in(cfg.enable_spot ? ["on-demand", "spot"] : ["on-demand"]) : {
        key           = key
        cfg           = cfg
        capacity_type = capacity_type
        # Karpenter's capacity-type value is lowercase-hyphenated; Anyscale's
        # taint value is uppercase-underscored. They are not the same string.
        anyscale_capacity_type = capacity_type == "spot" ? "SPOT" : "ON_DEMAND"
        pool_name              = capacity_type == "spot" ? "${cfg.name}spot" : cfg.name
        is_spot                = capacity_type == "spot"
      }
    ]
  ])

  # AKSNodeClass — one per config entry, shared by that entry's on-demand and
  # spot NodePools.
  gpu_nodeclass_documents = [
    for key, cfg in var.gpu_nodepool_configs : yamlencode({
      apiVersion = "karpenter.azure.com/v1beta1"
      kind       = "AKSNodeClass"
      metadata = {
        name = cfg.name
        annotations = {
          "kubernetes.io/description" = "AKS node class for ${key} GPU nodes (${cfg.vm_size})."
        }
      }
      spec = {
        imageFamily  = cfg.image_family
        osDiskSizeGB = cfg.os_disk_size_gb
        # THIS TAG IS THE MANAGED-GPU SWITCH. Nodes created from this class get
        # the AKS-managed NVIDIA driver + device plugin, which is why no GPU
        # operator chart is installed anywhere in this stack.
        tags = {
          EnableManagedGPUExperience = "true"
        }
      }
    })
  ]

  gpu_nodepool_documents = [
    for v in local.gpu_nodepool_variants : yamlencode({
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata = {
        name = v.pool_name
        annotations = {
          "kubernetes.io/description" = "${v.key} GPU NodePool (${v.cfg.vm_size}, ${v.capacity_type})."
        }
      }
      spec = {
        disruption = {
          budgets             = [{ nodes = "30%" }]
          consolidateAfter    = "15m"
          consolidationPolicy = "WhenEmpty"
        }
        # A hard ceiling on how much GPU this pool may ever provision. Karpenter
        # scales to zero when idle, so this bounds the blast radius of a runaway
        # workload rather than costing anything at rest.
        limits = {
          "nvidia.com/gpu" = v.cfg.max_gpus
        }
        template = {
          metadata = {
            labels = merge(
              {
                "kubernetes.azure.com/ebpf-dataplane" = "cilium"
                "nvidia.com/gpu.product"              = v.cfg.product_name
                "nvidia.com/gpu.count"                = v.cfg.gpu_count
              },
              v.is_spot ? {
                "kubernetes.azure.com/scalesetpriority" = "spot"
              } : {},
            )
          }
          spec = {
            expireAfter = "Never"
            nodeClassRef = {
              group = "karpenter.azure.com"
              kind  = "AKSNodeClass"
              name  = v.cfg.name
            }
            requirements = [
              { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
              { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
              { key = "karpenter.sh/capacity-type", operator = "In", values = [v.capacity_type] },
              { key = "karpenter.azure.com/sku-name", operator = "In", values = [v.cfg.vm_size] },
            ]
            # Cilium marks a fresh node NotReady until its agent is up; without
            # this startup taint pods can land on a node with no dataplane.
            startupTaints = [
              { key = "node.cilium.io/agent-not-ready", value = "true", effect = "NoExecute" },
            ]
            taints = concat(
              [
                { key = "nvidia.com/gpu", value = "present", effect = "NoSchedule" },
                { key = "node.anyscale.com/capacity-type", value = v.anyscale_capacity_type, effect = "NoSchedule" },
                { key = "node.anyscale.com/accelerator-type", value = "GPU", effect = "NoSchedule" },
              ],
              v.is_spot ? [
                { key = "kubernetes.azure.com/scalesetpriority", value = "spot", effect = "NoSchedule" },
              ] : [],
            )
          }
        }
      }
    })
  ]

  gpu_nodepool_manifest = join("\n---\n", concat(
    local.gpu_nodeclass_documents,
    local.gpu_nodepool_documents,
  ))
}

###############################################################################
# Rendered to disk (gitignored) and applied by the bootstrap in gateway.tf.
# No file at all when gpu_nodepool_configs is empty — a CPU-only deploy gets no
# GPU machinery whatsoever.
###############################################################################
resource "local_file" "gpu_nodepool_manifest" {
  count = length(var.gpu_nodepool_configs) > 0 ? 1 : 0

  filename        = "${path.module}/nvidia-nodepool.yaml"
  file_permission = "0600"
  content         = local.gpu_nodepool_manifest
}
