# ---------------------------------------------------------------------------------------------------------------------
# ENVIRONMENT VARIABLES
# Define these secrets as environment variables
# ---------------------------------------------------------------------------------------------------------------------

# AWS_ACCESS_KEY_ID
# AWS_SECRET_ACCESS_KEY

# ---------------------------------------------------------------------------------------------------------------------
# REQUIRED VARIABLES
# These variables must be set when using this module.
# ---------------------------------------------------------------------------------------------------------------------

variable "aws_region" {
  description = <<-EOT
    (Optional) The AWS region in which all resources will be created.

    ex:
    ```
    aws_region = "us-east-2"
    ```
  EOT
  type        = string
  default     = "us-east-2"
}

variable "tags" {
  description = <<-EOT
    (Optional) A map of tags to all resources that accept tags.

    ex:
    ```
    tags = {
      Environment = "dev"
      Repo        = "terraform-kubernetes-anyscale-foundation-modules",
    }
    ```
  EOT
  type        = map(string)
  default = {
    Test        = "true"
    Environment = "dev"
    Repo        = "terraform-kubernetes-anyscale-foundation-modules",
    Example     = "aws/eks-public"
  }
}

variable "eks_cluster_name" {
  description = <<-EOT
    (Optional) The name of the EKS cluster.

    This will be used for naming resources created by this module including the EKS cluster and the S3 bucket.

    ex:
    ```
    eks_cluster_name = "anyscale-eks-public"
    ```
  EOT
  type        = string
  default     = "anyscale-eks-public"
}

variable "eks_cluster_version" {
  description = <<-EOT
    (Optional) The Kubernetes version of the EKS cluster.

    ex:
    ```
    eks_cluster_version = "1.31"
    ```
  EOT
  type        = string
  default     = "1.31"
}

variable "node_group_gpu_types" {
  description = <<-EOT
    (Optional) The GPU types of the EKS nodes.
    Possible values: ["T4", "A10G"]
  EOT
  type        = list(string)
  default     = ["T4"]
}
