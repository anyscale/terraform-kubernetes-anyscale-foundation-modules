###############################################################################
# Optional Windows 11 browser jump host
# - Entra ID login via the AADLoginForWindows VM extension
# - Private NIC only; no public IP (Azure Bastion portal RDP is the only path)
# - Browser-only: never used for Terraform, Podman, or workload automation
# Docs:
# - https://learn.microsoft.com/azure/active-directory/devices/howto-vm-sign-in-azure-ad-windows
# - https://learn.microsoft.com/azure/bastion/bastion-connect-vm-rdp-windows
###############################################################################
locals {
  enabled = var.enabled ? 1 : 0
}

resource "azurerm_network_interface" "this" {
  count = local.enabled

  name                = "nic-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    # No public_ip_address_id — reachable only through Azure Bastion portal RDP.
  }
}

resource "azurerm_windows_virtual_machine" "this" {
  count = local.enabled

  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  tags                = var.tags

  network_interface_ids = [azurerm_network_interface.this[0].id]

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    name                 = "osdisk-${var.name}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_storage_account_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.source_image_reference.publisher
    offer     = var.source_image_reference.offer
    sku       = var.source_image_reference.sku
    version   = var.source_image_reference.version
  }

  dynamic "boot_diagnostics" {
    for_each = var.boot_diagnostics_enabled ? [1] : []
    content {
      storage_account_uri = null
    }
  }
}

# Entra ID login extension. Required for passwordless Entra sign-in through
# Bastion portal RDP and for VM login RBAC enforcement.
resource "azurerm_virtual_machine_extension" "aad_login" {
  count = local.enabled

  name                       = "AADLoginForWindows"
  virtual_machine_id         = azurerm_windows_virtual_machine.this[0].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "2.0"
  auto_upgrade_minor_version = true
  tags                       = var.tags
}

resource "azurerm_role_assignment" "vm_user_login" {
  for_each = var.enabled ? var.vm_user_login_principal_ids : {}

  scope                = azurerm_windows_virtual_machine.this[0].id
  role_definition_name = "Virtual Machine User Login"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "vm_admin_login" {
  for_each = var.enabled ? var.vm_admin_login_principal_ids : {}

  scope                = azurerm_windows_virtual_machine.this[0].id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = each.value
}
