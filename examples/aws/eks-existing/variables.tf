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

variable "enable_memorydb" {
  description = <<-EOT
    (Optional) Provision an AWS MemoryDB (Redis) cluster in the existing
    subnets via the `aws-anyscale-memorydb` cloudfoundation submodule, and
    emit its endpoint so it can be registered with the Anyscale cloud as
    `kubernetes_config.redis_endpoint` (Anyscale CLI/SDK >= 0.26.99 required).

    When `true`, you must also set `memorydb_allowed_security_group_ids` to a
    list containing your EKS managed-node-group security group id(s) — that's
    what gates ingress to the MemoryDB SG.

    ex:
    ```
    enable_memorydb = true
    ```
  EOT
  type        = bool
  default     = false
}

variable "memorydb_allowed_security_group_ids" {
  description = <<-EOT
    (Optional) Security group IDs allowed ingress to the MemoryDB cluster on
    `memorydb_port`. Should be your EKS managed-node-group security group(s).
    Required when `enable_memorydb = true`.

    ex:
    ```
    memorydb_allowed_security_group_ids = ["sg-0123456789abcdef0"]
    ```
  EOT
  type        = list(string)
  default     = []
}

variable "memorydb_node_type" {
  description = <<-EOT
    (Optional) MemoryDB node type. Only used when `enable_memorydb = true`.
    See https://docs.aws.amazon.com/memorydb/latest/devguide/nodes.supportedtypes.html.
  EOT
  type        = string
  default     = "db.t4g.small"
}

variable "memorydb_num_shards" {
  description = "(Optional) Number of MemoryDB shards. Only used when `enable_memorydb = true`."
  type        = number
  default     = 1
}

variable "memorydb_num_replicas_per_shard" {
  description = "(Optional) Number of replicas per MemoryDB shard. Only used when `enable_memorydb = true`."
  type        = number
  default     = 1
}

variable "memorydb_port" {
  description = "(Optional) Port the MemoryDB cluster listens on. Only used when `enable_memorydb = true`."
  type        = number
  default     = 6379
}

variable "enable_s3_pvc" {
  description = <<-EOT
    (Optional) Provision the IAM role used by the Mountpoint for Amazon S3 CSI
    driver pods, and render a `generated/pv-pvc.yaml` that mounts the Anyscale S3
    bucket as a PersistentVolumeClaim used as Anyscale shared storage.

    Because this example brings its own EKS cluster, Terraform only creates the
    IAM role here. You then install the Mountpoint-S3 CSI driver and bind the
    role to the `s3-csi-driver-sa` service account via two `aws eks` CLI calls
    (see the README's "Optional: S3 PVC Plugin" section).

    Mirrors the Azure blob PVC pattern documented at
    https://docs.anyscale.com/clouds/azure/pvc, wired up at registration time
    via `--persistent-volume-claim anyscale-shared-fuse`.

    ex:
    ```
    enable_s3_pvc = true
    ```
  EOT
  type        = bool
  default     = false
}
