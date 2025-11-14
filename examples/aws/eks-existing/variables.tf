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
  description = "The AWS region in which all resources will be created."
  type        = string
  default     = "us-east-2"
}

variable "tags" {
  description = "(Optional) A map of tags to all resources that accept tags."
  type        = map(string)
  default = {
    Test        = "true"
    Environment = "dev"
    Repo        = "terraform-kubernetes-anyscale-foundation-modules",
    Example     = "aws/eks-existing"
  }
}

variable "existing_vpc_id" {
  description = <<-EOT
    (Required) Existing VPC ID.
    The ID of an existing VPC to use. This should not be the entire ARN of the VPC, just the ID.
    ex:
    ```
    existing_vpc_id = "vpc-1234567890"
    ```
    ```
  EOT
  type        = string
  validation {
    condition = (
      length(var.existing_vpc_id) > 4 &&
      substr(var.existing_vpc_id, 0, 4) == "vpc-"
    )
    error_message = "The existing_vpc_id must be set and shoudl start with \"vpc-\"."
  }
}

variable "existing_subnet_ids" {
  description = <<-EOT
    (Required) Existing Subnet IDs.
    The IDs of existing subnets to use. This should not be the entire ARN of the subnet, just the ID.
    These subnets should be in the `existing_vpc_id`.
    ex:
    ```
    existing_subnet_ids = ["subnet-1234567890", "subnet-0987654321"]
    ```
  EOT
  type        = list(string)
  validation {
    condition = (
      length(var.existing_subnet_ids) > 0
    )
    error_message = "The existing_subnet_ids must be set and should be a list of subnet IDs."
  }
}

variable "customer_ingress_cidr_ranges" {
  description = <<-EOT
    The IPv4 CIDR block that is allowed to access the clusters.
    This provides the ability to lock down the v1 stack to just the public IPs of a corporate network.
    This is added to the security group and allows port 443 (https) and 22 (ssh) access.
    ex: `52.1.1.23/32,10.1.0.0/16'
  EOT
  type        = string
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
