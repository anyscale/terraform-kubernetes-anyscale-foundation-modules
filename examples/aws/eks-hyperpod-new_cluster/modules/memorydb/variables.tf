variable "resource_name_prefix" {
  description = "Prefix to be used for all resources created by this module."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC the MemoryDB cluster is deployed into."
  type        = string
}

variable "subnet_ids" {
  description = <<-EOT
    Subnet IDs for the MemoryDB subnet group. Provide subnets in at least two
    Availability Zones so the read replica lands in a different AZ from the
    primary (required for true head-node-fault-tolerance HA).
    EOT
  type        = list(string)
}

variable "source_security_group_id" {
  description = <<-EOT
    Security group whose members are allowed to reach MemoryDB on the Redis port.
    On this stack that is the shared cluster security group used by BOTH the EKS
    node group and the HyperPod instance groups, so the Ray head/worker pods (the
    Anyscale data plane) can reach the external GCS storage.
    EOT
  type        = string
}

variable "node_type" {
  description = "MemoryDB node type. db.t4g.small (~2 GiB) matches what Anyscale provisions for AWS clouds and is sufficient for head node fault tolerance (a 10-node service needs ~20 MB, growing to ~100 MB+)."
  type        = string
  default     = "db.t4g.small"
}

variable "port" {
  description = "Redis port for the MemoryDB cluster."
  type        = number
  default     = 6379
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
