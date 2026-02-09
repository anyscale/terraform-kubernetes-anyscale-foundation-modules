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
