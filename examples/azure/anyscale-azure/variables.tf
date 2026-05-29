variable "azure_subscription_id" {
  description = "(Required) Azure subscription ID"
  type        = string
}

variable "azure_location" {
  description = "(Optional) Azure region for all resources."
  type        = string
  default     = "West US"
}

variable "azure_tenant_id" {
  description = "Azure tenant ID. Can be found by running `az account show --query tenantId -o tsv`."
  type        = string
}

variable "tags" {
  description = "(Optional) Tags applied to all taggable resources."
  type        = map(string)
  default = {
    Test        = "true"
    Environment = "dev"
  }
}

variable "aks_cluster_name" {
  description = "(Optional) Name of the AKS cluster (and related resources)."
  type        = string
  default     = "anyscale-demo"
}

variable "azure_resource_group_name" {
  description = <<-EOT
    Resource group name. This variable has no default, so `terraform plan`/`apply`
    prompts for it interactively unless you supply it via terraform.tfvars, -var,
    or TF_VAR_azure_resource_group_name. Enter an empty value to fall back to
    "<aks_cluster_name>-rg".
  EOT
  type        = string
  nullable    = false
}

variable "anyscale_cloud_name" {
  description = <<-EOT
    Anyscale cloud name as it appears in the Anyscale console. This variable has
    no default, so `terraform plan`/`apply` prompts for it interactively unless
    you supply it via terraform.tfvars, -var, or TF_VAR_anyscale_cloud_name.
    Enter an empty value to fall back to "<aks_cluster_name>-cloud".
  EOT
  type        = string
  nullable    = false
}

variable "anyscale_operator_namespace" {
  description = "(Optional) Kubernetes namespace for the Anyscale operator."
  type        = string
  default     = "anyscale-operator"
}

variable "vnet_cidr" {
  description = "(Optional) CIDR block for the VNet."
  type        = string
  nullable    = false
  default     = "10.42.0.0/16"
}

variable "nodes_subnet_cidr" {
  description = "(Optional) CIDR block for the AKS nodes subnet."
  type        = string
  nullable    = false
  default     = "10.42.1.0/24"
}

variable "aks_cluster_subnet_cidr" {
  description = "(Optional) CIDR block for the AKS cluster service subnet. Cannot overlap with vnet_cidr or nodes_subnet_cidr."
  type        = string
  nullable    = false
  default     = "10.0.0.0/16"
}

variable "aks_cluster_dns_address" {
  description = "(Optional) DNS address for the AKS cluster. If not set, a default will be generated from aks_cluster_subnet_cidr."
  type        = string
  nullable    = true
  default     = null
}

variable "enable_blob_driver" {
  description = "(Optional) Enable the Azure Blob CSI driver on the AKS cluster. Required for mounting blob storage from pods."
  type        = bool
  nullable    = false
  default     = false
}

variable "enable_operator_infrastructure" {
  description = <<-EOT
    (Optional) Enable blob storage, managed identity, federated identity credential,
    role assignment, and output registration/helm commands for the Anyscale operator.
    Set to false when using the Azure control plane, which provisions these via ARM templates.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "storage_account_name" {
  description = "(Optional) Name of the Azure Storage account to create for cloud storage. May be needed if generated name is already taken."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.storage_account_name == null || can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Storage account name must be between 3 and 24 characters long and contain only lowercase letters and numbers."
  }
}

variable "enable_nfs" {
  description = <<-EOT
    (Optional) Enable provisioning of an Azure NFS (Network File System) storage account.
    This NFS storage can be used for file-based persistent storage needs, mounting shared volumes to AKS nodes and pods.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "storage_account_name_nfs" {
  description = "(Optional) Name of the Azure NFS storage account to create. May be needed if generated name is already taken."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.storage_account_name_nfs == null || can(regex("^[a-z0-9]{3,24}$", var.storage_account_name_nfs))
    error_message = "NFS storage account name must be between 3 and 24 characters long and contain only lowercase letters and numbers."
  }
}

