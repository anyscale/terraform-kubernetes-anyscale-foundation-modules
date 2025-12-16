# ------------------------------------------------------------------------------
# REQUIRED PARAMETERS
# These variables must be set when using this module.
# ------------------------------------------------------------------------------
variable "cloud_provider" {
  description = <<-EOT
    (Required) The cloud provider (aws or azure or gcp)

    ex:
    ```
    cloud_provider = "azure"
    ```
  EOT
  type        = string
  validation {
    condition = (
      var.cloud_provider == "aws" || var.cloud_provider == "azure" || var.cloud_provider == "gcp"
    )
    error_message = "The cloud_provider only allows `aws` or `azure` or `gcp`"
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

# ------------------
# AWS Related
# ------------------
variable "aws_dataplane_role_arn" {
  description = <<-EOT
    (Optional) The ARN of the AWS IAM role that will be used by the EKS cluster to access AWS services.

    Required if `cloud_provider` is set to `aws`.

    ex:
    ```
    aws_dataplane_role_arn = "arn:aws:iam::123456789012:role/my-eks-dataplane-role"
    ```
  EOT
  type        = string
  default     = null
}
variable "aws_controlplane_role_arn" {
  description = <<-EOT
    (Optional) The ARN of the AWS IAM role that will be used by the EKS cluster to access AWS services.

    Required if `cloud_provider` is set to `aws`.

    ex:
    ```
    aws_controlplane_role_arn = "arn:aws:iam::123456789012:role/my-eks-controlplane-role"
    ```
  EOT
  type        = string
  default     = null
}
