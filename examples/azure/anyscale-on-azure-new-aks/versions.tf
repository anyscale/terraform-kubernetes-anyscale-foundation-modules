terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # >= 4.31 for `gpu_driver` on azurerm_kubernetes_cluster_node_pool
      # (the gpu_driver_mode switch in aks.tf relies on it).
      version = ">= 4.31.0, < 5.0.0"
    }
    # azapi creates the Anyscale.Platform/clouds + cloudResources resources
    # natively (no ARM-template deployment wrapper), and applies the optional
    # Node Auto Provisioning patch to the AKS cluster.
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    # helm + kubernetes + kubectl drive the in-cluster bootstrap of Envoy
    # Gateway, the Gateway-API resources, and (optionally) the NVIDIA GPU
    # operator. They authenticate from the AKS cluster's kube_config
    # attributes — no kubeconfig file is read at plan time.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
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
    # local writes the post-apply deployment summary (anyscale-aks-cloud.yaml).
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id                 = var.azure_subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread             = var.storage_use_azuread
}

provider "azapi" {
  subscription_id = var.azure_subscription_id
}

# Authenticate the in-cluster providers using the AKS cluster's admin
# kube_config attributes directly (cert-based; available because the cluster
# keeps local accounts enabled and does not use AAD RBAC). This is the
# canonical "create AKS + deploy into it in one apply" pattern: the provider
# config is computed from the azurerm_kubernetes_cluster resource, so Terraform
# defers the kubernetes/helm/kubectl resources until the cluster exists — and
# nothing reads a kubeconfig file at plan time, so a stale ~/.kube/config
# context (old cluster, Lens proxy, etc.) can never be picked up. True single
# `terraform apply`, no `az aks get-credentials` for the providers.
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.aks.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = azurerm_kubernetes_cluster.aks.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = azurerm_kubernetes_cluster.aks.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
  load_config_file       = false
}
