variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "bastion_name" {
  type = string
}

variable "pip_name" {
  type = string
}

variable "subnet_id" {
  description = "ID of the AzureBastionSubnet."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for Bastion diagnostic settings."
  type        = string
}

variable "diagnostic_settings_enabled" {
  description = "Whether this module creates Azure Monitor diagnostic settings."
  type        = bool
  default     = false
}
