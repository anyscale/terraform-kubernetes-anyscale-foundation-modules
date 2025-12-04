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

# ---------------------------------------------------------------------------------------------------------------------
# OPTIONAL VARIABLES
# These variables have defaults but must be included when using this module.
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
    eks_cluster_version = "1.32"
    ```
  EOT
  type        = string
  default     = "1.32"
}

variable "node_group_gpu_types" {
  description = <<-EOT
    (Optional) The GPU types of the EKS nodes.
    Possible values: ["T4", "A10G"] plus any keys defined in additional_gpu_types
  EOT
  type        = list(string)
  default     = ["T4"]
}

variable "additional_gpu_types" {
  description = <<-EOT
    (Optional) Additional GPU types to add or override in the EKS cluster.
    Entries with the same key as a default (e.g., "T4") will override the default entirely.
    See gpu_instances.tfvars for examples.

    ex:
    ```
    additional_gpu_types = {
      # Override default T4 with more instance types
      "T4" = {
        product_name   = "Tesla-T4"
        instance_types = ["g4dn.xlarge", "g4dn.2xlarge", "g4dn.4xlarge"]
      }
      # Add new GPU type
      "L4" = {
        product_name   = "NVIDIA-L4"
        instance_types = ["g6.2xlarge", "g6.4xlarge"]
      }
    }
    ```
  EOT
  type = map(object({
    product_name   = string
    instance_types = list(string)
  }))
  default = {}
}

variable "enable_efs" {
  description = <<-EOT
    (Optional) Enable the creation of an EFS instance.

    This is optional for Anyscale deployments. EFS is used for shared storage between nodes.

    ex:
    ```
    enable_efs = true
    ```
  EOT
  type        = bool
  default     = false
}
