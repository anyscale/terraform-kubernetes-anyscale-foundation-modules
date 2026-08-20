output "endpoint_id" {
  description = "ID of the Anyscale Private Link endpoint, or null when disabled."
  value       = try(azurerm_private_endpoint.this[0].id, null)
}

output "private_ip" {
  description = "Private IP the Anyscale control-plane hostnames resolve to inside the VNet, or null when disabled."
  value       = try(azurerm_private_endpoint.this[0].private_service_connection[0].private_ip_address, null)
}

output "record_fqdns" {
  description = "Private DNS records created for the Anyscale control plane."
  value = var.enabled ? [
    for name in var.record_names :
    name == "@" ? var.dns_zone_name : "${name}.${var.dns_zone_name}"
  ] : []
}
