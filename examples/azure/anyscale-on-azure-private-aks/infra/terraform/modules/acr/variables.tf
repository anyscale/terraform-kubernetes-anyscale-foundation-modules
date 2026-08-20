variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.name))
    error_message = "ACR name must be 5-50 alphanumeric characters."
  }
}

variable "pe_subnet_id" {
  type = string
}

variable "pe_dns_zone_id" {
  type = string
}

variable "zone_redundancy_enabled" {
  type = bool
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for ACR diagnostic settings."
  type        = string
}

variable "diagnostic_settings_enabled" {
  description = "Whether this module creates Azure Monitor diagnostic settings."
  type        = bool
  default     = false
}

variable "acr_cache_rules" {
  description = <<-EOT
    Cache rules that mirror upstream image repositories into this registry,
    keyed by rule name. Use this to serve third-party images (registry.k8s.io,
    Docker Hub, quay.io, ...) from inside the private registry when node
    egress to the public internet is locked down.
  EOT
  type = map(object({
    source_repo = string
    target_repo = string
  }))
  default = {}
}
