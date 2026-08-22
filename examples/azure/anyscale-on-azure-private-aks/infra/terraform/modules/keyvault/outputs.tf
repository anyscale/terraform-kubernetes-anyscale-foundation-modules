output "key_vault_id" {
  value = azurerm_key_vault.this.id
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "private_mode" {
  description = "Key Vault private access settings used by root terraform tests."
  value = {
    sku_name                      = azurerm_key_vault.this.sku_name
    rbac_authorization_enabled    = azurerm_key_vault.this.rbac_authorization_enabled
    public_network_access_enabled = azurerm_key_vault.this.public_network_access_enabled
    purge_protection_enabled      = azurerm_key_vault.this.purge_protection_enabled
    private_endpoint_subnet_id    = azurerm_private_endpoint.this.subnet_id
  }
}
