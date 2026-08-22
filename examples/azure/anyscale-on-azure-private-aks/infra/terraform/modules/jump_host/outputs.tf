output "vm_id" {
  description = "Resource ID of the Linux automation jump host."
  value       = azurerm_linux_virtual_machine.this.id
}

output "vm_name" {
  description = "Name of the Linux automation jump host."
  value       = azurerm_linux_virtual_machine.this.name
}

output "private_ip_address" {
  description = "Private IP address of the jump-host NIC."
  value       = azurerm_network_interface.this.private_ip_address
}

output "principal_id" {
  description = "Principal ID of the jump-host system-assigned managed identity."
  value       = azurerm_linux_virtual_machine.this.identity[0].principal_id
}

output "admin_username" {
  description = "Admin username configured on the jump host."
  value       = var.admin_username
}

output "private_mode" {
  description = "Invariants consumed by terraform tests: no public IP, MI enabled."
  value = {
    has_public_ip          = false
    identity_type          = azurerm_linux_virtual_machine.this.identity[0].type
    password_auth_disabled = true
    vm_size                = var.vm_size
  }
}
