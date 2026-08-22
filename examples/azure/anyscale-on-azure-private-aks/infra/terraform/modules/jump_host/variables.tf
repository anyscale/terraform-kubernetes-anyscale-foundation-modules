variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

variable "name" {
  type        = string
  description = "Name of the Linux automation jump-host VM."
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID for the jump-host NIC. Must be a private subnet with no public IP."
}

variable "vm_size" {
  type        = string
  description = "VM size selected before apply by the harness sizing step."
}

variable "admin_username" {
  type    = string
  default = "azureoperator"
}

variable "admin_ssh_public_key" {
  type        = string
  description = "SSH public key (OpenSSH format) authorized for the admin user."
}

variable "os_disk_size_gb" {
  type    = number
  default = 128
}

variable "os_disk_storage_account_type" {
  type    = string
  default = "Premium_LRS"
}

variable "source_image_reference" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

variable "custom_data" {
  type        = string
  default     = null
  description = "Optional base64-encoded cloud-init payload for first-boot bootstrap."
}

variable "boot_diagnostics_enabled" {
  type    = bool
  default = true
}
