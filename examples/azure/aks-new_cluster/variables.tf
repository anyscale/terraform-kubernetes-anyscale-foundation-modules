variable "azure_subscription_id" {
  description = "(Required) Azure subscription ID"
  type        = string
}

variable "azure_location" {
  description = "(Optional) Azure region for all resources."
  type        = string
  default     = "West US"
}

variable "tags" {
  description = "(Optional) Tags applied to all taggable resources."
  type        = map(string)
  default = {
    Test        = "true"
    Environment = "dev"
  }
}

variable "aks_cluster_name" {
  description = "(Optional) Name of the AKS cluster (and related resources)."
  type        = string
  default     = "anyscale-aks-k8s"
}

variable "anyscale_operator_namespace" {
  description = "(Optional) Kubernetes namespace for the Anyscale operator."
  type        = string
  default     = "anyscale-operator"
}
