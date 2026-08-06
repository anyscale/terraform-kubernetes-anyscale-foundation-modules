variable "project_id" {
  description = "Google Cloud project ID."
  type        = string
}

variable "region" {
  description = "Regional GKE control-plane location."
  type        = string
}

variable "zone" {
  description = "Single A4/B200 worker zone."
  type        = string
}

variable "cluster_name" {
  description = "Name of the GKE cluster to create."
  type        = string
}

variable "host_network" {
  description = "Existing host/control-plane VPC name or self link for the GKE cluster."
  type        = string
}

variable "host_subnetwork" {
  description = "Existing host/control-plane subnetwork name or self link for the GKE cluster."
  type        = string
}

variable "gvnic_network_name" {
  description = "Dedicated VPC name for the extra Titanium gVNIC."
  type        = string
}

variable "gvnic_subnetwork_name" {
  description = "Subnetwork name for the extra Titanium gVNIC."
  type        = string
}

variable "gvnic_subnetwork_cidr" {
  description = "CIDR for the extra gVNIC subnetwork."
  type        = string
}

variable "rdma_network_name" {
  description = "Dedicated RoCE RDMA VPC name."
  type        = string
}

variable "rdma_subnetwork_name_prefix" {
  description = "Prefix for RDMA subnet names."
  type        = string
}

variable "rdma_subnetwork_cidr_prefix" {
  description = "First two octets for RDMA subnets."
  type        = string
}

variable "worker_node_count" {
  description = "A4/B200 worker node count."
  type        = number
}

variable "workload_name" {
  description = "Workload name used in default Kubernetes labels."
  type        = string
}

variable "resource_labels" {
  description = "Google Cloud resource labels applied to resources that support labels."
  type        = map(string)
  default     = {}
}
