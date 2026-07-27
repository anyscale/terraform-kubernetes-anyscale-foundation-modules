###############################################################################
# Plan-only validation test for Phase 1.
# Does not call Azure APIs (uses `command = plan`) — verifies that the
# composition is syntactically valid, all required variables have defaults,
# and naming logic produces the expected resource names.
#
# Run with:
#   terraform test
###############################################################################

variables {
  project        = "tftest"
  environment    = "ci"
  azure_location = "westus3"
  region_short   = "wus3"

  vnet_address_space = ["10.50.0.0/16"]
  subnet_cidrs = {
    firewall          = "10.50.0.0/26"
    bastion           = "10.50.0.128/26"
    aks_apiserver     = "10.50.1.0/28"
    dns_resolver_in   = "10.50.1.16/28"
    dns_resolver_out  = "10.50.1.32/28"
    private_endpoints = "10.50.2.0/24"
    jump_host         = "10.50.3.0/27"
    browser_jump_host = "10.50.3.32/27"
    aks_nodes         = "10.50.4.0/22"
  }

  dns_forwarding_rules = {}

  anyscale_fqdns = [
    "console.anyscale.com",
    "console.azure.anyscale.com",
    "api.azure.anyscale.com",
    "*.anyscale-cloud.dev",
    "*.azure.anyscale-cloud.dev",
    "*.az1.westus2.admin.azure.anyscale.com",
    "anyscaleazwestus2prod.blob.core.windows.net",
    "anyscaleazwestus2prod.dfs.core.windows.net",
    "api.anyscale.com",
    "anyscale-public.s3.us-west-2.amazonaws.com",
    "anyscale.com",
    "learn.microsoft.com",
  ]

  container_registry_fqdns = [
    "mcr.microsoft.com",
    "*.data.mcr.microsoft.com",
    "ghcr.io",
    "*.ghcr.io",
    "pkg-containers.githubusercontent.com",
    "*.docker.io",
    "registry-1.docker.io",
    "auth.docker.io",
    "production.cloudflare.docker.com",
    "production.cloudfront.docker.com",
    "quay.io",
    "*.quay.io",
    "registry.k8s.io",
    "k8s.gcr.io",
    "gcr.io",
    "*.gcr.io",
    "*.pkg.dev",
    "us-docker.pkg.dev",
    "europe-docker.pkg.dev",
    "asia-docker.pkg.dev",
    "nvcr.io",
    "*.nvcr.io",
    "authn.nvidia.com",
    "arcmktplaceprod.azurecr.io",
    "*.data.azurecr.io",
    "prod-registry-k8s-io-us-west-1.s3.dualstack.us-west-1.amazonaws.com",
  ]

  system_vm_size                       = "Standard_D2s_v5"
  cpu_vm_size                          = "Standard_D16s_v5"
  linux_jump_host_vm_size              = "Standard_D2s_v5"
  linux_jump_host_admin_username       = "azureoperator"
  linux_jump_host_admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKbBsj5ktF3GEfYJ5G5O2CP658q5S7Lf4K3b4BVVij7F terraform-test"
  gpu_pool_configs = {
    T4 = {
      name         = "gput4"
      vm_size      = "Standard_NC16as_T4_v3"
      product_name = "NVIDIA-T4"
      gpu_count    = "1"
      min_count    = 1
      max_count    = 2
    }
  }

  kubernetes_version               = "1.34.6"
  service_cidr                     = "10.100.0.0/16"
  dns_service_ip                   = "10.100.0.10"
  anyscale_operator_namespace      = "anyscale-operator"
  anyscale_operator_serviceaccount = "anyscale-operator"
  anyscale_platform = {
    enabled = false
  }
  storage_cors_rule = {
    allowed_headers    = ["*"]
    allowed_methods    = ["GET", "POST", "PUT", "HEAD", "DELETE"]
    allowed_origins    = ["https://*.anyscale.com"]
    expose_headers     = ["Accept-Ranges", "Content-Range", "Content-Length"]
    max_age_in_seconds = 0
  }

  log_analytics_retention_days = 30
  tags = {
    Project     = "tftest"
    Environment = "ci"
    ManagedBy   = "terraform"
    Owner       = "terraform-test"
  }
}

