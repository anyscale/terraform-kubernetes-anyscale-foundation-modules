output "resource_group_name" {
  description = "Name of the resource group."
  value       = local.resource_group_name
}

output "location" {
  description = "Azure region of the deployment."
  value       = local.resource_group_location
}

output "vnet_id" {
  description = "ID of the workload VNet."
  value       = local.net_vnet_id
}

output "subnet_ids" {
  description = "Map of subnet IDs created by the network module."
  value       = local.net_subnet_ids
}

output "firewall_private_ip" {
  description = "Azure Firewall private IP — UDR next-hop for AKS."
  value       = local.net_firewall_private_ip
}

output "dns_resolver_inbound_endpoint_ip" {
  description = "Azure DNS Private Resolver inbound endpoint IP for hybrid DNS clients and conditional forwarding patterns."
  value       = local.net_dns_resolver_inbound_ip
}

output "dns_resolver_forwarding_ruleset_id" {
  description = "Azure DNS Private Resolver forwarding ruleset ID."
  value       = module.dns_resolver.forwarding_ruleset_id
}

output "vnet_dns_servers" {
  description = "Custom DNS servers configured on the workload VNet."
  value       = local.net_vnet_dns_servers
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID (full ARM id)."
  value       = module.observability.log_analytics_workspace_id
}

output "log_analytics_workspace_customer_id" {
  description = "Log Analytics workspace customer ID used by Azure CLI query commands."
  value       = module.observability.log_analytics_workspace_customer_id
}

output "storage_account_name" {
  description = "Storage account name."
  value       = module.storage.storage_account_name
}

output "anyscale_operator_identity_client_id" {
  description = "Client ID of the Anyscale operator user-assigned managed identity."
  value       = module.identity.client_id
}

output "anyscale_operator_identity_id" {
  description = "Resource ID of the Anyscale operator user-assigned managed identity."
  value       = module.identity.id
}

output "anyscale_operator_identity_principal_id" {
  description = "Principal ID of the Anyscale operator user-assigned managed identity."
  value       = module.identity.principal_id
}

###############################################################################
# Phase 2 outputs
###############################################################################
output "aks_cluster_name" {
  description = "Name of the AKS cluster."
  value       = module.aks.cluster_name
}

output "aks_private_fqdn" {
  description = "Private FQDN of the AKS API server."
  value       = module.aks.private_fqdn
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster (for additional federated credentials)."
  value       = module.aks.oidc_issuer_url
}

output "acr_login_server" {
  description = "ACR login server (privatelink)."
  value       = module.acr.login_server
}

output "key_vault_name" {
  description = "Name of the Key Vault holding the image signing certificate."
  value       = module.keyvault.key_vault_name
}

output "key_vault_uri" {
  description = "URI of the signing Key Vault (used by the Ratify KeyManagementProvider CRD)."
  value       = module.keyvault.key_vault_uri
}

output "image_signing_cert_name" {
  description = "Name of the Notation signing certificate in Key Vault."
  value       = var.image_signing_cert_name
}

output "ratify_client_id" {
  description = "Client ID of the Ratify workload identity (used by the Ratify Store/KMP CRDs)."
  value       = module.image_integrity.ratify_client_id
}

output "bastion_name" {
  description = "Azure Bastion host name."
  value       = local.net_bastion_name
}

output "bastion_id" {
  description = "Azure Bastion host resource ID."
  value       = local.net_bastion_id
}

output "linux_jump_host_vm_id" {
  description = "Resource ID of the Linux automation jump host."
  value       = module.jump_host.vm_id
}

output "linux_jump_host_vm_name" {
  description = "Name of the Linux automation jump host."
  value       = module.jump_host.vm_name
}

output "linux_jump_host_private_ip" {
  description = "Private IP of the Linux automation jump host."
  value       = module.jump_host.private_ip_address
}

output "linux_jump_host_principal_id" {
  description = "Principal ID of the Linux jump-host managed identity."
  value       = module.jump_host.principal_id
}

