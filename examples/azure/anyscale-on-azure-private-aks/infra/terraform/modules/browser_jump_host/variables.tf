variable "enabled" {
  type        = bool
  default     = false
  description = "Create the optional Windows 11 browser jump host when true."
}

variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

variable "name" {
  type        = string
  description = "Name of the Windows 11 browser jump-host VM (<= 15 chars)."
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID for the browser-host NIC. Must be private with no public IP."
}

variable "vm_size" {
  type        = string
  description = "VM size selected before apply by the harness sizing step."
}

variable "admin_username" {
  type    = string
  default = "azureadmin"
}

variable "admin_password" {
  type        = string
  sensitive   = true
  description = "Local administrator password. Required by Azure even when Entra login is used."
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
    publisher = "microsoftwindowsdesktop"
    offer     = "windows-11"
    sku       = "win11-23h2-ent"
    version   = "latest"
  }
}

variable "vm_user_login_principal_ids" {
  type        = map(string)
  default     = {}
  description = "Map of key => principal_id granted Virtual Machine User Login on the browser host."
}

variable "vm_admin_login_principal_ids" {
  type        = map(string)
  default     = {}
  description = "Map of key => principal_id granted Virtual Machine Administrator Login on the browser host."
}

variable "boot_diagnostics_enabled" {
  type    = bool
  default = true
}
