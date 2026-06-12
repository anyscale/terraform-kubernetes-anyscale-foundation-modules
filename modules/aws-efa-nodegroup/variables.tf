# ------------------------------------------------------------------------------
# REQUIRED PARAMETERS
# ------------------------------------------------------------------------------

variable "cluster_name" {
  description = "(Required) Name of the existing EKS cluster."
  type        = string
}

variable "vpc_id" {
  description = "(Required) VPC ID where the EKS worker nodes and EFA security group are created."
  type        = string
}

variable "subnet_id" {
  description = "(Required) Single subnet ID for the EFA managed node group. Use a private subnet in one Availability Zone."
  type        = string
}

variable "node_role_arn" {
  description = "(Required) IAM role ARN for the EKS managed node group workers."
  type        = string
}

# ------------------------------------------------------------------------------
# OPTIONAL PARAMETERS
# ------------------------------------------------------------------------------

variable "name_prefix" {
  description = "(Optional) Prefix used for generated resource names."
  type        = string
  default     = null
}

variable "workload_name" {
  description = "(Optional) Workload name used in default resource names, Kubernetes labels, taints, and Cluster Autoscaler template tags."
  type        = string
  default     = "h100-efa"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.workload_name))
    error_message = "workload_name must be lowercase DNS-style text: letters, numbers, hyphens, no leading/trailing hyphen."
  }
}

variable "workload_label_key" {
  description = "(Optional) Kubernetes label and taint key used to isolate this P5/H100 EFA node group."
  type        = string
  default     = "workload"
}

variable "tags" {
  description = "(Optional) Tags applied to resources that support tags."
  type        = map(string)
  default     = {}
}

variable "availability_zone" {
  description = "(Optional) Expected Availability Zone for subnet_id. When set, the module verifies the subnet is in this AZ."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "(Optional) EFA-capable GPU instance type for the node group."
  type        = string
  default     = "p5.48xlarge"
}

variable "desired_size" {
  description = "(Optional) Desired number of EFA worker nodes."
  type        = number
  default     = 4
}

variable "min_size" {
  description = "(Optional) Minimum number of EFA worker nodes."
  type        = number
  default     = 0
}

variable "max_size" {
  description = "(Optional) Maximum number of EFA worker nodes."
  type        = number
  default     = 4
}

variable "ami_type" {
  description = "(Optional) EKS managed node group AMI type. Ignored when ami_id is set in the launch template."
  type        = string
  default     = "AL2023_x86_64_NVIDIA"
}

variable "ami_id" {
  description = "(Optional) Custom AMI ID for the launch template. If set, provide bootstrap-compatible user data outside this module if needed."
  type        = string
  default     = null
}

variable "capacity_type" {
  description = "(Optional) EKS managed node group capacity type."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT", "CAPACITY_BLOCK"], var.capacity_type)
    error_message = "capacity_type must be one of ON_DEMAND, SPOT, or CAPACITY_BLOCK."
  }
}

variable "capacity_reservation_id" {
  description = "(Optional) Targeted EC2 Capacity Reservation ID. Required when capacity_type is CAPACITY_BLOCK; also usable with ON_DEMAND targeted reservations."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "(Optional) Root EBS volume size in GiB."
  type        = number
  default     = 300
}

variable "root_volume_type" {
  description = "(Optional) Root EBS volume type."
  type        = string
  default     = "gp3"
}

variable "root_volume_encrypted" {
  description = "(Optional) Whether to encrypt the root EBS volume."
  type        = bool
  default     = true
}

variable "root_block_device_name" {
  description = "(Optional) Root block device name for the EKS optimized AMI."
  type        = string
  default     = "/dev/xvda"
}

variable "labels" {
  description = "(Optional) Additional or overriding Kubernetes labels for the managed node group. The module supplies P5/H100/EFA defaults."
  type        = map(string)
  default     = {}
}

variable "taints" {
  description = <<-EOT
    (Optional) Kubernetes taints for the managed node group.

    Effects must use AWS EKS API values: NO_SCHEDULE, NO_EXECUTE, or PREFER_NO_SCHEDULE.
  EOT
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default  = null
  nullable = true

  validation {
    condition = (
      var.taints == null ||
      alltrue([
        for taint in var.taints :
        contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], taint.effect)
      ])
    )
    error_message = "taints effects must be one of NO_SCHEDULE, NO_EXECUTE, or PREFER_NO_SCHEDULE."
  }
}

variable "enable_cluster_autoscaler_tags" {
  description = "(Optional) Whether to add Cluster Autoscaler node-template tags for the P5/H100/EFA labels, taints, and resources."
  type        = bool
  default     = true
}

variable "update_max_unavailable" {
  description = "(Optional) Maximum unavailable nodes during managed node group updates."
  type        = number
  default     = 1
}

variable "placement_group_name" {
  description = "(Optional) Explicit placement group name. Defaults to a name derived from name_prefix."
  type        = string
  default     = null
}

variable "launch_template_name_prefix" {
  description = "(Optional) Explicit launch template name prefix."
  type        = string
  default     = null
}

variable "node_group_name" {
  description = "(Optional) Explicit EKS managed node group name."
  type        = string
  default     = null
}

variable "create_efa_security_group" {
  description = "(Optional) Whether to create the EFA security group."
  type        = bool
  default     = true
}

variable "efa_security_group_id" {
  description = "(Optional) Existing EFA security group ID to use when create_efa_security_group is false."
  type        = string
  default     = null
}

variable "efa_security_group_name" {
  description = "(Optional) Name for the EFA security group."
  type        = string
  default     = null
}

variable "efa_security_group_name_prefix" {
  description = "(Optional) Name prefix for the EFA security group."
  type        = string
  default     = null
}

variable "revoke_security_group_rules_on_delete" {
  description = "(Optional) Whether Terraform revokes security group rules before deleting the EFA security group."
  type        = bool
  default     = false
}

variable "allow_all_egress" {
  description = "(Optional) Whether to allow outbound IPv4 traffic from the EFA security group."
  type        = bool
  default     = true
}

variable "cluster_security_group_ids" {
  description = "(Optional) EKS control-plane or cluster security group IDs allowed to initiate traffic to EFA nodes."
  type        = list(string)
  default     = []
}

variable "additional_security_group_ids" {
  description = "(Optional) Additional security group IDs attached to every launch-template network interface, such as an existing Anyscale/EKS node security group."
  type        = list(string)
  default     = []
}

variable "efa_interface_count" {
  description = "(Optional) Number of EFA-only interfaces to generate when network_interfaces is not supplied. p5.48xlarge supports 32."
  type        = number
  default     = 32

  validation {
    condition     = var.efa_interface_count >= 1
    error_message = "efa_interface_count must be at least 1."
  }
}

variable "network_interfaces" {
  description = <<-EOT
    (Optional) Override launch-template network interface layout.

    Leave null for the p5.48xlarge one-IP layout:
    card 0 device 0 interface, card 0 device 1 efa-only, cards 1..31 device 0 efa-only.
  EOT
  type = list(object({
    network_card_index = number
    device_index       = number
    interface_type     = string
  }))
  default = null
}
