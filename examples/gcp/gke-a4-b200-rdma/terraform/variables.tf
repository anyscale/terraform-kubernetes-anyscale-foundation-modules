# ------------------------------------------------------------------------------
# REQUIRED PARAMETERS
# ------------------------------------------------------------------------------

variable "project_id" {
  description = "(Required) Google Cloud project ID."
  type        = string
}

variable "region" {
  description = "(Required) Regional GKE control-plane location."
  type        = string
}

variable "zone" {
  description = "(Required) Single A4/B200 worker zone. The zone must have a matching vpc-roce network profile."
  type        = string
}

variable "cluster_name" {
  description = "(Required) Name of the GKE cluster to create."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,38}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be a valid GKE-style name: start with a lowercase letter, contain lowercase letters, numbers, and hyphens, and end with a letter or number."
  }
}

variable "host_network" {
  description = "(Required) Existing host/control-plane VPC name or self link for the GKE cluster."
  type        = string
}

variable "host_subnetwork" {
  description = "(Required) Existing host/control-plane subnetwork name or self link for the GKE cluster."
  type        = string
}

# ------------------------------------------------------------------------------
# OPTIONAL PARAMETERS
# ------------------------------------------------------------------------------

variable "workload_name" {
  description = "(Optional) Workload name used in default Kubernetes labels."
  type        = string
  default     = "b200-rdma"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.workload_name))
    error_message = "workload_name must be lowercase DNS-style text: letters, numbers, hyphens, no leading/trailing hyphen."
  }
}

variable "workload_label_key" {
  description = "(Optional) Kubernetes label key used to identify the B200/RDMA worker pool."
  type        = string
  default     = "workload"
}

variable "resource_labels" {
  description = "(Optional) Google Cloud resource labels applied to resources that support labels."
  type        = map(string)
  default     = {}
}

variable "enable_project_services" {
  description = "(Optional) Whether to enable Compute Engine and GKE APIs for the project."
  type        = bool
  default     = true
}

variable "disable_services_on_destroy" {
  description = "(Optional) Whether Terraform should disable project services on destroy."
  type        = bool
  default     = false
}

variable "release_channel" {
  description = "(Optional) GKE release channel."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE", "EXTENDED", "UNSPECIFIED"], var.release_channel)
    error_message = "release_channel must be one of RAPID, REGULAR, STABLE, EXTENDED, or UNSPECIFIED."
  }
}

variable "cluster_version" {
  description = "(Optional) Pinned GKE version. When null, the module uses the selected release channel default for the region."
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "(Optional) Whether to enable GKE cluster deletion protection."
  type        = bool
  default     = false
}

variable "network_mtu" {
  description = "(Optional) MTU for the dedicated gVNIC and RDMA VPCs."
  type        = number
  default     = 8896
}

variable "gvnic_network_name" {
  description = "(Optional) Dedicated VPC name for the extra Titanium gVNIC."
  type        = string
  default     = "b200-gvnic"
}

variable "gvnic_subnetwork_name" {
  description = "(Optional) Subnetwork name for the extra Titanium gVNIC."
  type        = string
  default     = "b200-gvnic-subnet"
}

variable "gvnic_subnetwork_cidr" {
  description = "(Required) CIDR for the extra gVNIC subnetwork."
  type        = string
}

variable "rdma_network_name" {
  description = "(Optional) Dedicated RoCE RDMA VPC name."
  type        = string
  default     = "b200-rdma"
}

variable "rdma_network_profile" {
  description = "(Optional) Full or partial Google network profile URL for the RDMA VPC. Defaults to projects/PROJECT/global/networkProfiles/ZONE-vpc-roce."
  type        = string
  default     = null
}

variable "rdma_subnetwork_name_prefix" {
  description = "(Optional) Prefix for RDMA subnet names. The module creates PREFIX-0 through PREFIX-N."
  type        = string
  default     = "b200-rdma-subnet"
}

variable "rdma_subnetwork_cidr_prefix" {
  description = "(Required) First two octets for RDMA subnets. Subnets become PREFIX.0.0/24 through PREFIX.N.0/24."
  type        = string
}