variable "system_vm_size" {
  description = "VM size for the default system node pool."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "cpu_vm_size" {
  description = "VM size for the CPU node pools (on-demand and spot)."
  type        = string
  default     = "Standard_D16s_v5"
}

variable "gpu_pool_configs" {
  description = <<-EOT
    (Optional) Full configuration for GPU node pools. The map key is a logical label
    (e.g. "T4", "A100"). The `name` field is used as the AKS node pool name and must
    be lowercase alphanumeric, max 8 chars (spot pools append "spot").
  EOT
  type = map(object({
    name         = string
    vm_size      = string
    product_name = string
    gpu_count    = string
  }))
  default = {
    T4 = {
      name         = "gput4"
      vm_size      = "Standard_NC16as_T4_v3"
      product_name = "NVIDIA-T4"
      gpu_count    = "1"
    }
    A100 = {
      name         = "gpua100"
      vm_size      = "Standard_NC24ads_A100_v4"
      product_name = "NVIDIA-A100"
      gpu_count    = "1"
    }
    # Example of adding new GPU pools:
    # A10 = {
    #   name         = "gpua10"
    #   vm_size      = "Standard_NV36ads_A10_v5"
    #   product_name = "NVIDIA-A10"
    #   gpu_count    = "1"
    # }
    # H100 = {
    #   name         = "h100x8"
    #   vm_size      = "Standard_ND96isr_H100_v5"
    #   product_name = "NVIDIA-H100"
    #   gpu_count    = "8"
    # }
  }

  validation {
    condition = alltrue([
      for k, v in var.gpu_pool_configs : can(regex("^[a-z0-9]{1,8}$", v.name))
    ])
    error_message = "gpu_pool_configs name must be lowercase alphanumeric, max 8 characters (spot pools append 'spot' for a 12-char AKS limit)."
  }

  validation {
    condition = alltrue([
      for k, v in var.gpu_pool_configs : can(regex("^[1-9][0-9]*$", v.gpu_count))
    ])
    error_message = "gpu_pool_configs gpu_count must be a positive integer string (e.g. \"1\", \"8\")."
  }
}

variable "cors_rule" {
  description = <<-EOT
    (Optional)
    Object containing a rule of Cross-Origin Resource Sharing.
    The default allows GET, POST, PUT, HEAD, and DELETE
    access for the purpose of viewing logs and other functionality
    from within the Anyscale Web UI (*.anyscale.com).

    ex:
    ```
    cors_rule = {
      allowed_headers = ["*"]
      allowed_methods = ["GET", "POST", "PUT", "HEAD", "DELETE"]
      allowed_origins = ["https://*.anyscale.com"]
      expose_headers  = ["Accept-Ranges", "Content-Range", "Content-Length"]
    }
    ```
  EOT
  type = object({
    allowed_headers    = list(string)
    allowed_methods    = list(string)
    allowed_origins    = list(string)
    expose_headers     = list(string)
    max_age_in_seconds = optional(number, 0)
  })
  default = {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "POST", "PUT", "HEAD", "DELETE"]
    allowed_origins = ["https://*.anyscale.com"]
    expose_headers  = ["Accept-Ranges", "Content-Range", "Content-Length"]
  }
}

variable "storage_use_azuread" {
  description = "(Optional) Determines whether the provider uses AzureAD or the SharedKey from the Storage Account to connect to the Storage Blob & Queue APIs"
  type        = bool
  nullable    = false
  default     = false
}

variable "anyscale_operator_serviceaccount" {
  description = "(Optional) Kubernetes service account name the Anyscale operator runs as. The federated identity credential in aks.tf is bound to this service account name."
  type        = string
  default     = "anyscale-operator"
}

###############################################################################
# Azure Container Registry — for Anyscale workload images
###############################################################################
variable "enable_acr" {
  description = "(Optional) Create a customer-owned ACR for Anyscale workload images and grant the AKS kubelet identity AcrPull. Disable if you supply your own registry out-of-band."
  type        = bool
  nullable    = false
  default     = true
}

variable "acr_name" {
  description = "(Optional) Override the generated ACR name. Globally unique; 5-50 alphanumeric chars."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.acr_name == null || can(regex("^[a-zA-Z0-9]{5,50}$", var.acr_name))
    error_message = "ACR name must be 5-50 alphanumeric characters."
  }
}

