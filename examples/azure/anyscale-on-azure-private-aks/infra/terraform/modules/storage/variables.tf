variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "storage_account_name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 lowercase alphanumeric characters."
  }
}

variable "subscription_id" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "container_name" {
  type = string
}

variable "replication_type" {
  description = "Storage account replication type."
  type        = string
}

variable "cors_rule" {
  type = object({
    allowed_headers    = list(string)
    allowed_methods    = list(string)
    allowed_origins    = list(string)
    expose_headers     = list(string)
    max_age_in_seconds = number
  })
}

variable "pe_subnet_id" {
  type        = string
  description = "Subnet ID where the storage account private endpoints will be deployed."
}

variable "pe_dns_zone_ids" {
  description = "Private DNS zone IDs for blob/dfs subresources."
  type = object({
    blob = string
    dfs  = string
  })
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for storage diagnostic settings."
  type        = string
}

variable "diagnostic_settings_enabled" {
  description = "Whether this module creates Azure Monitor diagnostic settings."
  type        = bool
  default     = false
}
