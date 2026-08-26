###############################################################################
# Create-or-adopt resolution layer.
#
# This example defaults to creating everything it needs (`create_aks_cluster =
# true`, the historical behaviour). Set `create_aks_cluster = false` and supply
# `existing_aks_cluster_name` + `azure_resource_group_name` to layer Anyscale
# onto an AKS cluster you already run.
#
# Every other file reads the cluster, resource group and node subnet through
# the `local.aks_*` / `local.rg_*` / `local.node_subnet_id` values defined here,
# so there is exactly one place that knows which mode is in effect.
#
#   create_aks_cluster = true
#       -> new RG, VNet, subnet, cluster and node pools (the default)
#   create_aks_cluster = true + existing_node_subnet_id
#       -> new cluster in a subnet you already have
#   create_aks_cluster = true + create_resource_group = false
#       -> new cluster in a resource group you already have
#   create_aks_cluster = false
#       -> adopt an existing cluster, along with its resource group and subnet
###############################################################################

locals {
  # Adopting a cluster implies adopting the resource group it lives in — there
  # is nothing sensible to create alongside it.
  create_resource_group = var.create_aks_cluster && var.create_resource_group

  # The VNet/subnet pair is only ours to create when we are creating the
  # cluster AND the caller has not pointed us at a subnet of their own.
  create_network = var.create_aks_cluster && var.existing_node_subnet_id == null

  create_node_pools = var.create_node_pools

  # Interpolating a null into a string is an error, and this name is null in
  # the (default) create path. Normalise once so the CLI probe and the
  # precondition messages below can use it unconditionally.
  existing_aks_cluster_name = var.existing_aks_cluster_name == null ? "" : var.existing_aks_cluster_name

  # Keep in sync with the validation on var.azure_location, select-region.sh
  # and the README. Used to check the region of an ADOPTED cluster, which the
  # variable validation cannot see.
  anyscale_supported_locations = [
    "westcentralus", "eastus", "eastus2", "westus2", "westus3",
    "southcentralus", "westeurope", "swedencentral", "uksouth",
    "australiaeast", "southeastasia", "northeurope",
  ]
}

###############################################################################
# Existing resource group.
###############################################################################
data "azurerm_resource_group" "existing" {
  count = local.create_resource_group ? 0 : 1

  name = var.azure_resource_group_name

  lifecycle {
    precondition {
      condition     = var.azure_resource_group_name != ""
      error_message = "azure_resource_group_name must name an existing resource group when create_resource_group=false or create_aks_cluster=false. The \"<aks_cluster_name>-rg\" fallback only applies when Terraform creates the group."
    }
  }
}

###############################################################################
# Existing AKS cluster.
###############################################################################
data "azurerm_kubernetes_cluster" "existing" {
  count = var.create_aks_cluster ? 0 : 1

  name                = var.existing_aks_cluster_name
  resource_group_name = var.azure_resource_group_name

  lifecycle {
    precondition {
      condition     = var.existing_aks_cluster_name != null && var.existing_aks_cluster_name != ""
      error_message = "existing_aks_cluster_name must be set when create_aks_cluster=false."
    }
    precondition {
      condition     = var.azure_resource_group_name != ""
      error_message = "azure_resource_group_name must name the resource group holding existing_aks_cluster_name when create_aks_cluster=false."
    }
  }
}

###############################################################################
# Microsoft Entra workload identity is not exposed by the azurerm data source,
# so read it with the Azure CLI (already a hard dependency of this example —
# see azure-login.sh and the gateway-LB steps in envoy-gateway.tf).
#
# Deliberately tolerant: an unreadable value yields "" rather than failing, and
# the preflight precondition below only blocks on an explicit "false". This
# mirrors how the Anyscale.Platform agreement status is read in anyscale.tf.
###############################################################################
data "external" "existing_aks_workload_identity" {
  count = var.create_aks_cluster ? 0 : 1

  program = [
    "bash",
    "-c",
    "value=\"$(az aks show --resource-group '${var.azure_resource_group_name}' --name '${local.existing_aks_cluster_name}' --query 'securityProfile.workloadIdentity.enabled' -o tsv --only-show-errors 2>/dev/null || true)\"; printf '{\"enabled\":\"%s\"}' \"$value\"",
  ]
}