variable "acr_sku" {
  description = "(Optional) ACR SKU. Premium is only required for Private Link / zone redundancy / customer-managed keys."
  type        = string
  nullable    = false
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "acr_sku must be one of Basic, Standard, or Premium."
  }
}

variable "acr_zone_redundancy_enabled" {
  description = "(Optional) Enable zone redundancy on the ACR. Premium SKU only; ignored on Basic/Standard."
  type        = bool
  nullable    = false
  default     = false
}

###############################################################################
# Anyscale platform (Azure-managed control plane)
# These inputs drive the ARM `Anyscale.Platform/clouds` deployment and the
# `Anyscale.AKS.Operator` AKS extension. Defaults target
# https://console.azure.anyscale.com and the marketplace `anyscale-operator`
# plan — only override if you are testing against a non-default control plane.
###############################################################################
variable "anyscale_platform" {
  description = "(Optional) Tunables for the Anyscale.Platform/clouds ARM deployment and the Anyscale.AKS.Operator AKS extension."
  type = object({
    extension_resource_name          = optional(string, "anyscaleoperator")
    control_plane_url                = optional(string, "https://console.azure.anyscale.com")
    auth_audience                    = optional(string, "api://086bc555-6989-4362-ba30-fded273e432b/.default")
    extension_configuration_settings = optional(map(string), {})
    plan_name                        = optional(string, "anyscale-operator")
    plan_publisher                   = optional(string, "anyscale1750870039553")
    plan_product                     = optional(string, "anyscale-operator-aks")
    release_train                    = optional(string, "stable")
    tags_by_resource                 = optional(map(map(string)), {})
  })
  default = {}
}

variable "anyscale_platform_contributors" {
  description = <<-EOT
    (Optional) Principals (users, groups, or service principals) to grant the
    "Anyscale Platform Contributor" role on the Anyscale cloud resource.

    IMPORTANT: Subscription Owner/Contributor on the underlying Azure resources
    does NOT carry over to the Anyscale resource provider. Creating Anyscale
    workspaces, jobs, or services requires this explicit Anyscale platform role
    on the cloud resource itself.

    Each entry needs the principal's object (principal) ID and its type
    (User | Group | ServicePrincipal). Example:

      anyscale_platform_contributors = [
        { principal_id = "00000000-0000-0000-0000-000000000000", principal_type = "User" },
        { principal_id = "11111111-1111-1111-1111-111111111111", principal_type = "Group" },
      ]
  EOT
  type = list(object({
    principal_id   = string
    principal_type = optional(string, "User")
  }))
  default = []

  validation {
    condition     = alltrue([for c in var.anyscale_platform_contributors : contains(["User", "Group", "ServicePrincipal"], c.principal_type)])
    error_message = "principal_type must be one of: User, Group, ServicePrincipal."
  }
}

###############################################################################
# Envoy Gateway bootstrap
# Anyscale routes workspace and service traffic through an in-cluster Envoy
# Gateway. Defaults match the upstream Anyscale quickstart for AKS.
###############################################################################
variable "envoy_gateway" {
  description = "(Optional) Envoy Gateway install knobs."
  type = object({
    namespace                        = optional(string, "envoy-gateway-system")
    release_name                     = optional(string, "eg")
    chart_version                    = optional(string, "v1.7.0")
    gateway_class_name               = optional(string, "eg")
    gateway_name                     = optional(string, "gateway")
    gateway_lb_wait_timeout_seconds  = optional(number, 600)
    gateway_lb_poll_interval_seconds = optional(number, 10)
  })
  default = {}
}

# NOTE: there is intentionally no kubeconfig_path variable. The
# kubernetes/helm/kubectl providers authenticate directly from the AKS
# cluster's admin cert attributes (see versions.tf), and the gateway-LB shell
# steps use an isolated ${path.module}/.kubeconfig written by
# terraform_data.aks_credentials. Nothing depends on ~/.kube/config, so the
# whole stack deploys in a single `terraform apply` regardless of what other
# kube contexts exist on the workstation.