run "naming_and_validate_plan" {
  command = plan

  assert {
    condition     = output.resource_group_name == "rg-tftest-ci-wus3"
    error_message = "Resource group name does not match the CAF naming convention."
  }

  assert {
    condition     = output.aks_cluster_name == "aks-tftest-ci-wus3"
    error_message = "AKS cluster name does not match the CAF naming convention."
  }

  assert {
    condition     = output.bastion_name == "bas-tftest-ci-wus3"
    error_message = "Bastion name does not match the CAF naming convention."
  }

  assert {
    condition     = length(output.dns_resolver_inbound_endpoint_ip) > 0
    error_message = "DNS Private Resolver inbound endpoint IP must be exported."
  }

  assert {
    condition     = output.private_mode_validation.observability.ampls_enabled == true && output.private_mode_validation.container_insights.container_log_v2_enabled == true
    error_message = "Plan must include AMPLS and ContainerLogV2 observability posture."
  }

  assert {
    condition     = output.anyscale_operator_workload_identity.namespace == "anyscale-operator" && output.anyscale_operator_workload_identity.service_account == "anyscale-operator" && output.anyscale_operator_workload_identity.pod_labels["azure.workload.identity/use"] == "true" && contains(keys(output.anyscale_operator_workload_identity.service_account_annotations), "azure.workload.identity/client-id")
    error_message = "Anyscale operator Workload Identity install values must expose the namespace, service account, pod label, and client-id annotation."
  }

  assert {
    condition     = output.bootstrap_script_contract.service_account.annotations["meta.helm.sh/release-name"] == "anyscaleoperator" && output.bootstrap_script_contract.helm_releases.nvidia_device_plugin.chart_version == "0.17.1" && output.bootstrap_script_contract.helm_releases.anyscale_gateway.gateway_class_name == "approuting-istio" && output.bootstrap_script_contract.helm_releases.anyscale_gateway.gateway_private_ip == "10.50.7.251" && output.bootstrap_script_contract.helm_releases.anyscale_gateway.session_hostname == "*.i.azure.anyscaleuserdata.com" && output.bootstrap_script_contract.helm_releases.anyscale_gateway.service_hostname == "*.s.azure.anyscaleuserdata.com" && length(output.bootstrap_script_contract.helm_releases.anyscale_gateway.https_listeners) == 0 && output.bootstrap_script_contract.helm_releases.anyscale_gateway.service_annotations["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true" && output.bootstrap_script_contract.helm_releases.anyscale_gateway.service_annotations["service.beta.kubernetes.io/azure-load-balancer-ipv4"] == "10.50.7.251"
    error_message = "The jump-box bootstrap script contract must expose Helm-adoptable service account metadata, pinned Helm release settings, and managed Gateway API settings."
  }

  assert {
    condition     = output.private_mode_validation.aks.app_routing_istio_enabled == true && output.private_mode_validation.aks.app_routing_istio_gateway_class == "approuting-istio" && output.private_mode_validation.aks.managed_gateway_api_installation == "Standard"
    error_message = "The AKS contract must enable managed Gateway API and app-routing Istio."
  }

  assert {
    condition     = output.anyscale_platform_contract.cloud_management_mode == "azapi_arm_template" && output.anyscale_platform_contract.extension_management_mode == "azurerm_kubernetes_cluster_extension" && output.anyscale_platform_contract.extension_type == "Anyscale.AKS.Operator" && output.anyscale_platform_contract.extension_release_namespace == "anyscale-operator" && output.anyscale_platform_contract.extension_service_account_name == "anyscale-operator" && contains(output.anyscale_platform_contract.dynamic_configuration_keys, "global.cloudDeploymentId") && contains(output.anyscale_platform_contract.dynamic_configuration_keys, "networking.gateway.enabled") && output.anyscale_platform_contract.gateway.enabled == "true" && output.anyscale_platform_contract.gateway.name == "anyscale-gateway" && output.anyscale_platform_contract.gateway.class_name == "approuting-istio" && output.anyscale_platform_contract.gateway.namespace == "anyscale-operator" && output.anyscale_platform_contract.gateway.api_version == "gateway.networking.k8s.io/v1" && output.anyscale_platform_contract.gateway.hostname == "10.50.7.251" && output.anyscale_platform_contract.extension_configuration_settings["workloads.accelerator.tolerations.default[0].key"] == "node.anyscale.com/accelerator-type" && output.anyscale_platform_contract.extension_configuration_settings["workloads.accelerator.tolerations.default[1].key"] == "nvidia.com/gpu" && output.anyscale_platform_contract.extension_configuration_settings["workloads.accelerator.tolerations.default[1].operator"] == "Exists" && output.anyscale_platform_contract.lifecycle.create_order[1] == "anyscale_cloud" && output.anyscale_platform_contract.lifecycle.create_order[2] == "cluster_bootstrap" && output.anyscale_platform_contract.lifecycle.destroy_order[0] == "drain_jobs_services_workspaces_and_cluster_sessions" && output.anyscale_platform_contract.lifecycle.destroy_order[1] == "delete_anyscale_cloud" && output.anyscale_platform_contract.teardown.enabled == true && output.anyscale_platform_contract.teardown.mode == "terraform_data_local_exec" && contains(output.anyscale_platform_contract.teardown.runtime_objects, "jobs") && contains(output.anyscale_platform_contract.teardown.runtime_objects, "services") && contains(output.anyscale_platform_contract.teardown.runtime_objects, "workspaces") && contains(output.anyscale_platform_contract.teardown.runtime_objects, "cluster_sessions") && output.anyscale_platform_contract.teardown.cloud_delete_stage == "before_extension_and_aks_destroy"
    error_message = "The Anyscale contract must keep the cloud on the AzAPI ARM path, move the AKS extension to the native azurerm resource, keep the cloud teardown hook, expose the intended lifecycle ordering, and declaratively include the taint-toleration defaults for GPU pools."
  }

  assert {
    condition     = output.anyscale_platform_contract.role_assignments.current_principal_admin.role_definition_name == "Anyscale Platform Administrator Role" && output.anyscale_platform_contract.role_assignments.current_principal_admin.scope == "/subscriptions/${var.azure_subscription_id}"
    error_message = "The default Anyscale Platform role contract must grant the deploying principal the subscription-scoped Administrator role for org-owner-style access."
  }

}

run "anyscale_platform_native_extension_contract" {
  command = plan

  variables {
    anyscale_platform = {
      enabled = true
    }
  }

  assert {
    condition     = output.bootstrap_script_contract.service_account.annotations["meta.helm.sh/release-name"] == "anyscaleoperator"
    error_message = "The jump-box bootstrap script contract must keep the Helm-adoptable operator service account metadata intact when the platform is enabled."
  }

  assert {
    condition     = output.anyscale_platform_contract.enabled == true && output.anyscale_platform_contract.extension_release_train == "Stable" && output.anyscale_platform_contract.extension_management_mode == "azurerm_kubernetes_cluster_extension" && output.anyscale_platform_contract.control_plane_url == "https://console.azure.anyscale.com" && output.anyscale_platform_contract.teardown.runtime_termination_timeout_seconds == 900 && output.anyscale_platform_contract.teardown.poll_interval_seconds == 20
    error_message = "The enabled platform contract must normalize the release train for the native azurerm AKS extension resource, default the extension control plane to the Azure console host, and keep the runtime-drain cloud teardown defaults stable."
  }

  assert {
    condition     = output.anyscale_platform_contract.role_assignments.current_principal_admin.role_definition_name == "Anyscale Platform Administrator Role" && output.anyscale_platform_contract.role_assignments.current_principal_admin.scope == "/subscriptions/${var.azure_subscription_id}"
    error_message = "The enabled platform contract must keep the deploying principal as a subscription-scoped Anyscale Platform Administrator by default."
  }
}
