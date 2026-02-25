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
