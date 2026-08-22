variable "resource_group_name" {
  type = string
}

variable "resource_group_id" {
  type = string
}

variable "location" {
  type = string
}

variable "name_suffix" {
  type = string
}

variable "oidc_issuer_url" {
  description = "AKS OIDC issuer URL used for the Ratify workload identity federated credential."
  type        = string
}

variable "tags" {
  type = map(string)
}
