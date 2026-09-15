variable "region" {
  description = "AWS region."
  type        = string
}

variable "cluster_name" {
  description = "Existing EKS cluster name."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the EFA node group."
  type        = string
}

variable "subnet_id" {
  description = "Single private subnet ID in the target Availability Zone."
  type        = string
}

variable "availability_zone" {
  description = "Availability Zone expected for subnet_id."
  type        = string
  default     = null
}

variable "node_role_arn" {
  description = "IAM role ARN for EKS worker nodes."
  type        = string
}

variable "desired_size" {
  description = "Desired node count."
  type        = number
  default     = 4
}

variable "min_size" {
  description = "Minimum node count."
  type        = number
  default     = 0
}

variable "max_size" {
  description = "Maximum node count."
  type        = number
  default     = 4
}

variable "cluster_security_group_ids" {
  description = "EKS control-plane or cluster security group IDs allowed to reach EFA nodes."
  type        = list(string)
  default     = []
}

variable "additional_security_group_ids" {
  description = "Additional security groups attached to launch-template network interfaces."
  type        = list(string)
  default     = []
}

variable "capacity_type" {
  description = "EKS capacity type."
  type        = string
  default     = "ON_DEMAND"
}

variable "capacity_reservation_id" {
  description = "Capacity Block reservation ID when capacity_type is CAPACITY_BLOCK."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to resources."
  type        = map(string)
  default     = {}
}
