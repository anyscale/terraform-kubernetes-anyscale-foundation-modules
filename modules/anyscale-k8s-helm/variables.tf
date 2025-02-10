# ------------------------------------------------------------------------------
# REQUIRED PARAMETERS
# These variables must be set when using this module.
# ------------------------------------------------------------------------------
variable "cloud_provider" {
  description = <<-EOT
    (Required) The cloud provider (aws or gcp)

    ex:
    ```
    cloud_provider = "aws"
    ```
  EOT
  type        = string
  validation {
    condition = (
      var.cloud_provider == "aws" || var.cloud_provider == "gcp"
    )
    error_message = "The cloud_provider only allows `aws` or `gcp`"
  }
}

variable "kubernetes_cluster_name" {
  type        = string
  description = <<-EOT
    (Optional) The name of the Kubernetes cluster.

    ex:
    ```
    kubernetes_cluster_name = "my-cluster"
    ```
  EOT
  default     = null
}

# ------------------------------------------------------------------------------
# OPTIONAL PARAMETERS
# These variables have defaults, but may be overridden.
# ------------------------------------------------------------------------------
variable "module_enabled" {
  description = <<-EOT
    (Optional) Determines if this module should create resources.

    If set to true, `eks_role_arn`, `anyscale_subnet_ids`, and `anyscale_security_group_id` must be provided.
    ex:
    ```
    module_enabled = true
    ```
  EOT
  type        = bool
  default     = false
}


# variable "anyscale_node_tolerations" {
#   description = <<-EOT
#     (Optional) List of tolerations to apply to helm charts that need to run on Anyscale Nodes.

#     ex:
#     ```
#     anyscale_node_tolerations = [
#       {
#         key      = "node.anyscale.com/capacity-type"
#         operator = "Equal"
#         value    = "ANY"
#         effect   = "NoSchedule"
#       },
#       {
#         key      = "node.anyscale.com/accelerator-type"
#         operator = "Equal"
#         value    = "GPU"
#         effect   = "NoSchedule"
#       }
#     ]
#     ```
#   EOT
#   type = list(
#     object({
#       key      = string
#       operator = string
#       value    = string
#       effect   = string
#     })
#   )
#   default = [
#     {
#       key      = "node.anyscale.com/capacity-type"
#       operator = "Equal"
#       value    = "ANY"
#       effect   = "NoSchedule"
#     },
#     {
#       key      = "node.anyscale.com/accelerator-type"
#       operator = "Equal"
#       value    = "GPU"
#       effect   = "NoSchedule"
#     }
#   ]
# }

# ------------------------------------------------------------------------------
# Helm Chart Variables
# ------------------------------------------------------------------------------
variable "eks_cluster_region" {
  description = <<-EOT
    (Optional) The region of the EKS cluster.

    ex:
    ```
    eks_cluster_region = "us-west-2"
    ```
  EOT
  type        = string
  default     = null
}
variable "anyscale_cluster_autoscaler_chart" {
  description = <<-EOT
    (Optional) The Helm chart to install the Cluster Autoscaler.

    ex:
    ```
    anyscale_cluster_autoscaler_chart = {
      enabled       = true
      name          = "cluster-autoscaler"
      respository   = "https://kubernetes.github.io/autoscaler"
      chart         = "cluster-autoscaler"
      chart_version = "9.37.0"
      namespace     = "kube-system"
      values        = {
        "some.other.config" = "value"
      }
    }
    ```
  EOT
  type = object({
    enabled       = bool
    name          = optional(string)
    repository    = optional(string)
    chart         = optional(string)
    chart_version = optional(string)
    namespace     = optional(string)
    values        = optional(map(string))
  })
  default = {
    enabled       = true
    name          = "cluster-autoscaler"
    repository    = "https://kubernetes.github.io/autoscaler"
    chart         = "cluster-autoscaler"
    chart_version = "9.37.0"
    namespace     = "kube-system"
    values        = {}
  }
}

