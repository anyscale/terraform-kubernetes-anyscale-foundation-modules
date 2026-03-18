# ---------------------------------------------------------------------------------------------------------------------
# ENVIRONMENT VARIABLES
# Define these secrets as environment variables
# ---------------------------------------------------------------------------------------------------------------------

# ARM_SUBSCRIPTION_ID
# ARM_CLIENT_ID
# ARM_CLIENT_SECRET
# ARM_TENANT_ID

# ---------------------------------------------------------------------------------------------------------------------
# REQUIRED VARIABLES
# These variables must be set when using this module.
# ---------------------------------------------------------------------------------------------------------------------

variable "azure_subscription_id" {
  description = "(Required) Azure subscription ID"
  type        = string
}

variable "existing_resource_group_name" {
  description = <<-EOT
    (Required) Existing Resource Group name.
    The name of an existing Azure Resource Group where the AKS cluster is deployed.

    ex:
    ```
    existing_resource_group_name = "my-aks-resource-group"
    ```
  EOT
  type        = string
  validation {
    condition     = length(var.existing_resource_group_name) > 0
    error_message = "The existing_resource_group_name must be set."
  }
}

variable "existing_aks_cluster_name" {
  description = <<-EOT
    (Required) Existing AKS cluster name.
    The name of an existing AKS cluster. The cluster must have:
    - OIDC issuer enabled (oidc_issuer_enabled = true)
    - Workload identity enabled (workload_identity_enabled = true)
    - Node pools configured with appropriate taints and labels for Anyscale

    ex:
    ```
    existing_aks_cluster_name = "my-aks-cluster"
    ```
  EOT
  type        = string
  validation {
    condition     = length(var.existing_aks_cluster_name) > 0
    error_message = "The existing_aks_cluster_name must be set."
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# OPTIONAL VARIABLES
# These variables have defaults but may be overridden when using this module.
# ---------------------------------------------------------------------------------------------------------------------

variable "anyscale_cloud_name" {
  description = <<-EOT
    (Optional) Name prefix for Anyscale resources.
    This will be used as a prefix for the Storage Account and other created resources.
    The Storage Account name is this value with hyphens removed plus "sa"; it must be
    globally unique across Azure and 3-24 characters (e.g. "anyscale-prod" -> "anyscaleprodsa").

    ex:
    ```
    anyscale_cloud_name = "anyscale-prod"
    ```
  EOT
  type        = string
  default     = "anyscale"
}

variable "anyscale_operator_namespace" {
  description = "(Optional) Kubernetes namespace for the Anyscale operator."
  type        = string
  default     = "anyscale-operator"
}

variable "tags" {
  description = "(Optional) Tags applied to all taggable resources."
  type        = map(string)
  default = {
    Test        = "true"
    Environment = "dev"
    Repo        = "terraform-kubernetes-anyscale-foundation-modules"
    Example     = "azure/aks-existing"
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
