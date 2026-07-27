terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # >= 4.81 for the typed `azurerm_kubernetes_automatic_cluster` resource.
      # There is no earlier release that models AKS Automatic natively — before
      # it, the only option was a raw azapi managedClusters body.
      version = ">= 4.81.0, < 5.0.0"
    }
    # azapi creates the Anyscale.Platform/clouds + cloudResources resources
    # natively (no ARM-template deployment wrapper), and patches the two
    # surfaces the typed cluster resource does not expose: the monitoring
    # profile and deployment safeguards.
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    # external is only used on the internal-gateway path (internal LBs get a
    # private IP, not a public DNS label, so the address must be read back
    # from the Gateway status).
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    # random generates a small suffix appended to globally-unique resource
    # names (storage account, ACR) so the default `aks_cluster_name` does
    # not collide with another tenant's deployment.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # local writes the rendered in-cluster manifests and the post-apply
    # deployment summary (anyscale-aks-cloud.yaml).
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

###############################################################################
# NO helm / kubernetes / kubectl PROVIDERS.
#
# The `new-aks` sibling authenticates those providers from the cluster's
# `kube_config` client certificate. AKS Automatic does not issue one: local
# accounts are disabled and Entra RBAC is enforced, so the only way in is an
# Entra token via `kubelogin`. Terraform providers cannot drive that exec
# plugin from computed cluster attributes at plan time, so all in-cluster
# objects here are applied by a `terraform_data` local-exec that shells out to
# `az aks get-credentials` + `kubelogin` + `kubectl apply` (gateway.tf).
###############################################################################

provider "azurerm" {
  features {}
  subscription_id                 = var.azure_subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread             = var.storage_use_azuread
}

provider "azapi" {
  subscription_id = var.azure_subscription_id
}
