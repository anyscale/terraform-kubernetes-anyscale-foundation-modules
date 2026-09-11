###############################################################################
# GPU driver stack — the gpu_driver_mode switch.
#
#   "operator" (default) — GPU node pools are created with gpu_driver="None"
#     (aks.tf) and this Helm release installs the NVIDIA GPU operator, which
#     manages the driver, container toolkit, and device plugin. GA everywhere.
#     (From the awesome-aks demo's nvidia.tf, pinned by variable.)
#
#   "managed" — GPU node pools are created with gpu_driver="Install" and no
#     chart is deployed. For AKS to also manage the device plugin, register
#     the ManagedGPUExperiencePreview feature first (see variables.tf).
#
# Only installed when at least one GPU pool exists (or NAP may provision GPU
# nodes) — a CPU-only deploy gets no GPU machinery at all.
###############################################################################
resource "helm_release" "nvidia_gpu_operator" {
  count = var.gpu_driver_mode == "operator" && (length(var.gpu_pool_configs) > 0 || var.enable_node_auto_provisioning) ? 1 : 0

  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = var.gpu_operator_chart_version
  namespace        = "gpu-operator"
  create_namespace = true
  wait             = true
  timeout          = 600

  # The chart's daemonsets tolerate nvidia.com/gpu by default — but the GPU
  # pools ALSO carry the Anyscale taints (node.anyscale.com/capacity-type,
  # node.anyscale.com/accelerator-type; spot pools add scalesetpriority).
  # Without tolerations for those, the driver/device-plugin daemonsets never
  # schedule onto GPU nodes, nvidia.com/gpu never registers as allocatable,
  # and GPU workloads sit Pending with "Insufficient nvidia.com/gpu" while
  # the autoscaler keeps adding useless nodes. Setting tolerations REPLACES
  # the chart defaults, so the nvidia.com/gpu toleration is restated. The
  # node-feature-discovery subchart needs the same treatment (it labels the
  # nodes the operator keys off), including the chart's control-plane
  # defaults.
  values = [
    yamlencode({
      daemonsets = {
        tolerations = local.gpu_operator_tolerations
      }
      node-feature-discovery = {
        worker = {
          tolerations = concat(
            [
              { key = "node-role.kubernetes.io/master", operator = "Equal", value = "", effect = "NoSchedule" },
              { key = "node-role.kubernetes.io/control-plane", operator = "Equal", value = "", effect = "NoSchedule" },
            ],
            local.gpu_operator_tolerations,
          )
        }
      }
    })
  ]
}

locals {
  gpu_operator_tolerations = [
    { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" },
    { key = "node.anyscale.com/capacity-type", operator = "Exists", effect = "NoSchedule" },
    { key = "node.anyscale.com/accelerator-type", operator = "Exists", effect = "NoSchedule" },
    { key = "kubernetes.azure.com/scalesetpriority", operator = "Exists", effect = "NoSchedule" },
  ]
}

###############################################################################
# Karpenter NodePool for GPU workloads — only meaningful when Node Auto
# Provisioning is enabled (from the awesome-aks demo). Mirrors the taints the
# static GPU pools use so Anyscale workloads schedule identically on
# NAP-provisioned nodes.
###############################################################################
resource "kubectl_manifest" "nap_gpu_node_pool" {
  count = var.enable_node_auto_provisioning ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "nvidia"
      annotations = {
        "kubernetes.io/description" = "Specialized NodePool for workloads requiring GPUs."
      }
    }
    spec = {
      disruption = {
        budgets             = [{ nodes = "30%" }]
        consolidateAfter    = "15m"
        consolidationPolicy = "WhenEmpty"
      }
      template = {
        metadata = {
          labels = {
            "kubernetes.azure.com/ebpf-dataplane" = "cilium"
          }
        }
        spec = {
          expireAfter = "Never"
          nodeClassRef = {
            group = "karpenter.azure.com"
            kind  = "AKSNodeClass"
            name  = "default"
          }
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "karpenter.azure.com/sku-name", operator = "In", values = [var.nap_gpu_sku_name] },
          ]
          startupTaints = [
            { key = "node.cilium.io/agent-not-ready", value = "true", effect = "NoExecute" },
          ]
          taints = [
            { key = "nvidia.com/gpu", value = "present", effect = "NoSchedule" },
            { key = "node.anyscale.com/capacity-type", value = "ON_DEMAND", effect = "NoSchedule" },
            { key = "node.anyscale.com/accelerator-type", value = "GPU", effect = "NoSchedule" },
          ]
        }
      }
    }
  })

  depends_on = [azapi_update_resource.node_auto_provisioning]
}
