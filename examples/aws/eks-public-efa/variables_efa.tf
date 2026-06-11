variable "efa_capacity_reservation_id" {
  description = "(Optional) Targeted EC2 Capacity Reservation ID for the p5.48xlarge EFA node group."
  type        = string
  default     = null
}

variable "efa_capacity_reservation_az_id" {
  description = "(Optional) Availability Zone ID for the targeted EFA capacity reservation, for example use1-az3."
  type        = string
  default     = null
}

variable "efa_workload_name" {
  description = "(Optional) Workload name used for the P5/H100 EFA node group name, labels, taints, and Cluster Autoscaler template tags."
  type        = string
  default     = "h100-efa"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.efa_workload_name))
    error_message = "efa_workload_name must be lowercase DNS-style text: letters, numbers, hyphens, no leading/trailing hyphen."
  }
}

variable "efa_private_subnet_cidr" {
  description = "(Optional) CIDR block for the private EFA subnet created in the capacity reservation AZ."
  type        = string
  default     = "172.24.22.0/24"
}