output "linux_jump_host_admin_username" {
  description = "Admin username for the Linux jump host."
  value       = module.jump_host.admin_username
}

output "browser_jump_host_enabled" {
  description = "Whether the Windows browser jump host was created."
  value       = module.browser_jump_host.enabled
}

output "browser_jump_host_vm_id" {
  description = "Resource ID of the Windows browser jump host."
  value       = module.browser_jump_host.vm_id
}

output "browser_jump_host_vm_name" {
  description = "Name of the Windows browser jump host."
  value       = module.browser_jump_host.vm_name
}

output "browser_jump_host_private_ip" {
  description = "Private IP of the Windows browser jump host."
  value       = module.browser_jump_host.private_ip_address
}

output "anyscale_userdata_gateway_ip" {
  description = "Gateway internal LB IP that the private userdata wildcard records resolve to."
  value       = local.gateway_internal_lb_ip
}

output "anyscale_cloud_name" {
  description = "Terraform-managed Anyscale cloud name when the AzAPI deployment path is enabled."
  value       = local.anyscale_platform_enabled ? local.anyscale_platform_cloud_name : null
}

output "anyscale_cloud_id" {
  description = "Resource ID of the Terraform-managed Anyscale cloud."
  value       = local.anyscale_platform_enabled ? "${local.resource_group_id}/providers/Anyscale.Platform/clouds/${local.anyscale_platform_cloud_name}" : null
}

output "anyscale_cloud_resource_id" {
  description = "Resource ID of the Terraform-managed default Anyscale cloud resource."
  value       = local.anyscale_platform_enabled ? "${local.resource_group_id}/providers/Anyscale.Platform/clouds/${local.anyscale_platform_cloud_name}/cloudResources/default" : null
}

output "anyscale_cloud_deployment_id" {
  description = "Anyscale cloud deployment ID emitted by the Azure-native Anyscale cloud resource."
  value       = local.anyscale_platform_enabled ? azapi_resource.anyscale_platform[0].output.cloud_deployment_id : null
}

output "anyscale_extension_resource_id" {
  description = "Resource ID of the Terraform-managed AKS Anyscale extension."
  value       = local.anyscale_platform_enabled ? azurerm_kubernetes_cluster_extension.anyscale_operator[0].id : null
}

output "anyscale_extension_name" {
  description = "Name of the Terraform-managed AKS Anyscale extension."
  value       = local.anyscale_platform_enabled ? azurerm_kubernetes_cluster_extension.anyscale_operator[0].name : null
}

output "anyscale_platform_contract" {
  description = "Plan-time lifecycle contract for the Terraform-managed Anyscale cloud, AKS marketplace extension, and Azure cloud teardown hook."
  value = {
    enabled                          = local.anyscale_platform_enabled
    cloud_name                       = local.anyscale_platform_cloud_name
    cloud_management_mode            = "azapi_arm_template"
    extension_management_mode        = "azurerm_kubernetes_cluster_extension"
    extension_type                   = "Anyscale.AKS.Operator"
    extension_resource_name          = local.anyscale_platform_extension_name
    extension_release_namespace      = var.anyscale_operator_namespace
    extension_service_account_name   = var.anyscale_operator_serviceaccount
    extension_release_train          = local.anyscale_platform_extension_release_train
    control_plane_url                = var.anyscale_platform.control_plane_url
    dynamic_configuration_keys       = local.anyscale_platform_extension_dynamic_configuration_keys
    extension_configuration_settings = local.anyscale_platform_extension_configuration_settings
    gateway                          = local.anyscale_platform_gateway_configuration
    role_assignments = {
      for key, assignment in local.anyscale_platform_resolved_role_assignments : key => {
        principal_id         = assignment.principal_id
        principal_type       = assignment.principal_type
        role_definition_id   = assignment.role_definition_id
        role_definition_name = assignment.effective_role_definition_name
        scope                = assignment.effective_scope
      }
    }
    lifecycle = {
      create_order  = local.anyscale_platform_lifecycle_create_order
      destroy_order = local.anyscale_platform_lifecycle_destroy_order
    }
    teardown = {
      enabled                               = local.anyscale_platform_destroy_workaround_enabled
      mode                                  = "terraform_data_local_exec"
      runtime_objects                       = local.anyscale_platform_destroy_workaround_runtime_objects
      cloud_delete_stage                    = "before_extension_and_aks_destroy"
      runtime_termination_timeout_seconds   = local.anyscale_platform_destroy_workaround_runtime_timeout_seconds
      workspace_termination_timeout_seconds = local.anyscale_platform_destroy_workaround_runtime_timeout_seconds
      poll_interval_seconds                 = local.anyscale_platform_destroy_workaround_poll_interval_seconds
    }
  }
}

