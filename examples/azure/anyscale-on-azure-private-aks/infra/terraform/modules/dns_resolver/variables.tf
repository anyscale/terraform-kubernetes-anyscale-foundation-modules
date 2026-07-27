variable "resource_group_name" {
  description = "Resource group name for DNS Private Resolver resources."
  type        = string
}

variable "location" {
  description = "Azure region for DNS Private Resolver resources."
  type        = string
}

variable "tags" {
  description = "Tags applied to taggable DNS Private Resolver resources."
  type        = map(string)
}

variable "resolver_name" {
  description = "Azure DNS Private Resolver name."
  type        = string
}

variable "inbound_endpoint_name" {
  description = "Inbound endpoint name."
  type        = string
}

variable "outbound_endpoint_name" {
  description = "Outbound endpoint name."
  type        = string
}

variable "forwarding_ruleset_name" {
  description = "DNS forwarding ruleset name."
  type        = string
}

variable "virtual_network_id" {
  description = "VNet where the DNS Private Resolver is deployed."
  type        = string
}

variable "inbound_subnet_id" {
  description = "Dedicated delegated subnet ID for the inbound endpoint."
  type        = string
}

variable "outbound_subnet_id" {
  description = "Dedicated delegated subnet ID for the outbound endpoint."
  type        = string
}

variable "inbound_endpoint_ip" {
  description = "Static private IP for the inbound endpoint."
  type        = string
}

variable "forwarding_ruleset_vnet_links" {
  description = "Map of forwarding ruleset VNet link key -> VNet ID."
  type        = map(string)
}

variable "forwarding_rules" {
  description = "Map of forwarding rule name -> domain suffix and target DNS servers."
  type = map(object({
    domain_name = string
    target_dns_servers = list(object({
      ip_address = string
      port       = number
    }))
  }))
}