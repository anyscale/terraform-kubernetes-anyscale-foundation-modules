variable "resource_group_name" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "vnet_links" {
  description = "Map of VNet link key -> VNet ID to link to every private DNS zone."
  type        = map(string)
}

variable "zones" {
  description = "Map of logical zone key -> private DNS zone FQDN."
  type        = map(string)
}