output "bootstrap_script_contract" {
  description = "Static plan-time contract for the jump-box bootstrap script that pre-creates the operator namespace, service account, NVIDIA device plugin, and Anyscale Gateway in the private AKS cluster before the Anyscale marketplace extension is installed."
  value = {
    operator_namespace          = var.anyscale_operator_namespace
    operator_service_account    = var.anyscale_operator_serviceaccount
    azure_tenant_id             = var.azure_tenant_id
    operator_identity_client_id = module.identity.client_id
    extension_release_name      = local.anyscale_platform_extension_name
    service_account = {
      namespace = var.anyscale_operator_namespace
      name      = var.anyscale_operator_serviceaccount
      labels = {
        "app.kubernetes.io/managed-by" = "Helm"
        "azure.workload.identity/use"  = "true"
      }
      annotations = {
        "meta.helm.sh/release-name"         = local.anyscale_platform_extension_name
        "meta.helm.sh/release-namespace"    = var.anyscale_operator_namespace
        "azure.workload.identity/client-id" = module.identity.client_id
        "azure.workload.identity/tenant-id" = var.azure_tenant_id
      }
    }
    helm_releases = {
      nvidia_device_plugin = {
        namespace     = var.bootstrap_k8s.gpu_resources_namespace
        release_name  = var.bootstrap_k8s.nvidia_device_plugin_release_name
        chart         = "nvidia-device-plugin"
        repository    = "https://nvidia.github.io/k8s-device-plugin"
        chart_version = var.bootstrap_k8s.nvidia_device_plugin_chart_version
      }
      anyscale_gateway = {
        namespace          = var.anyscale_operator_namespace
        release_name       = var.bootstrap_k8s.gateway_release_name
        chart              = "anyscale-gateway"
        gateway_name       = var.bootstrap_k8s.gateway_name
        gateway_class_name = "approuting-istio"
        gateway_private_ip = local.gateway_internal_lb_ip
        session_hostname   = "*.i.azure.anyscaleuserdata.com"
        service_hostname   = "*.s.azure.anyscaleuserdata.com"
        https_listeners    = var.bootstrap_k8s.gateway_service_https_enabled ? ["https"] : []
        service_name       = var.bootstrap_k8s.gateway_service_name
        service_annotations = {
          "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
          "service.beta.kubernetes.io/azure-load-balancer-ipv4"     = local.gateway_internal_lb_ip
          "gateway.istio.io/name-override"                          = var.bootstrap_k8s.gateway_service_name
        }
      }
    }
  }
}

###############################################################################
# Convenience commands
###############################################################################
output "aks_get_credentials_command" {
  description = "Run this to fetch Entra-backed kubeconfig, then run kubelogin convert-kubeconfig -l azurecli."
  value       = "az aks get-credentials --resource-group ${local.resource_group_name} --name ${module.aks.cluster_name} --overwrite-existing && kubelogin convert-kubeconfig -l azurecli"
}

output "aks_bastion_connect_command" {
  description = "Open a Bastion tunnel to the private AKS API server using Entra-backed kubelogin access (preview)."
  value       = "az aks bastion --name ${module.aks.cluster_name} --resource-group ${local.resource_group_name} --bastion ${local.net_bastion_id}"
}

output "aks_bastion_admin_connect_command" {
  description = "Fallback admin Bastion tunnel command for break-glass validation. Prefer aks_bastion_connect_command."
  value       = "az aks bastion --name ${module.aks.cluster_name} --resource-group ${local.resource_group_name} --admin --bastion ${local.net_bastion_id}"
}

