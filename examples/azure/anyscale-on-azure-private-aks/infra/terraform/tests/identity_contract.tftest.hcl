###############################################################################
# Plan-only validation for the Anyscale operator managed identity contract.
#
# This file covers the three supported identity modes:
# - create: Terraform creates the UAMI and container-scoped storage RBAC.
# - existing-managed-rbac: Terraform uses an existing UAMI and creates RBAC.
# - existing-external-rbac: Terraform uses an existing UAMI and only exposes
#   the expected RBAC contract for external validation.
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

run "created_identity_managed_rbac_contract" {
  command = plan

  assert {
    condition     = output.anyscale_operator_identity_contract.mode == "create" && output.anyscale_operator_identity_contract.created_by_terraform == true && output.anyscale_operator_identity_contract.managed_by_terraform == true && output.anyscale_operator_identity_contract.role_definition_name == "Storage Blob Data Contributor"
    error_message = "Default Anyscale operator identity mode must create the UAMI and manage storage RBAC."
  }
}

run "existing_identity_managed_rbac_contract" {
  command = plan

  variables {
    anyscale_operator_identity = {
      mode         = "existing-managed-rbac"
      id           = "/subscriptions/24a4c592-bfaf-492f-beaf-f10b3b67f03f/resourceGroups/rg-existing-anyscale/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-existing-anyscale-operator"
      client_id    = "11111111-1111-1111-1111-111111111111"
      principal_id = "22222222-2222-2222-2222-222222222222"
      name         = "id-existing-anyscale-operator"
    }
  }

  assert {
    condition     = output.anyscale_operator_identity_contract.mode == "existing-managed-rbac" && output.anyscale_operator_identity_contract.created_by_terraform == false && output.anyscale_operator_identity_contract.managed_by_terraform == true && output.private_mode_validation.identity.mode == "existing-managed-rbac" && output.private_mode_validation.identity.created_by_terraform == false && output.private_mode_validation.identity.managed_by_terraform == true
    error_message = "existing-managed-rbac must use the supplied UAMI and still manage storage RBAC in Terraform."
  }

  assert {
    condition     = output.anyscale_operator_identity_id == "/subscriptions/24a4c592-bfaf-492f-beaf-f10b3b67f03f/resourceGroups/rg-existing-anyscale/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-existing-anyscale-operator" && output.anyscale_operator_identity_client_id == "11111111-1111-1111-1111-111111111111" && output.anyscale_operator_identity_principal_id == "22222222-2222-2222-2222-222222222222"
    error_message = "existing-managed-rbac must expose the supplied UAMI id, client id, and principal id."
  }

  assert {
    condition     = output.private_mode_validation.workload_identity.user_assigned_identity_id == output.anyscale_operator_identity_id && output.anyscale_operator_workload_identity.service_account_annotations["azure.workload.identity/client-id"] == "11111111-1111-1111-1111-111111111111"
    error_message = "existing-managed-rbac must point the FIC and service account annotation at the supplied UAMI."
  }

  assert {
    condition     = output.private_mode_validation.identity.role_definition_name == "Storage Blob Data Contributor" && output.private_mode_validation.identity.scope == output.private_mode_validation.storage.container_id && output.private_mode_validation.identity.principal_id == "22222222-2222-2222-2222-222222222222"
    error_message = "existing-managed-rbac must assign Storage Blob Data Contributor to the supplied UAMI principal at container scope."
  }
}

run "existing_identity_external_rbac_contract" {
  command = plan

  variables {
    anyscale_operator_identity = {
      mode                = "existing-external-rbac"
      id                  = "/subscriptions/24a4c592-bfaf-492f-beaf-f10b3b67f03f/resourceGroups/rg-existing-anyscale/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-existing-rbac-anyscale-operator"
      client_id           = "33333333-3333-3333-3333-333333333333"
      principal_id        = "44444444-4444-4444-4444-444444444444"
      name                = "id-existing-rbac-anyscale-operator"
      manage_storage_rbac = false
    }
  }

  assert {
    condition     = output.anyscale_operator_identity_contract.mode == "existing-external-rbac" && output.anyscale_operator_identity_contract.created_by_terraform == false && output.anyscale_operator_identity_contract.managed_by_terraform == false && output.private_mode_validation.identity.mode == "existing-external-rbac" && output.private_mode_validation.identity.created_by_terraform == false && output.private_mode_validation.identity.managed_by_terraform == false && output.private_mode_validation.identity.role_assignment_id == null
    error_message = "existing-external-rbac must use the supplied UAMI without creating a Terraform-managed role assignment."
  }

  assert {
    condition     = output.anyscale_operator_identity_id == "/subscriptions/24a4c592-bfaf-492f-beaf-f10b3b67f03f/resourceGroups/rg-existing-anyscale/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-existing-rbac-anyscale-operator" && output.anyscale_operator_identity_client_id == "33333333-3333-3333-3333-333333333333" && output.anyscale_operator_identity_principal_id == "44444444-4444-4444-4444-444444444444"
    error_message = "existing-external-rbac must expose the externally managed UAMI id, client id, and principal id."
  }

  assert {
    condition     = output.private_mode_validation.workload_identity.user_assigned_identity_id == output.anyscale_operator_identity_id && output.anyscale_operator_workload_identity.service_account_annotations["azure.workload.identity/client-id"] == "33333333-3333-3333-3333-333333333333"
    error_message = "existing-external-rbac must point the FIC and service account annotation at the supplied UAMI."
  }

  assert {
    condition     = output.private_mode_validation.identity.role_definition_name == "Storage Blob Data Contributor" && output.private_mode_validation.identity.scope == output.private_mode_validation.storage.container_id && output.private_mode_validation.identity.principal_id == "44444444-4444-4444-4444-444444444444"
    error_message = "existing-external-rbac must still publish the expected Storage Blob Data Contributor container-scope RBAC contract."
  }
}
