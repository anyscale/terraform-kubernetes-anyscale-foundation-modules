variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "log_analytics_name" {
  type = string
}

variable "ampls_name" {
  type = string
}

variable "ampls_private_endpoint_name" {
  type = string
}

variable "retention_in_days" {
  type = number
}

variable "internet_ingestion_enabled" {
  description = "Whether the Log Analytics workspace accepts public ingestion."
  type        = bool
}

variable "internet_query_enabled" {
  description = "Whether the Log Analytics workspace accepts public query traffic."
  type        = bool
}

variable "ampls_enabled" {
  description = "Whether to create Azure Monitor Private Link Scope and private endpoint resources."
  type        = bool
}

variable "ampls_ingestion_access_mode" {
  type = string
}

variable "ampls_query_access_mode" {
  type = string
}

variable "private_endpoint_subnet_id" {
  description = "Subnet ID where the Azure Monitor Private Link Scope private endpoint will be deployed."
  type        = string
}

variable "ampls_private_dns_zone_ids" {
  description = "Private DNS zone IDs required by Azure Monitor Private Link Scope."
  type = object({
    monitor  = string
    oms      = string
    ods      = string
    agentsvc = string
    blob     = string
  })
}