output "private_mode_validation" {
  description = "Private AKS and locked-down egress invariants consumed by terraform tests."
  value = {
    aks                = module.aks.private_mode
    workload_identity  = module.aks.workload_identity
    routing            = module.routing.egress_route
    firewall           = module.firewall.egress_validation
    dns_resolver       = module.dns_resolver.private_dns_resolver_validation
    vnet_dns_servers   = local.net_vnet_dns_servers
    acr                = module.acr.private_mode
    storage            = module.storage.private_mode
    observability      = module.observability.private_link_validation
    container_insights = module.aks.container_insights
    identity           = module.identity.storage_access
    bastion            = module.bastion.private_aks_access
    kubelogin_access   = module.aks.kubelogin_access
  }
}

output "anyscale_operator_identity_contract" {
  description = "Plan-time identity mode contract for the Anyscale operator user-assigned managed identity."
  value = {
    mode                      = local.anyscale_operator_identity_mode
    created_by_terraform      = local.anyscale_operator_identity_created_by_tf
    managed_by_terraform      = local.anyscale_operator_storage_rbac_managed_by_tf
    role_definition_name      = local.anyscale_operator_storage_role_definition_name
    expected_storage_scope_id = module.storage.container_id
    existing_identity = local.anyscale_operator_identity_created_by_tf ? null : {
      id           = var.anyscale_operator_identity.id
      client_id    = var.anyscale_operator_identity.client_id
      principal_id = var.anyscale_operator_identity.principal_id
      name         = var.anyscale_operator_identity.name
    }
  }
}

output "anyscale_platform_admin_role_assignments" {
  description = "Azure RBAC role assignments Terraform manages for Anyscale Platform built-in roles."
  value = {
    for key, assignment in azurerm_role_assignment.anyscale_platform : key => {
      id                 = assignment.id
      principal_id       = assignment.principal_id
      role_definition_id = assignment.role_definition_id
      scope              = assignment.scope
    }
  }
}

output "anyscale_operator_workload_identity" {
  description = "Kubernetes Workload Identity values for the Anyscale operator service account and storage data-plane access."
  value = {
    namespace         = var.anyscale_operator_namespace
    service_account   = var.anyscale_operator_serviceaccount
    tenant_id         = var.azure_tenant_id
    client_id         = module.identity.client_id
    principal_id      = module.identity.principal_id
    identity_id       = module.identity.id
    federated_subject = module.aks.workload_identity.subject
    service_account_annotations = {
      "azure.workload.identity/client-id" = module.identity.client_id
      "azure.workload.identity/tenant-id" = var.azure_tenant_id
    }
    pod_labels = {
      "azure.workload.identity/use" = "true"
    }
    storage = {
      account_name  = module.storage.storage_account_name
      container_id  = module.storage.container_id
      container     = module.storage.container_name
      blob_endpoint = module.storage.blob_endpoint
      dfs_endpoint  = module.storage.dfs_endpoint
      rbac          = module.identity.storage_access
    }
  }
}

output "anyscale_privatelink" {
  description = <<-EOT
    Anyscale control-plane Private Link state, DNS records, and the firewall
    FQDNs it supersedes. Nulls/empty when enable_anyscale_privatelink is false.

    The cross-tenant approval status is deliberately absent: azurerm does not
    export it on azurerm_private_endpoint, and Terraform would report a stale
    value if it did. Check it against Azure directly:

      az network private-endpoint-connection list --id <endpoint_id> -o table
  EOT
  value = {
    enabled      = var.enable_anyscale_privatelink
    endpoint_id  = module.anyscale_privatelink.endpoint_id
    private_ip   = module.anyscale_privatelink.private_ip
    record_fqdns = module.anyscale_privatelink.record_fqdns
    superseded_firewall_fqdns = [
      for fqdn in var.anyscale_fqdns : fqdn
      if !contains(local.firewall_anyscale_fqdns, fqdn)
    ]
  }
}
