variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "name" {
  type = string
}

variable "operator_identity" {
  description = "Anyscale operator managed identity mode and optional existing user-assigned managed identity IDs."
  type = object({
    mode                = optional(string, "create")
    id                  = optional(string)
    client_id           = optional(string)
    principal_id        = optional(string)
    name                = optional(string)
    manage_storage_rbac = optional(bool)
  })
}

variable "storage_data_scope_id" {
  description = "Storage data-plane scope to grant Storage Blob Data Contributor on. Prefer the default Anyscale storage container for least privilege."
  type        = string
}
