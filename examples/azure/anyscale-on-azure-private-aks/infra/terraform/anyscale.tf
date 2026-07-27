locals {
  anyscale_platform_enabled                  = var.anyscale_platform.enabled
  anyscale_platform_cloud_name               = coalesce(var.anyscale_platform.cloud_name, local.suffix)
  anyscale_platform_cloud_control_plane_name = "/subscriptions/${var.azure_subscription_id}/resourcegroups/${local.resource_group_name}/providers/anyscale.platform/clouds/${local.anyscale_platform_cloud_name}"
  anyscale_platform_cloud_arm_id             = "${local.resource_group_id}/providers/Anyscale.Platform/clouds/${local.anyscale_platform_cloud_name}"
  anyscale_platform_subscription_scope       = "/subscriptions/${var.azure_subscription_id}"
  anyscale_platform_extension_name           = var.anyscale_platform.extension_resource_name
  anyscale_platform_extension_release_train  = contains(["stable", "preview"], lower(var.anyscale_platform.release_train)) ? title(lower(var.anyscale_platform.release_train)) : var.anyscale_platform.release_train
  anyscale_platform_destroy_workaround_enabled = coalesce(
    try(var.anyscale_platform.teardown.enabled, null),
    try(var.anyscale_platform.destroy_workaround.enabled, null),
    true,
  )
  anyscale_platform_destroy_workaround_runtime_timeout_seconds = coalesce(
    try(var.anyscale_platform.teardown.runtime_termination_timeout_seconds, null),
    try(var.anyscale_platform.teardown.workspace_termination_timeout_seconds, null),
    try(var.anyscale_platform.destroy_workaround.runtime_termination_timeout_seconds, null),
    try(var.anyscale_platform.destroy_workaround.workspace_termination_timeout_seconds, null),
    900,
  )
  anyscale_platform_destroy_workaround_poll_interval_seconds = coalesce(
    try(var.anyscale_platform.teardown.poll_interval_seconds, null),
    try(var.anyscale_platform.destroy_workaround.poll_interval_seconds, null),
    20,
  )
  anyscale_platform_destroy_workaround_runtime_objects = [
    "jobs",
    "services",
    "workspaces",
    "cluster_sessions",
  ]
  anyscale_platform_lifecycle_create_order = [
    "aks_cluster",
    "anyscale_cloud",
    "cluster_bootstrap",
    "anyscale_extension",
  ]
  anyscale_platform_lifecycle_destroy_order = [
    "drain_jobs_services_workspaces_and_cluster_sessions",
    "delete_anyscale_cloud",
    "delete_anyscale_extension",
    "delete_aks_cluster",
  ]
  anyscale_platform_extension_dynamic_configuration_keys = [
    "global.cloudDeploymentId",
    "global.controlPlaneURL",
    "global.auth.iamIdentity",
    "global.auth.audience",
    "workloads.serviceAccount.name",
    "networking.gateway.enabled",
    "networking.gateway.name",
    "networking.gateway.className",
    "networking.gateway.namespace",
    "networking.gateway.apiVersion",
    "networking.gateway.hostname",
  ]
  anyscale_platform_gateway_configuration = {
    enabled     = "true"
    name        = var.bootstrap_k8s.gateway_name
    class_name  = "approuting-istio"
    namespace   = var.anyscale_operator_namespace
    api_version = "gateway.networking.k8s.io/v1"
    hostname    = local.gateway_internal_lb_ip
  }
  anyscale_platform_extension_configuration_defaults = {
    "workloads.accelerator.tolerations.default[0].key"      = "node.anyscale.com/accelerator-type"
    "workloads.accelerator.tolerations.default[0].value"    = "GPU"
    "workloads.accelerator.tolerations.default[0].effect"   = "NoSchedule"
    "workloads.accelerator.tolerations.default[1].key"      = "nvidia.com/gpu"
    "workloads.accelerator.tolerations.default[1].operator" = "Exists"
    "workloads.accelerator.tolerations.default[1].effect"   = "NoSchedule"
    "workloads.instanceTypes.enableDefaults"                = "true"
  }
  anyscale_platform_extension_configuration_settings = merge(
    local.anyscale_platform_extension_configuration_defaults,
    var.anyscale_platform.extension_configuration_settings,
  )
  anyscale_platform_deployments = {
    top_level    = "dep-anyscale-${local.suffix}"
    blob         = "dep-anyblob-${local.suffix}"
    fic          = "dep-anyfic-${local.suffix}"
    storage_rbac = "dep-anystoragerbac-${local.suffix}"
    acr_rbac     = "dep-anyacrrbac-${local.suffix}"
  }
  anyscale_platform_role_name_aliases = {
    "Anyscale Platform Administrator" = "Anyscale Platform Administrator Role"
    "Anyscale Platform Contributor"   = "Anyscale Platform Contributor Role"
    "Anyscale Platform Reader"        = "Anyscale Platform Reader Role"
  }
  anyscale_platform_role_scopes = {
    subscription   = local.anyscale_platform_subscription_scope
    resource_group = local.resource_group_id
    cloud          = local.anyscale_platform_cloud_arm_id
  }
  anyscale_platform_default_admin_role_assignment = var.anyscale_platform_default_admin_assignment.enabled ? {
    current_principal_admin = {
      principal_id         = data.azurerm_client_config.current.object_id
      principal_type       = var.anyscale_platform_default_admin_assignment.principal_type
      role_definition_id   = var.anyscale_platform_default_admin_assignment.role_definition_id
      role_definition_name = var.anyscale_platform_default_admin_assignment.role_definition_name
      scope                = var.anyscale_platform_default_admin_assignment.scope
      custom_scope         = var.anyscale_platform_default_admin_assignment.custom_scope
    }
  } : {}
  anyscale_platform_explicit_role_assignments = {
    for key, assignment in var.anyscale_platform_role_assignments : key => {
      principal_id         = assignment.principal_id
      principal_type       = assignment.principal_type
      role_definition_id   = assignment.role_definition_id
      role_definition_name = assignment.role_definition_name
      scope                = assignment.scope
      custom_scope         = assignment.custom_scope
    }
  }
  anyscale_platform_legacy_admin_role_assignments = {
    for key, assignment in var.anyscale_platform_admin_role_assignments : "legacy_${key}" => {
      principal_id         = assignment.principal_id
      principal_type       = assignment.principal_type
      role_definition_id   = assignment.role_definition_id
      role_definition_name = assignment.role_definition_name
      scope                = "cloud"
      custom_scope         = null
    }
  }
  anyscale_platform_effective_role_assignments = merge(
    local.anyscale_platform_default_admin_role_assignment,
    local.anyscale_platform_explicit_role_assignments,
    local.anyscale_platform_legacy_admin_role_assignments,
  )
  anyscale_platform_resolved_role_assignments = {
    for key, assignment in local.anyscale_platform_effective_role_assignments : key => merge(assignment, {
      effective_role_definition_name = assignment.role_definition_name == null ? null : lookup(local.anyscale_platform_role_name_aliases, assignment.role_definition_name, assignment.role_definition_name)
      effective_scope                = assignment.scope == "custom" ? assignment.custom_scope : local.anyscale_platform_role_scopes[assignment.scope]
    })
  }
}

