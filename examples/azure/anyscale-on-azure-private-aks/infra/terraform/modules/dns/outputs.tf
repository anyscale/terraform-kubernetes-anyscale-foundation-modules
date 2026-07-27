output "zone_ids" {
  description = "Map of logical zone key -> private DNS zone resource ID."
  value       = { for k, z in azurerm_private_dns_zone.this : k => z.id }
}

output "zone_names" {
  description = "Map of logical zone key -> private DNS zone FQDN."
  value       = { for k, z in azurerm_private_dns_zone.this : k => z.name }
}
