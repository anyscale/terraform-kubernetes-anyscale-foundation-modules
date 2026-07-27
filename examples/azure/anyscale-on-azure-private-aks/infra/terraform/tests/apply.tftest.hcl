###############################################################################
# Full apply test — provisions all Phase 1 resources, asserts shape, then
# tears everything down automatically (terraform test always destroys).
#
# Run with (all five are required — see the note on precedence below):
#   TF_VAR_azure_subscription_id="$(az account show --query id -o tsv)" \
#   TF_VAR_azure_tenant_id="$(az account show --query tenantId -o tsv)" \
#   TF_VAR_project=tftest7f3a TF_VAR_environment=ci \
#   TF_VAR_azure_location=westus2 TF_VAR_region_short=wus2 \
#     terraform test -filter=tests/apply.tftest.hcl -verbose
#
# project / environment / azure_location / region_short are deliberately absent
# from the `variables` block below. A file-level `variables` block outranks both
# -var and TF_VAR_*, so pinning them here would make the suite unrunnable outside
# whatever region and name were pinned. Two things forced this:
#   - The region must be quota-selectable. The old hardcoded westus3 fails with
#     ErrCode_InsufficientVCPUQuota in subscriptions whose DSv5 quota lives
#     elsewhere.
#   - The storage account name is derived from project/environment/region_short
#     and must be globally unique. A fixed token permanently burns that name
#     ("StorageAccountAlreadyTaken") once any run has claimed it, so use a
#     project token with a random suffix.
#
# Requires Microsoft.Authorization/policyAssignments/write at the target scope
# (Owner or Resource Policy Contributor). Contributor alone is not enough:
# module.image_integrity creates a policy assignment and has no enable toggle.
#
# azure_subscription_id / azure_tenant_id are intentionally not pinned in any
# suite: the azurerm provider resolves subscription_id through the Azure CLI
# authorizer at configure time, so a placeholder GUID fails every run, plan-only
# suites included ("the provided subscription ID ... is not known by Azure CLI").
#
# WARNING: `terraform test` auto-loads infra/terraform/terraform.auto.tfvars.json
# if a deploy or `verify --static` has rendered one. That silently supplies a real
# subscription and lets this billable suite run when you only meant to run the
# plan gate. Use -filter, or move the rendered tfvars aside first.
#
# Cost note: this provisions an Azure Firewall (Standard) which is billed by
# the hour. GPU pool contract coverage lives in the plan suites so this apply
# test can stay quota-safe in subscriptions without NCASv3 capacity.
###############################################################################

variables {
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
    "prod-registry-k8s-io-us-west-2.s3.dualstack.us-west-2.amazonaws.com",
  ]

  system_vm_size                       = "Standard_D2s_v5"
  cpu_vm_size                          = "Standard_D16s_v5"
  linux_jump_host_vm_size              = "Standard_D2s_v5"
  linux_jump_host_admin_username       = "azureoperator"
  linux_jump_host_admin_ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKbBsj5ktF3GEfYJ5G5O2CP658q5S7Lf4K3b4BVVij7F terraform-test"
  gpu_pool_configs                     = {}

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

  log_analytics_retention_days                  = 30
  terraform_managed_diagnostic_settings_enabled = true
  tags = {
    ManagedBy = "terraform"
    Owner     = "terraform-test"
  }
}