data "azurerm_client_config" "current" {}

# The Anyscale portal still exports the cloud resource path as an ARM template.
# Keep that contract intact with AzAPI, but manage the AKS marketplace
# extension natively with azurerm to shrink the generic AzAPI surface.
resource "azapi_resource" "anyscale_platform" {
  count = local.anyscale_platform_enabled ? 1 : 0

  type                      = "Microsoft.Resources/deployments@2022-09-01"
  name                      = local.anyscale_platform_deployments.top_level
  parent_id                 = local.resource_group_id
  schema_validation_enabled = false
  response_export_values = {
    cloud_deployment_id = "properties.outputs.cloudResourceId.value"
    provisioning_state  = "properties.provisioningState"
  }
  body = {
    properties = {
      mode     = "Incremental"
      template = jsondecode(file("${path.module}/templates/anyscale-platform-cloud.template.json"))
      parameters = {
        location = {
          value = local.resource_group_location
        }
        cloudName = {
          value = local.anyscale_platform_cloud_name
        }
        storageAccountName = {
          value = module.storage.storage_account_name
        }
        storageMode = {
          value = "existing"
        }
        storageAccountResourceId = {
          value = module.storage.storage_account_id
        }
        storageContainerName = {
          value = module.storage.container_name
        }
        workloadIdentityName = {
          value = module.identity.name
        }
        identityMode = {
          value = "existing"
        }
        identityResourceId = {
          value = module.identity.id
        }
        tagsByResource = {
          value = var.anyscale_platform.tags_by_resource
        }
        acrMode = {
          value = "existing"
        }
        acrName = {
          value = module.acr.acr_name
        }
        acrResourceId = {
          value = module.acr.acr_id
        }
        aksKubeletPrincipalId = {
          value = module.aks.kubelet_identity_object_id
        }
        manageAksKubeletAcrPullRoleAssignment = {
          value = false
        }
        storageBlobServiceDeploymentName = {
          value = local.anyscale_platform_deployments.blob
        }
        federatedIdentityDeploymentName = {
          value = local.anyscale_platform_deployments.fic
        }
        storageRoleAssignmentDeploymentName = {
          value = local.anyscale_platform_deployments.storage_rbac
        }
        acrRoleAssignmentsDeploymentName = {
          value = local.anyscale_platform_deployments.acr_rbac
        }
      }
    }
  }

  depends_on = [
    module.aks,
    module.storage,
    module.identity,
    module.acr,
  ]
}