variable "anyscale_ingress_chart" {
  description = <<-EOT
    (Optional) The Helm chart to install the Cluster Ingress.

    ex:
    ```
    anyscale_ingress_chart = {
      enabled       = true
      name          = "anyscale-ingress"
      respository   = "https://kubernetes.github.io/ingress-nginx"
      chart         = "ingress-nginx"
      chart_version = "4.11.1"
      namespace     = "ingress-nginx"
      values        = {
        "some.other.config" = "value"
      }
    }
    ```
  EOT
  type = object({
    enabled       = bool
    name          = optional(string)
    repository    = optional(string)
    chart         = optional(string)
    chart_version = optional(string)
    namespace     = optional(string)
    values        = optional(map(string))
  })
  default = {
    enabled       = true
    name          = "anyscale-ingress"
    repository    = "https://kubernetes.github.io/ingress-nginx"
    chart         = "ingress-nginx"
    chart_version = "4.11.1"
    namespace     = "ingress-nginx"
    values = {
      "controller.service.type"            = "LoadBalancer"
      "controller.allowSnippetAnnotations" = "true"
      "controller.autoscaling.enabled"     = "true"
    }
  }
}

variable "anyscale_ingress_internal_lb" {
  description = <<-EOT
    (Optioanl) Determines if the AWS NLB should be internal.

    Requires `cloud_provider` to be set to `aws`.
    Requires `anyscale_ingress_chart` to be enabled.

    ex:
    ```
    anyscale_ingress_internal_lb = true
    ```
  EOT
  type        = bool
  default     = false
}

