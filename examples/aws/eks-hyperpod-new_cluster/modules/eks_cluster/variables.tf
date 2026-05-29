variable "resource_name_prefix" {
  description = "Prefix to be used for all resources created by this module"
  type        = string
  default     = "sagemaker-hyperpod-eks"
}

variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "vpc_id" {
  description = "The ID of the VPC"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "security_group_id" {
  description = "ID of the security group for the EKS cluster"
  type        = string
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
}

variable "private_node_subnet_cidr" {
  description = "CIDR blocks for private subnets for nodes"
  type        = string
}

variable "nat_gateway_id" {
  description = "ID of the NAT gateway for the EKS cluster"
  type        = string
}

# ----------------------------------------------------------------------------
# System node group sizing.
#
# This managed node group hosts the cluster's system / control components:
# CoreDNS, the AWS Load Balancer Controller (replicaCount: 2), Envoy Gateway,
# and the Anyscale operator. Defaults are sized for HA (>= 2 nodes) and enough
# pod density to also tolerate disabling VPC CNI prefix delegation (the LBC
# pod-ENI workaround). Application/Ray pods do NOT run here — those land on
# HyperPod instance groups via Karpenter.
# ----------------------------------------------------------------------------
variable "system_node_instance_types" {
  description = "Instance types for the EKS system node group. m5.large gives 8 GiB and ~29 max pods, which comfortably fits the system components with HA."
  type        = list(string)
  default     = ["m5.large"]
}

variable "system_node_desired_size" {
  description = "Desired size of the EKS system node group. Keep >= 2 for HA of CoreDNS / LBC / Envoy Gateway / Anyscale operator."
  type        = number
  default     = 2
}

variable "system_node_min_size" {
  description = "Minimum size of the EKS system node group."
  type        = number
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum size of the EKS system node group."
  type        = number
  default     = 3
}