resource "azurerm_kubernetes_cluster_extension" "anyscale_operator" {
  count = local.anyscale_platform_enabled ? 1 : 0

  name              = local.anyscale_platform_extension_name
  cluster_id        = module.aks.cluster_id
  extension_type    = "Anyscale.AKS.Operator"
  release_train     = var.anyscale_platform.extension_version == null ? local.anyscale_platform_extension_release_train : null
  release_namespace = var.anyscale_operator_namespace
  version           = var.anyscale_platform.extension_version

  plan {
    name      = var.anyscale_platform.plan_name
    publisher = var.anyscale_platform.plan_publisher
    product   = var.anyscale_platform.plan_product
  }

  configuration_settings = merge(
    {
      "global.cloudDeploymentId"      = azapi_resource.anyscale_platform[0].output.cloud_deployment_id
      "global.controlPlaneURL"        = var.anyscale_platform.control_plane_url
      "global.auth.iamIdentity"       = module.identity.client_id
      "global.auth.audience"          = var.anyscale_platform.auth_audience
      "workloads.serviceAccount.name" = var.anyscale_operator_serviceaccount
      "networking.gateway.enabled"    = local.anyscale_platform_gateway_configuration.enabled
      "networking.gateway.name"       = local.anyscale_platform_gateway_configuration.name
      "networking.gateway.className"  = local.anyscale_platform_gateway_configuration.class_name
      "networking.gateway.namespace"  = local.anyscale_platform_gateway_configuration.namespace
      "networking.gateway.apiVersion" = local.anyscale_platform_gateway_configuration.api_version
      "networking.gateway.hostname"   = local.anyscale_platform_gateway_configuration.hostname
    },
    local.anyscale_platform_extension_configuration_settings,
  )

  configuration_protected_settings = var.anyscale_cli_token == null ? {} : {
    "global.auth.anyscaleCliToken" = var.anyscale_cli_token
  }

  # Keep the cloud-to-extension edge explicit even though
  # global.cloudDeploymentId already creates an implicit dependency. The
  # teardown hook handles the non-inverse delete requirement by deleting the
  # cloud before Terraform tears down the extension and AKS cluster.
  # NOTE: the operator namespace and service account are pre-created by the
  # jump-box bootstrap script before this Terraform apply runs.
  depends_on = [
    azapi_resource.anyscale_platform,
  ]
}

resource "azurerm_role_assignment" "anyscale_platform" {
  for_each = local.anyscale_platform_enabled ? local.anyscale_platform_resolved_role_assignments : {}

  scope                = each.value.effective_scope
  role_definition_id   = try(each.value.role_definition_id, null)
  role_definition_name = try(each.value.role_definition_id, null) == null ? each.value.effective_role_definition_name : null
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type

  depends_on = [azapi_resource.anyscale_platform]
}

# Azure cloud teardown hook: while the cloud, extension, AKS backing
# resources, and private-link dependencies still exist, drain Anyscale jobs,
# services, workspaces, and cluster sessions, then delete the cloud before
# Terraform proceeds to extension, AKS, private endpoint, DNS, and network
# teardown.
resource "terraform_data" "anyscale_platform_destroy_workaround" {
  count = local.anyscale_platform_enabled && local.anyscale_platform_destroy_workaround_enabled ? 1 : 0

  input = {
    repo_root             = abspath("${path.root}/../..")
    anyscale_host         = var.anyscale_platform.control_plane_url
    anyscale_cli_token    = var.anyscale_cli_token
    anyscale_cloud_name   = local.anyscale_platform_cloud_control_plane_name
    anyscale_cloud_arm_id = local.anyscale_platform_cloud_arm_id
    azure_subscription_id = var.azure_subscription_id
    timeout_seconds       = local.anyscale_platform_destroy_workaround_runtime_timeout_seconds
    poll_interval_seconds = local.anyscale_platform_destroy_workaround_poll_interval_seconds
  }

  provisioner "local-exec" {
    when        = destroy
    working_dir = self.input.repo_root
    command     = "./scripts/lib/anyscale-cloud-teardown.sh --timeout-seconds ${self.input.timeout_seconds} --poll-interval-seconds ${self.input.poll_interval_seconds}"

    environment = {
      ANYSCALE_HOST         = self.input.anyscale_host
      ANYSCALE_CLI_TOKEN    = self.input.anyscale_cli_token
      ANYSCALE_CLOUD_NAME   = self.input.anyscale_cloud_name
      ANYSCALE_CLOUD_ARM_ID = self.input.anyscale_cloud_arm_id
      AZURE_SUBSCRIPTION_ID = self.input.azure_subscription_id
    }
  }

  depends_on = [
    azapi_resource.anyscale_platform,
    azurerm_kubernetes_cluster_extension.anyscale_operator,
    module.acr,
    module.aks,
    module.bastion,
    module.dns,
    module.dns_resolver,
    module.firewall,
    module.identity,
    module.network,
    module.observability,
    module.routing,
    module.storage,
  ]
}
