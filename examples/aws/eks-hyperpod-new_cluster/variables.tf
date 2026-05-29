variable "resource_name_prefix" {
  description = "Prefix to be used for all resources"
  type        = string
  default     = "sagemaker-hyperpod-eks"
}

variable "aws_region" {
  description = "AWS Region to be targeted for deployment"
  type        = string
  default     = "us-west-2"
}

# VPC Module Variables
variable "create_vpc_module" {
  description = "Whether to create VPC module"
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "The IP range (CIDR notation) for the VPC"
  type        = string
  default     = "10.192.0.0/16"
}

variable "public_subnet_1_cidr" {
  description = "The IP range (CIDR notation) for the public subnet in the first Availability Zone"
  type        = string
  default     = "10.192.10.0/24"
}

variable "public_subnet_2_cidr" {
  description = "The IP range (CIDR notation) for the public subnet in the second Availability Zone"
  type        = string
  default     = "10.192.11.0/24"
}

variable "existing_vpc_id" {
  description = "The ID of an existing VPC to use if not creating a new one"
  type        = string
  default     = ""
}

# Private Subnet Module Variables
variable "create_private_subnet_module" {
  description = "Whether to create private subnet module"
  type        = bool
  default     = true
}

variable "availability_zone_id" {
  description = "The Availability Zone Id for private subnet"
  type        = string
  default     = "usw2-az2"
}

variable "private_subnet_cidr" {
  description = "The IP range (CIDR notation) for the private subnet"
  type        = string
  default     = "10.1.0.0/16"
}

variable "existing_nat_gateway_id" {
  description = "The ID of an existing NAT Gateway"
  type        = string
  default     = ""
}

variable "existing_private_subnet_id" {
  description = "The ID of an existing private subnet"
  type        = string
  default     = ""
}

# Security Group Module Variables
variable "create_security_group_module" {
  description = "Whether to create security group module"
  type        = bool
  default     = true
}

variable "existing_security_group_id" {
  description = "The ID of an existing security group"
  type        = string
  default     = ""
}

# EKS Cluster Module Variables
variable "create_eks_module" {
  description = "Whether to create EKS cluster module"
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  description = "The Kubernetes version to use for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "eks_cluster_name" {
  description = "The name of the EKS cluster"
  type        = string
  default     = "sagemaker-hyperpod-eks-cluster"
}

variable "existing_eks_cluster_name" {
  description = "The name of an existing EKS cluster"
  type        = string
  default     = ""
}

variable "eks_private_subnet_1_cidr" {
  description = "The IP range (CIDR notation) for the first EKS private subnet"
  type        = string
  default     = "10.192.7.0/28"
}

variable "eks_private_subnet_2_cidr" {
  description = "The IP range (CIDR notation) for the second EKS private subnet"
  type        = string
  default     = "10.192.8.0/28"
}

variable "eks_private_node_subnet_cidr" {
  description = "The IP range (CIDR notation) for the EKS private node subnet"
  type        = string
  default     = "10.192.9.0/24"
}

# S3 Bucket Module Variables
variable "create_s3_bucket_module" {
  description = "Whether to create S3 bucket module"
  type        = bool
  default     = true
}

variable "existing_s3_bucket_name" {
  description = "The name of an existing S3 bucket"
  type        = string
  default     = ""
}

# S3 Endpoint Module Variables
variable "create_s3_endpoint_module" {
  description = "Whether to create S3 endpoint module"
  type        = bool
  default     = true
}

variable "existing_private_route_table_id" {
  description = "The ID of an existing private route table"
  type        = string
  default     = ""
}

# Lifecycle Script Module Variables
variable "create_lifecycle_script_module" {
  description = "Whether to create lifecycle script module"
  type        = bool
  default     = true
}

# SageMaker IAM Role Module Variables
variable "create_sagemaker_iam_role_module" {
  description = "Whether to create SageMaker IAM role module"
  type        = bool
  default     = true
}

variable "existing_sagemaker_iam_role_name" {
  description = "The name of an existing SageMaker IAM role"
  type        = string
  default     = ""
}

