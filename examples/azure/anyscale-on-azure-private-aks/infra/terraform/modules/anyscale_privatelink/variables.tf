variable "enabled" {
  type        = bool
  default     = false
  description = "Create the private endpoint to Anyscale's control plane when true."
}

variable "name_prefix" {
  type        = string
  description = "Prefix used to name the private endpoint and DNS VNet link (typically the AKS cluster name)."
}

variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

variable "pe_subnet_id" {
  type        = string
  description = "Subnet ID for the private endpoint NIC (the shared private-endpoints subnet)."
}

variable "vnet_id" {
  type        = string
  description = "VNet ID to link the Anyscale private DNS zone to."
}

variable "privatelink_service_alias" {
  type        = string
  description = "Alias of the Private Link Service Anyscale provides for this cloud deployment."
}

variable "dns_zone_name" {
  type        = string
  description = "Private DNS zone Anyscale's control-plane hostnames live under (e.g. <cloud-id>.anyscale.internal)."
}

variable "record_names" {
  type        = list(string)
  default     = ["*"]
  description = "Record names to create in the private DNS zone, pointed at the endpoint's private IP. \"*\" produces the wildcard record *.<zone>; \"@\" is the apex."
}
