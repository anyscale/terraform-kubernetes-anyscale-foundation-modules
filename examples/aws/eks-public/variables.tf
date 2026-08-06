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

    Default tracks the latest version available on EKS Standard support.
    Envoy Gateway v1.7.0 requires Kubernetes >= 1.30.

    ex:
    ```
    eks_cluster_version = "1.35"
    ```
  EOT
  type        = string
  default     = "1.35"
}

variable "gpu_instance_types" {
  description = <<-EOT
    (Optional) GPU types configuration for the EKS cluster.
    See gpu_instances.tfvars.example for additional GPU types.

    ex:
    ```
    gpu_instance_types = {
      "T4" = {
        product_name   = "Tesla-T4"
        instance_types = ["g4dn.xlarge", "g4dn.2xlarge", "g4dn.4xlarge"]
      }
      "A10G" = {
        product_name   = "NVIDIA-A10G"
        instance_types = ["g5.4xlarge"]
      }
    }
    ```
  EOT
  type = map(object({
    product_name   = string
    instance_types = list(string)
  }))
  default = {
    "T4" = {
      product_name   = "Tesla-T4"
      instance_types = ["g4dn.4xlarge"]
    }
  }
}

variable "node_group_disk_size" {
  description = <<-EOT
    (Optional) The disk size (GB) of the EKS nodes.
    Possible values: [500, 1000]

    ex:
    ```
    node_group_disk_size = 1000
    ```
  EOT
  type        = number
  default     = 500
}

variable "enable_efs" {
  description = <<-EOT
    (Optional) Enable the creation of an EFS instance.

    Provisions an EFS file system as Anyscale shared storage. Typically an alternative to `enable_s3_pvc`: only one backend is normally attached to an Anyscale cloud at a time.

    ex:
    ```
    enable_efs = true
    ```
  EOT
  type        = bool
  default     = false
}

variable "bucket_force_destroy" {
  description = <<-EOT
    (Optional) When true, `terraform destroy` will delete the Anyscale S3 bucket
    even if it still contains objects (operator logs, cluster metadata, mounted
    PVC data, etc.). Default is `false` so accidental destroys do not wipe data.

    Set to `true` for ephemeral dev / e2e test deployments where you want
    teardown to be one command. See `dev-overrides.tfvars.example` for a ready-made
    override file.

    ex:
    ```
    bucket_force_destroy = true
    ```
  EOT
  type        = bool
  default     = false
}

variable "anyscale_cloud_name" {
  description = <<-EOT
    (Optional) Anyscale cloud name passed to `anyscale cloud register --name`.

    Pick a name that is unique within your Anyscale organization.

    ex:
    ```
    anyscale_cloud_name = "my-eks-public-cloud"
    ```
  EOT
  type        = string
  default     = "anyscale-eks-public"
}

variable "enable_s3_pvc" {
  description = <<-EOT
    (Optional) Provision the IAM role + EKS Pod Identity association for the Mountpoint for Amazon S3 CSI driver, and render a `generated/pv-pvc.yaml` that mounts the Anyscale S3 bucket as a PersistentVolumeClaim used as Anyscale shared storage.

    The CSI driver itself is installed via the `aws-mountpoint-s3-csi-driver` EKS managed addon. This is the AWS analogue of the Azure blob PVC pattern documented at https://docs.anyscale.com/clouds/azure/pvc — wired up at registration time via `file_storage.persistent_volume_claim` rather than via post-hoc `anyscale cloud update`.

    ex:
    ```
    enable_s3_pvc = true
    ```
  EOT
  type        = bool
  default     = true
}

variable "enable_memorydb" {
  description = <<-EOT
    (Optional) Provision an AWS MemoryDB (Redis) cluster in the private subnets via the `aws-anyscale-memorydb` cloudfoundation submodule, and emit its endpoint as `kubernetes_config.redis_endpoint` in the rendered cloud-resource YAML.

    This wires Anyscale Services head-node fault tolerance (Anyscale CLI/SDK >= 0.26.99 required).

    Default is `true` for this example. Set to `false` if you want to skip MemoryDB provisioning and ongoing cost.

    ex:
    ```
    enable_memorydb = false
    ```
  EOT
  type        = bool
  default     = true
}

variable "memorydb_node_type" {
  description = <<-EOT
    (Optional) MemoryDB node type. Only used when `enable_memorydb = true`.

    See https://docs.aws.amazon.com/memorydb/latest/devguide/nodes.supportedtypes.html.

    ex:
    ```
    memorydb_node_type = "db.r7g.large"
    ```
  EOT
  type        = string
  default     = "db.t4g.small"
}

variable "memorydb_num_shards" {
  description = <<-EOT
    (Optional) Number of MemoryDB shards. Only used when `enable_memorydb = true`.
  EOT
  type        = number
  default     = 1
}

variable "memorydb_num_replicas_per_shard" {
  description = <<-EOT
    (Optional) Number of replicas per MemoryDB shard. Only used when `enable_memorydb = true`.
  EOT
  type        = number
  default     = 1
}

variable "memorydb_port" {
  description = <<-EOT
    (Optional) Port on which the MemoryDB cluster listens. Only used when `enable_memorydb = true`.
  EOT
  type        = number
  default     = 6379
}
