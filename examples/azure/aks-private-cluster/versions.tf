terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # >= 4.31 keeps this example on the same floor as the sibling Azure
      # examples in this repo.
      version = ">= 4.31.0, < 5.0.0"
    }
    # random generates a short suffix appended to globally-unique resource
    # names (storage account, ACR) so the default cluster name does not
    # collide with another tenant's deployment.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# NOTE: there are deliberately NO kubernetes / helm / kubectl providers here.
#
# The API server is private (aks.tf), so any in-cluster Terraform provider
# would have to reach it from wherever Terraform runs. This example instead
# emits the registration and helm commands as outputs, which you run through
# `az aks command invoke` (see the README). That keeps `terraform apply`
# working from anywhere without a VNet jumpbox or peering.
provider "azurerm" {
  features {}
  subscription_id                 = var.azure_subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread             = var.storage_use_azuread
}