# AWS Load Balancer Controller IAM Role Module Variables
variable "create_aws_lbc_iam_role_module" {
  description = <<-EOT
    (Optional) Whether to create the IAM role consumed by the AWS Load Balancer Controller
    via EKS Pod Identity.

    Required for HyperPod because the LBC must run in IP target mode (instance target mode
    is incompatible with HyperPod's non-standard providerID + cross-account ENIs).
    EOT
  type        = bool
  default     = true
}

# MemoryDB Module Variables (Anyscale head node fault tolerance)
variable "create_memorydb_module" {
  description = <<-EOT
    (Optional) Whether to create an Amazon MemoryDB cluster as the Redis-compatible
    external storage backend for Anyscale head node fault tolerance.

    Anyscale recommends head node fault tolerance for ALL production services.
    Defaults to false because MemoryDB incurs ongoing cost in your account even
    when idle — set this to true for production clouds. Requires create_eks_module
    (the EKS module's multi-AZ private subnets host the MemoryDB subnet group).

    After apply, set the `redis_endpoint` output on the Anyscale cloud resource
    (see the z_next_steps output).
    EOT
  type        = bool
  default     = false
}

variable "memorydb_node_type" {
  description = "MemoryDB node type for the head node fault tolerance cluster."
  type        = string
  default     = "db.t4g.small"
}

# Helm Chart Module Variables
variable "create_helm_chart_module" {
  description = "Whether to create Helm chart module"
  type        = bool
  default     = true
}

variable "helm_repo_path" {
  description = "The path to the HyperPod Helm chart"
  type        = string
  default     = "helm_chart/HyperPodHelmChart"
}

variable "namespace" {
  description = "The Kubernetes namespace"
  type        = string
  default     = "kube-system"
}

variable "helm_release_name" {
  description = "The name of the Helm release"
  type        = string
  default     = "hyperpod-dependencies"
}

# HyperPod Cluster Module Variables
variable "create_hyperpod_module" {
  description = "Whether to create HyperPod cluster module"
  type        = bool
  default     = true
}

variable "hyperpod_cluster_name" {
  description = "Name of the HyperPod cluster"
  type        = string
  default     = "ml-cluster"
}

variable "node_recovery" {
  description = "Specifies whether to enable or disable the automatic node recovery feature"
  type        = string
  default     = "Automatic"
  validation {
    condition     = contains(["Automatic", "None"], var.node_recovery)
    error_message = "Node recovery must be either 'Automatic' or 'None'"
  }
}

variable "node_provisioning_mode" {
  description = "Determines the scaling strategy for the SageMaker HyperPod cluster. When set to 'Continuous', enables continuous scaling which dynamically manages node provisioning. Set to null to disable continuous provisioning and use standard scaling approach."
  type        = string
  default     = "Continuous"
  validation {
    condition     = var.node_provisioning_mode == null || var.node_provisioning_mode == "Continuous"
    error_message = "Node provisioning mode must be either 'Continuous' or null"
  }
}

variable "instance_groups" {
  description = "Map of instance group configurations"
  type = map(object({
    instance_type             = string
    instance_count            = number
    ebs_volume_size_in_gb     = number
    threads_per_core          = number
    enable_stress_check       = bool
    enable_connectivity_check = bool
    lifecycle_script          = string
    image_id                  = optional(string)
    training_plan_arn         = optional(string)
  }))
  default = {}
}

variable "restricted_instance_groups" {
  description = "Map of restricted instance group configurations"
  type = map(object({
    instance_type                    = string
    instance_count                   = number
    ebs_volume_size_in_gb            = number
    threads_per_core                 = number
    enable_stress_check              = bool
    enable_connectivity_check        = bool
    fsxl_per_unit_storage_throughput = number
    fsxl_size_in_gi_b                = number
    training_plan_arn                = optional(string)
  }))
  default = {}
}

variable "anyscale_new_cloud_name" {
  type        = string
  description = "Name of the new Anyscale cloud (used in the rendered `anyscale cloud register` command output)."
}

variable "anyscale_operator_namespace" {
  description = <<-EOT
    (Optional) Kubernetes namespace where the Anyscale Operator runs.

    Used for both the EKS Pod Identity association (which maps the
    `anyscale-operator` service account in this namespace to the SageMaker
    execution IAM role) and the rendered Helm install commands.
    EOT
  type        = string
  default     = "anyscale-operator"
}

