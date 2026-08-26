terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.26.0"
    }
    # azapi installs the Anyscale.Platform/clouds ARM resource directly
    # (the same ARM template the Azure portal exports for the managed path).
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    # helm + kubernetes + kubectl drive the in-cluster bootstrap of Envoy
    # Gateway and the Gateway-API resources the Anyscale operator routes
    # through. They consume a kubeconfig produced by `az aks get-credentials`
    # — see README for the two-stage deploy workflow.
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
    # external is used to read the Gateway LoadBalancer address back into
    # Terraform after the Envoy Gateway controller programs it.
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
  host                   = local.aks_kube_config.host
  client_certificate     = base64decode(local.aks_kube_config.client_certificate)
  client_key             = base64decode(local.aks_kube_config.client_key)
  cluster_ca_certificate = base64decode(local.aks_kube_config.cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = local.aks_kube_config.host
    client_certificate     = base64decode(local.aks_kube_config.client_certificate)
    client_key             = base64decode(local.aks_kube_config.client_key)
    cluster_ca_certificate = base64decode(local.aks_kube_config.cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = local.aks_kube_config.host
  client_certificate     = base64decode(local.aks_kube_config.client_certificate)
  client_key             = base64decode(local.aks_kube_config.client_key)
  cluster_ca_certificate = base64decode(local.aks_kube_config.cluster_ca_certificate)
  load_config_file       = false
}