###############################################################################
# Preflight assertions for the adopt path.
#
# These live on a side-effect-free terraform_data rather than on the data
# sources themselves because a precondition cannot reference the attributes of
# the resource it is attached to. Failing here fails `terraform plan`, before
# anything is created.
###############################################################################
resource "terraform_data" "existing_aks_preflight" {
  count = var.create_aks_cluster ? 0 : 1

  input = {
    cluster_id = data.azurerm_kubernetes_cluster.existing[0].id
  }

  lifecycle {
    precondition {
      condition     = data.azurerm_kubernetes_cluster.existing[0].oidc_issuer_enabled
      error_message = <<-EOT
        The existing AKS cluster "${local.existing_aks_cluster_name}" does not have the OIDC issuer enabled, which the Anyscale operator's federated identity credential requires. Enable it with:

          az aks update --resource-group ${var.azure_resource_group_name} --name ${local.existing_aks_cluster_name} --enable-oidc-issuer --enable-workload-identity
      EOT
    }

    precondition {
      condition     = try(data.external.existing_aks_workload_identity[0].result.enabled, "") != "false"
      error_message = <<-EOT
        The existing AKS cluster "${local.existing_aks_cluster_name}" does not have Microsoft Entra workload identity enabled. The Anyscale operator authenticates to the control plane with a workload-identity token, not a CLI token. Enable it with:

          az aks update --resource-group ${var.azure_resource_group_name} --name ${local.existing_aks_cluster_name} --enable-oidc-issuer --enable-workload-identity
      EOT
    }

    precondition {
      condition     = length(data.azurerm_kubernetes_cluster.existing[0].kube_config) > 0
      error_message = <<-EOT
        The existing AKS cluster "${local.existing_aks_cluster_name}" returned no certificate-based kube_config. This example's kubernetes/helm/kubectl providers (versions.tf) authenticate with the cluster's client certificate, which Azure only issues when local accounts are enabled.

        Either re-enable local accounts (az aks update --resource-group ${var.azure_resource_group_name} --name ${local.existing_aks_cluster_name} --enable-local-accounts), or fork versions.tf to authenticate the three in-cluster providers through an `exec` block running `kubelogin get-token`.
      EOT
    }

    precondition {
      condition     = contains(local.anyscale_supported_locations, lower(replace(data.azurerm_kubernetes_cluster.existing[0].location, " ", "")))
      error_message = <<-EOT
        The existing AKS cluster "${local.existing_aks_cluster_name}" is in region "${data.azurerm_kubernetes_cluster.existing[0].location}", where Anyscale.Platform/clouds is not available. Supported regions: ${join(", ", local.anyscale_supported_locations)}.
      EOT
    }

    precondition {
      condition     = local.node_subnet_id != null
      error_message = <<-EOT
        Could not determine a node subnet for the existing AKS cluster "${local.existing_aks_cluster_name}" — its first agent pool reports no vnet_subnet_id, which usually means the cluster uses kubenet rather than Azure CNI. Set existing_node_subnet_id explicitly, or set create_node_pools=false if the cluster already has pools carrying the Anyscale taints.
      EOT
    }
  }
}

###############################################################################
# Preflight assertion for an adopted resource group.
#
# `var.azure_location` only ever configures a resource group Terraform creates,
# so its region validation does not cover an adopted one. That matters: the
# Anyscale.Platform/clouds ARM deployment in anyscale.tf is submitted with
# `location = local.rg_location`, and the storage account, ACR and operator
# identity are created there too.
###############################################################################
resource "terraform_data" "existing_rg_preflight" {
  count = local.create_resource_group ? 0 : 1

  input = {
    resource_group_id = local.rg_id
  }

  lifecycle {
    precondition {
      condition     = contains(local.anyscale_supported_locations, lower(replace(local.rg_location, " ", "")))
      error_message = <<-EOT
        The existing resource group "${var.azure_resource_group_name}" is in region "${local.rg_location}", where Anyscale.Platform/clouds is not available. The Anyscale cloud, storage account, ACR and operator identity are all deployed into this region.

        Supported regions: ${join(", ", local.anyscale_supported_locations)}.
      EOT
    }
  }
}

###############################################################################
# Resolved values consumed by the rest of the example.
###############################################################################
locals {
  rg_name     = local.create_resource_group ? azurerm_resource_group.rg[0].name : data.azurerm_resource_group.existing[0].name
  rg_id       = local.create_resource_group ? azurerm_resource_group.rg[0].id : data.azurerm_resource_group.existing[0].id
  rg_location = local.create_resource_group ? azurerm_resource_group.rg[0].location : data.azurerm_resource_group.existing[0].location

  aks_id                = var.create_aks_cluster ? azurerm_kubernetes_cluster.aks[0].id : data.azurerm_kubernetes_cluster.existing[0].id
  aks_name              = var.create_aks_cluster ? azurerm_kubernetes_cluster.aks[0].name : data.azurerm_kubernetes_cluster.existing[0].name
  aks_oidc_issuer_url   = var.create_aks_cluster ? azurerm_kubernetes_cluster.aks[0].oidc_issuer_url : data.azurerm_kubernetes_cluster.existing[0].oidc_issuer_url
  aks_kubelet_object_id = var.create_aks_cluster ? azurerm_kubernetes_cluster.aks[0].kubelet_identity[0].object_id : data.azurerm_kubernetes_cluster.existing[0].kubelet_identity[0].object_id
  aks_kube_config       = var.create_aks_cluster ? azurerm_kubernetes_cluster.aks[0].kube_config[0] : data.azurerm_kubernetes_cluster.existing[0].kube_config[0]

  # Precedence: explicit override -> the subnet we just created -> the subnet
  # the adopted cluster's first agent pool already runs in. Null (a kubenet
  # cluster, nothing to infer) is caught by the preflight precondition above.
  node_subnet_id = try(coalesce(
    var.existing_node_subnet_id,
    one(azurerm_subnet.nodes[*].id),
    try(one(data.azurerm_kubernetes_cluster.existing[*].agent_pool_profile[0].vnet_subnet_id), null),
  ), null)
}