run "phase1_apply" {
  command = apply

  assert {
    condition     = output.resource_group_name == "rg-${var.project}-${var.environment}-${var.region_short}"
    error_message = "Resource group name does not match the CAF naming convention."
  }

  assert {
    condition     = length(output.firewall_private_ip) > 0
    error_message = "Firewall private IP must be populated for use as the AKS UDR next-hop."
  }

  assert {
    condition     = length(output.subnet_ids.aks_apiserver) > 0 && length(output.subnet_ids.aks_nodes) > 0 && length(output.subnet_ids.firewall) > 0 && length(output.subnet_ids.bastion) > 0
    error_message = "All required subnet IDs must be exported."
  }

  assert {
    condition     = length(output.subnet_ids.dns_resolver_in) > 0 && length(output.subnet_ids.dns_resolver_out) > 0
    error_message = "DNS Private Resolver subnet IDs must be exported."
  }

  assert {
    condition     = output.private_mode_validation.firewall.dns_proxy_enabled == true && length(output.private_mode_validation.firewall.dns_servers) == 0 && contains(output.vnet_dns_servers, output.firewall_private_ip)
    error_message = "Enterprise DNS must route VNet DNS to Azure Firewall DNS proxy and use default Azure DNS upstream for public plus VNet-linked Private Link zones."
  }

  assert {
    condition     = contains(output.private_mode_validation.firewall.azure_identity_fqdns, "login.microsoftonline.com") && contains(output.private_mode_validation.firewall.azure_identity_fqdns, "sts.windows.net") && contains(output.private_mode_validation.firewall.azure_identity_fqdns, "management.azure.com")
    error_message = "Firewall egress rules must include Microsoft identity and ARM endpoints for private Workload Identity storage validation."
  }

  assert {
    condition     = output.private_mode_validation.dns_resolver.inbound_endpoint_ip == "10.50.1.20" && output.private_mode_validation.dns_resolver.inbound_subnet_id == output.subnet_ids.dns_resolver_in && output.private_mode_validation.dns_resolver.outbound_subnet_id == output.subnet_ids.dns_resolver_out
    error_message = "DNS Private Resolver inbound/outbound endpoints must use their dedicated subnets."
  }

  assert {
    condition     = length(output.log_analytics_workspace_id) > 0
    error_message = "Log Analytics workspace must be created."
  }

  assert {
    condition     = length(output.log_analytics_workspace_customer_id) > 0
    error_message = "Log Analytics workspace customer ID must be exported for proof queries."
  }

  assert {
    condition     = output.private_mode_validation.observability.ampls_private_endpoint_subnet_id == output.subnet_ids.private_endpoints
    error_message = "AMPLS private endpoint must be placed on the dedicated private-endpoints subnet."
  }

  assert {
    condition     = length(output.storage_account_name) > 0
    error_message = "Storage account must be created."
  }

  assert {
    condition     = length(output.anyscale_operator_identity_principal_id) > 0
    error_message = "Anyscale operator user-assigned identity must be created."
  }

  assert {
    condition     = length(output.anyscale_operator_identity_client_id) > 0
    error_message = "Anyscale operator user-assigned identity client ID must be exported for Helm/operator setup."
  }

  assert {
    condition     = output.private_mode_validation.storage.blob_private_endpoint_subnet_id == output.subnet_ids.private_endpoints && output.private_mode_validation.storage.dfs_private_endpoint_subnet_id == output.subnet_ids.private_endpoints
    error_message = "Storage blob and dfs private endpoints must stay on the dedicated private-endpoints subnet."
  }

  assert {
    condition     = output.private_mode_validation.storage.public_network_access_enabled == false && output.private_mode_validation.storage.default_network_action == "Deny" && output.private_mode_validation.storage.shared_access_key_enabled == false && output.private_mode_validation.storage.default_to_oauth_authentication == true
    error_message = "Storage must remain private-only with shared keys disabled and OAuth enabled by default."
  }

  assert {
    condition     = output.private_mode_validation.identity.mode == "create" && output.private_mode_validation.identity.created_by_terraform == true && output.private_mode_validation.identity.managed_by_terraform == true && output.private_mode_validation.identity.role_definition_name == "Storage Blob Data Contributor" && output.private_mode_validation.identity.scope == output.private_mode_validation.storage.container_id && output.private_mode_validation.identity.principal_id == output.anyscale_operator_identity_principal_id && output.private_mode_validation.identity.principal_type == "ServicePrincipal" && length(output.private_mode_validation.identity.role_assignment_id) > 0
    error_message = "The Anyscale operator identity must keep Storage Blob Data Contributor on the default storage container as a service-principal role assignment."
  }

  assert {
    condition     = output.anyscale_operator_workload_identity.client_id == output.anyscale_operator_identity_client_id && output.anyscale_operator_workload_identity.identity_id == output.anyscale_operator_identity_id && output.anyscale_operator_workload_identity.federated_subject == output.private_mode_validation.workload_identity.subject && output.anyscale_operator_workload_identity.service_account_annotations["azure.workload.identity/client-id"] == output.anyscale_operator_identity_client_id && output.anyscale_operator_workload_identity.storage.container_id == output.private_mode_validation.storage.container_id && output.anyscale_operator_workload_identity.storage.rbac.scope == output.private_mode_validation.storage.container_id
    error_message = "Anyscale operator Workload Identity outputs must connect the Kubernetes service account metadata, UAMI, federated credential, and storage container RBAC scope."
  }
}
