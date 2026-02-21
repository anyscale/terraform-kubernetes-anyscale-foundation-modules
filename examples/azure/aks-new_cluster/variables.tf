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

variable "node_group_gpu_types" {
  description = <<-EOT
    (Optional) The GPU types of the AKS nodes.
    Possible values: ["T4", "A10", "A100", "H100"]
  EOT
  type        = list(string)
  default     = ["T4", "A100"]

  validation {
    condition = alltrue(
      [for g in var.node_group_gpu_types : contains(["T4", "A10", "A100", "H100"], g)]
    )
    error_message = "GPU type must be one of: T4, A10, A100, H100."
  }
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

  validation {
    condition = !anytrue([
      cidrcontains(var.vnet_cidr, cidrhost(var.aks_cluster_subnet_cidr, 0)),
      cidrcontains(var.aks_cluster_subnet_cidr, cidrhost(var.vnet_cidr, 0)),
      cidrcontains(var.nodes_subnet_cidr, cidrhost(var.aks_cluster_subnet_cidr, 0)),
      cidrcontains(var.aks_cluster_subnet_cidr, cidrhost(var.nodes_subnet_cidr, 0)),
    ])
    error_message = "aks_cluster_subnet_cidr must not overlap with vnet_cidr or nodes_subnet_cidr."
  }
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
  description = "(Optional) Enable NFS storage account."
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