variable "rdma_interface_count" {
  description = "(Optional) Number of RDMA additional node networks to attach to each A4/B200 worker."
  type        = number
  default     = 8

  validation {
    condition     = var.rdma_interface_count >= 1 && var.rdma_interface_count <= 8
    error_message = "rdma_interface_count must be between 1 and 8 for GKE A4/B200 workers."
  }
}

variable "create_cpu_head_pool" {
  description = "(Optional) Whether to create a CPU node pool for the Ray head or other control-plane workloads."
  type        = bool
  default     = true
}

variable "cpu_head_pool_name" {
  description = "(Optional) CPU head node pool name."
  type        = string
  default     = "cpu-head"
}

variable "cpu_node_count" {
  description = "(Optional) CPU head node count."
  type        = number
  default     = 1
}

variable "cpu_machine_type" {
  description = "(Optional) Machine type for CPU head nodes."
  type        = string
  default     = "e2-standard-16"
}

variable "cpu_disk_size_gb" {
  description = "(Optional) Boot disk size in GB for CPU head nodes."
  type        = number
  default     = 500
}

variable "cpu_disk_type" {
  description = "(Optional) Boot disk type for CPU head nodes."
  type        = string
  default     = "pd-balanced"
}

variable "cpu_labels" {
  description = "(Optional) Additional or overriding Kubernetes labels for the CPU head node pool."
  type        = map(string)
  default     = {}
}

variable "worker_pool_name" {
  description = "(Optional) A4/B200 worker node pool name."
  type        = string
  default     = "a4-spot"
}

variable "worker_node_count" {
  description = "(Optional) A4/B200 worker node count. Each node has 8 B200 GPUs."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_node_count >= 1
    error_message = "worker_node_count must be at least 1."
  }
}

variable "worker_machine_type" {
  description = "(Optional) A4/B200 worker machine type."
  type        = string
  default     = "a4-highgpu-8g"
}

variable "worker_spot" {
  description = "(Optional) Whether to create worker nodes as Spot VMs."
  type        = bool
  default     = true
}

variable "worker_disk_size_gb" {
  description = "(Optional) Boot disk size in GB for A4/B200 workers."
  type        = number
  default     = 500
}

variable "worker_disk_type" {
  description = "(Optional) Boot disk type for A4/B200 workers."
  type        = string
  default     = "hyperdisk-balanced"
}

variable "worker_labels" {
  description = "(Optional) Additional or overriding Kubernetes labels for the A4/B200 worker node pool."
  type        = map(string)
  default     = {}
}

variable "worker_taints" {
  description = <<-EOT
    (Optional) Kubernetes taints for the A4/B200 worker node pool.

    Effects must use GKE API values: NO_SCHEDULE, NO_EXECUTE, or PREFER_NO_SCHEDULE.
  EOT
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []

  validation {
    condition = alltrue([
      for taint in var.worker_taints :
      contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], taint.effect)
    ])
    error_message = "worker_taints effects must be one of NO_SCHEDULE, NO_EXECUTE, or PREFER_NO_SCHEDULE."
  }
}

variable "gpu_type" {
  description = "(Optional) GKE accelerator type for A4/B200 workers."
  type        = string
  default     = "nvidia-b200"
}

variable "gpu_count" {
  description = "(Optional) GPU count per A4/B200 worker."
  type        = number
  default     = 8
}

variable "gpu_driver_version" {
  description = "(Optional) GKE GPU driver version mode."
  type        = string
  default     = "LATEST"
}

variable "node_image_type" {
  description = "(Optional) GKE node image type."
  type        = string
  default     = "COS_CONTAINERD"
}

variable "node_service_account_email" {
  description = "(Optional) Google service account email to use for node VMs."
  type        = string
  default     = null
}

variable "node_oauth_scopes" {
  description = "(Optional) OAuth scopes for node VMs."
  type        = set(string)
  default     = ["https://www.googleapis.com/auth/cloud-platform"]
}

variable "enable_node_auto_repair" {
  description = "(Optional) Whether GKE should auto-repair nodes."
  type        = bool
  default     = false
}

variable "enable_node_auto_upgrade" {
  description = "(Optional) Whether GKE should auto-upgrade nodes."
  type        = bool
  default     = false
}
