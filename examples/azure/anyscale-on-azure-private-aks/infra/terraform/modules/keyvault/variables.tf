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
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.name))
    error_message = "Key Vault name must be 3-24 chars, start with a letter, end alphanumeric, and contain only letters, digits, and hyphens."
  }
}

variable "tenant_id" {
  type = string
}

variable "pe_subnet_id" {
  type = string
}

variable "pe_dns_zone_id" {
  type = string
}

variable "purge_protection_enabled" {
  description = "Enable purge protection. Recommended true for production; defaults false to keep the sample easy to tear down."
  type        = bool
  default     = false
}

variable "soft_delete_retention_days" {
  type    = number
  default = 7
}
