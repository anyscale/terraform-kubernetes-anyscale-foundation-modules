output "enabled" {
  description = "Whether the Windows browser jump host was created."
  value       = var.enabled
}

output "vm_id" {
  description = "Resource ID of the Windows browser jump host (null when disabled)."
  value       = one(azurerm_windows_virtual_machine.this[*].id)
}

output "vm_name" {
  description = "Name of the Windows browser jump host (null when disabled)."
  value       = one(azurerm_windows_virtual_machine.this[*].name)
}

output "private_ip_address" {
  description = "Private IP address of the browser-host NIC (null when disabled)."
  value       = one(azurerm_network_interface.this[*].private_ip_address)
}

output "principal_id" {
  description = "Principal ID of the browser-host system-assigned managed identity (null when disabled)."
  value       = var.enabled ? azurerm_windows_virtual_machine.this[0].identity[0].principal_id : null
}

output "aad_login_extension_name" {
  description = "Name of the Entra ID login extension (null when disabled)."
  value       = one(azurerm_virtual_machine_extension.aad_login[*].name)
}

output "private_mode" {
  description = "Invariants consumed by terraform tests and browser prechecks."
  value = {
    enabled                  = var.enabled
    has_public_ip            = false
    aad_login_extension_type = var.enabled ? "AADLoginForWindows" : null
    vm_user_login_count      = length(var.vm_user_login_principal_ids)
    vm_admin_login_count     = length(var.vm_admin_login_principal_ids)
    vm_size                  = var.enabled ? var.vm_size : null
  }
}
