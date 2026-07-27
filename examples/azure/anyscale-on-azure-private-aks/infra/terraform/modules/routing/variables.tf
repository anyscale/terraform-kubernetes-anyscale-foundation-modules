variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "route_table_name" {
  type = string
}

variable "firewall_private_ip" {
  description = "Azure Firewall private IP — UDR next hop for all egress (0.0.0.0/0)."
  type        = string
}

variable "subnet_ids_to_associate" {
  description = "Map of subnet logical name -> subnet ID to associate with this route table."
  type        = map(string)
}
