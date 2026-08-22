terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.9"
    }

    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.72"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