variable "anyscale_nvidia_device_plugin_chart" {
  description = <<-EOT
    (Optional) The Helm chart to install the NVIDIA Device Plugin.

    Valid settings can be found in the [nvidia documentation](https://github.com/NVIDIA/k8s-device-plugin?tab=readme-ov-file#deploying-with-gpu-feature-discovery-for-automatic-node-labels)

    ex:
    ```
    anyscale_nvidia_device_plugin_chart = {
      enabled       = true
      name          = "nvidia-device-plugin"
      respository   = "https://nvidia.github.io/k8s-device-plugin"
      chart         = "nvidia-device-plugin"
      chart_version = "0.16.2"
      namespace     = "nvidia-device-plugin"
      values        = {
        "some.other.config" = "value"
      }
    }
    ```
  EOT
  type = object({
    enabled       = bool
    name          = optional(string)
    repository    = optional(string)
    chart         = optional(string)
    chart_version = optional(string)
    namespace     = optional(string)
    values        = optional(map(string))
  })
  default = {
    enabled       = true
    name          = "anyscale-nvidia-device-plugin"
    repository    = "https://nvidia.github.io/k8s-device-plugin"
    chart         = "nvidia-device-plugin"
    chart_version = "0.16.2"
    namespace     = "nvidia-device-plugin"
    values = {
      "gfd.enabled"       = "true",
      "priorityClassName" = "system-node-critical"

      "nfd.worker.tolerations[0].key"      = "node-role.kubernetes.io/master"
      "nfd.worker.tolerations[0].operator" = "Equal"
      "nfd.worker.tolerations[0].value"    = ""
      "nfd.worker.tolerations[0].effect"   = "NoSchedule"

      "nfd.worker.tolerations[1].key"      = "nvidia.com/gpu"
      "nfd.worker.tolerations[1].operator" = "Equal"
      "nfd.worker.tolerations[1].value"    = "present"
      "nfd.worker.tolerations[1].effect"   = "NoSchedule"

      "nfd.worker.tolerations[2].key"      = "node.anyscale.com/accelerator-type"
      "nfd.worker.tolerations[2].operator" = "Equal"
      "nfd.worker.tolerations[2].value"    = "GPU"
      "nfd.worker.tolerations[2].effect"   = "NoSchedule"

      "nfd.worker.tolerations[3].key"      = "node.anyscale.com/capacity-type"
      "nfd.worker.tolerations[3].operator" = "Equal"
      "nfd.worker.tolerations[3].value"    = "ANY"
      "nfd.worker.tolerations[3].effect"   = "NoSchedule"

      "tolerations[0].key"      = "nvidia.com/gpu"
      "tolerations[0].operator" = "Equal"
      "tolerations[0].value"    = "present"
      "tolerations[0].effect"   = "NoSchedule"

      "tolerations[1].key"      = "node.anyscale.com/accelerator-type"
      "tolerations[1].operator" = "Equal"
      "tolerations[1].value"    = "GPU"
      "tolerations[1].effect"   = "NoSchedule"

      "tolerations[2].key"      = "node.anyscale.com/capacity-type"
      "tolerations[2].operator" = "Equal"
      "tolerations[2].value"    = "ANY"
      "tolerations[2].effect"   = "NoSchedule"
    }
  }
}

variable "anyscale_metrics_server_chart" {
  description = <<-EOT
    (Optional) The Helm chart to install the Metrics Server.

    Required for the Anyscale Autoscaler to function.

    ex:
    ```
    anyscale_metrics_server_chart = {
      enabled       = true
      name          = "metrics-server"
      respository   = "https://kubernetes-sigs.github.io/metrics-server/"
      chart         = "metrics-server"
      chart_version = "3.12.1"
      namespace     = "metrics-server"
      values        = {
        "some.other.config" = "value"
      }
    }
    ```
  EOT
  type = object({
    enabled       = bool
    name          = optional(string)
    repository    = optional(string)
    chart         = optional(string)
    chart_version = optional(string)
    namespace     = optional(string)
    values        = optional(map(string))
  })
  default = {
    enabled       = true
    name          = "metrics-server"
    repository    = "https://kubernetes-sigs.github.io/metrics-server/"
    chart         = "metrics-server"
    chart_version = "3.12.1"
    namespace     = "metrics-server"
    values        = {}
  }
}

variable "anyscale_prometheus_chart" {
  description = <<-EOT
    (Optional) The Helm chart to install Prometheus.

    ex:
    ```
    anyscale_prometheus_chart = {
      enabled       = true
      name          = "prometheus"
      respository   = "https://prometheus-community.github.io/helm-charts"
      chart         = "prometheus"
      chart_version = "16.0.0"
      namespace     = "prometheus"
      values        = {
        "some.other.config" = "value"
      }
    }
    ```
  EOT
  type = object({
    enabled       = bool
    name          = optional(string)
    repository    = optional(string)
    chart         = optional(string)
    chart_version = optional(string)
    namespace     = optional(string)
    values        = optional(map(string))
  })
  default = {
    enabled       = false
    name          = "prometheus"
    repository    = "https://prometheus-community.github.io/helm-charts"
    chart         = "prometheus"
    chart_version = "25.26.0"
    namespace     = "prometheus"
    values        = {}
  }
}

variable "anyscale_aws_loadbalancer_chart" {
  description = <<-EOT
    (Optional) The Helm chart to install the AWS Load Balancer Controller.

    Requires `cloud_provider` to be set to `aws`.

    ex:
    ```
    anyscale_aws_loadbalancer_chart = {
      enabled       = true
      name          = "aws-load-balancer-controller"
      repository   = "https://aws.github.io/eks-charts"
      chart         = "aws-load-balancer-controller"
      chart_version = "1.2.7"
      namespace     = "kube-system"
      values        = {
        "some.other.config" = "value"
      }
    }
    ```
  EOT
  type = object({
    enabled       = bool
    name          = optional(string)
    repository    = optional(string)
    chart         = optional(string)
    chart_version = optional(string)
    namespace     = optional(string)
    values        = optional(map(string))
  })
  default = {
    enabled       = true
    name          = "aws-load-balancer-controller"
    repository    = "https://aws.github.io/eks-charts"
    chart         = "aws-load-balancer-controller"
    chart_version = "1.11.0"
    namespace     = "kube-system"
    values        = {}
  }
}
