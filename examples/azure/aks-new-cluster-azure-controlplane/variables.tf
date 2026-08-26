variable "azure_subscription_id" {
  description = "(Required) Azure subscription ID"
  type        = string
}

variable "azure_location" {
  description = <<-EOT
    (Optional) Azure region for all resources. Must be one of the regions where
    `Anyscale.Platform/clouds` is supported: westcentralus, eastus, eastus2,
    westus2, westus3, southcentralus, westeurope, swedencentral, uksouth,
    australiaeast, southeastasia, northeurope. Older regions like `westus` are
    NOT supported by the Anyscale resource provider.

    Tip: run `./select-region.sh` to print the supported regions, scan your
    subscription's CPU/GPU quota in each, and pick a deployable region.
  EOT
  type        = string
  default     = "westus2"

  # Single source of truth for Anyscale-supported regions. Keep in sync with
  # the list in select-region.sh, the README, and terraform.tfvars.example.
  validation {
    condition = contains([
      "westcentralus", "eastus", "eastus2", "westus2", "westus3",
      "southcentralus", "westeurope", "swedencentral", "uksouth",
      "australiaeast", "southeastasia", "northeurope",
    ], var.azure_location)
    error_message = <<-EOT
      azure_location must be a region where Anyscale.Platform/clouds is supported:
      westcentralus, eastus, eastus2, westus2, westus3, southcentralus,
      westeurope, swedencentral, uksouth, australiaeast, southeastasia,
      northeurope. Run ./select-region.sh to scan quota and pick one.
    EOT
  }
}

variable "azure_tenant_id" {
  description = "Azure tenant ID. Can be found by running `az account show --query tenantId -o tsv`."
  type        = string
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
  default     = "anyscale-demo"
}

variable "azure_resource_group_name" {
  description = <<-EOT
    Resource group name. This variable has no default, so `terraform plan`/`apply`
    prompts for it interactively unless you supply it via terraform.tfvars, -var,
    or TF_VAR_azure_resource_group_name. Enter an empty value to fall back to
    "<aks_cluster_name>-rg".

    The empty-value fallback only applies when Terraform creates the group. When
    create_resource_group=false or create_aks_cluster=false this must name a
    resource group that already exists.
  EOT
  type        = string
  nullable    = false
}

###############################################################################
# Create-or-adopt toggles.
#
# The defaults reproduce this example's original behaviour: create a resource
# group, VNet, subnet, AKS cluster and the Anyscale node pools from scratch.
# See aks_existing.tf for how these resolve, and the README for the
# prerequisites an adopted cluster has to meet.
###############################################################################
variable "create_aks_cluster" {
  description = <<-EOT
    (Optional) Create the AKS cluster (and its VNet/subnet). Set to false to
    layer Anyscale onto a cluster you already run — supply
    `existing_aks_cluster_name` and `azure_resource_group_name` in that case.

    An adopted cluster must have the OIDC issuer and Microsoft Entra workload
    identity enabled, live in an Anyscale-supported region, and still issue a
    certificate-based kubeconfig (i.e. local accounts not disabled). Terraform
    checks all four before it changes anything.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "existing_aks_cluster_name" {
  description = <<-EOT
    (Optional) Name of an existing AKS cluster to adopt, in
    `azure_resource_group_name`. Required when create_aks_cluster=false and
    ignored otherwise.
  EOT
  type        = string
  nullable    = true
  default     = null
}

variable "create_resource_group" {
  description = <<-EOT
    (Optional) Create the resource group. Set to false to place the storage
    account, ACR and operator identity into a resource group that already
    exists. Forced to false when create_aks_cluster=false, since an adopted
    cluster brings its own resource group.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "existing_node_subnet_id" {
  description = <<-EOT
    (Optional) Full resource ID of an existing subnet to place AKS nodes in.
    When set, Terraform skips creating the VNet and subnet (and `vnet_cidr` /
    `nodes_subnet_cidr` are unused).

    When adopting a cluster (create_aks_cluster=false) this is normally left
    null — the subnet is read from the cluster's first agent pool. Set it
    explicitly if that pool is not in the subnet you want new pools to use.

    Note: `enable_nfs` requires the subnet to carry the `Microsoft.Storage`
    service endpoint. Terraform adds it to subnets it creates; on a subnet you
    supply, add it yourself.
  EOT
  type        = string
  nullable    = true
  default     = null
}

variable "create_node_pools" {
  description = <<-EOT
    (Optional) Create the Anyscale CPU/GPU node pools (on-demand and spot).
    Set to false when adopting a cluster whose pools already carry the
    `node.anyscale.com/capacity-type`, `node.anyscale.com/accelerator-type` and
    `nvidia.com/gpu` taints that the operator tolerates — see
    `anyscale_platform.extension_configuration_settings` to adjust those
    tolerations to a different scheme.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "node_pool_zones" {
  description = <<-EOT
    (Optional) Availability zones for the node pools Terraform creates, e.g.
    ["3"]. Leave null to let Azure place nodes without a zone constraint.

    Useful when only some zones in a region have capacity or quota for the VM
    sizes you asked for — `./scan-regional-quotas.sh` and `./select-gpu.sh`
    help identify that.
  EOT
  type        = list(string)
  nullable    = true
  default     = null
}

variable "anyscale_cloud_name" {
  description = <<-EOT
    Anyscale cloud name as it appears in the Anyscale console. This variable has
    no default, so `terraform plan`/`apply` prompts for it interactively unless
    you supply it via terraform.tfvars, -var, or TF_VAR_anyscale_cloud_name.
    Enter an empty value to fall back to "<aks_cluster_name>-cloud".
  EOT
  type        = string
  nullable    = false
}

variable "anyscale_operator_namespace" {
  description = "(Optional) Kubernetes namespace for the Anyscale operator."
  type        = string
  default     = "anyscale-operator"
}

variable "vnet_cidr" {
  description = "(Optional) CIDR block for the VNet."
  type        = string
  nullable    = false
  default     = "10.42.0.0/16"
}

variable "nodes_subnet_cidr" {
  description = "(Optional) CIDR block for the AKS nodes subnet."
  type        = string
  nullable    = false
  default     = "10.42.1.0/24"
}

variable "aks_cluster_subnet_cidr" {
  description = "(Optional) CIDR block for the AKS cluster service subnet. Cannot overlap with vnet_cidr or nodes_subnet_cidr."
  type        = string
  nullable    = false
  default     = "10.0.0.0/16"
}

variable "aks_cluster_dns_address" {
  description = "(Optional) DNS address for the AKS cluster. If not set, a default will be generated from aks_cluster_subnet_cidr."
  type        = string
  nullable    = true
  default     = null
}

variable "enable_blob_driver" {
  description = "(Optional) Enable the Azure Blob CSI driver on the AKS cluster. Required for mounting blob storage from pods."
  type        = bool
  nullable    = false
  default     = false
}

variable "enable_operator_infrastructure" {
  description = <<-EOT
    (Optional) Enable blob storage, managed identity, federated identity credential,
    role assignment, and output registration/helm commands for the Anyscale operator.

    KNOWN BROKEN: setting this to false fails at plan. anyscale.tf references
    azurerm_storage_account.sa[0], azurerm_storage_container.blob[0] and
    azurerm_user_assigned_identity.anyscale_operator[0] without guarding on this
    variable, so they resolve to an invalid index. It could not work as described
    in any case — the ARM deployment passes storageMode/identityMode = "existing",
    binding to the resources this flag would have skipped rather than creating its
    own. Leave it at true.

    If you want to install the operator yourself rather than via the AKS
    marketplace extension, the flag you want is `install_operator_extension`.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "register_anyscale_resource_provider" {
  description = <<-EOT
    (Optional) Register the Anyscale.Platform resource provider on the
    subscription via Terraform (azurerm_resource_provider_registration).
    Set to false if the RP is already registered or your org registers
    resource providers centrally and disallows registering them per-deploy.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "accept_anyscale_platform_agreement" {
  description = <<-EOT
    (Optional) Accept the Anyscale.Platform marketplace-style subscription
    agreement via Terraform (required once per subscription before
    Anyscale.Platform/clouds can be deployed). Set to false if the agreement
    has already been accepted, or if your org requires a human to review and
    accept it out-of-band rather than have Terraform accept it automatically.

    Terms of use:   https://catalogartifact.azureedge.net/publicartifacts/anyscale1750870039553.anyscale-operator-aks-73ba5252-dbbc-41fc-9f44-9a2171d23019/Artifacts/Documents/TermsOfUse.txt
    Privacy policy: https://www.anyscale.com/privacy-policy

    This mirrors the consent normally given by clicking "Create" on the
    Marketplace offer in the Azure portal: "By clicking Create, I (a) agree
    to the legal terms and privacy statement(s) associated with the
    Marketplace offering(s) listed above; (b) authorize Microsoft to bill my
    current payment method for the fees associated with the offering(s),
    with the same billing frequency as my Azure subscription; and (c) agree
    that Microsoft may share my contact, usage and transactional information
    with the provider(s) of the offering(s) for support, billing and other
    transactional activities. Microsoft does not provide rights for
    third-party offerings." See the Azure Marketplace Terms for additional
    details: https://azure.microsoft.com/support/legal/marketplace-terms/

    Review all of the above before leaving this at its default (true) —
    setting it to true means Terraform gives this consent on your behalf,
    non-interactively, whenever the agreement isn't already Active.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "install_operator_extension" {
  description = <<-EOT
    (Optional) Install the Anyscale.AKS.Operator AKS extension via Terraform
    (azurerm_kubernetes_cluster_extension). Set to false to skip this and install
    the Anyscale operator manually via `helm install` instead — useful if you want
    to control the Helm release yourself (custom values, staged rollout, pinned
    chart version). enable_operator_infrastructure still provisions the managed
    identity/federated credential/role assignment the operator needs either way.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "storage_account_name" {
  description = "(Optional) Name of the Azure Storage account to create for cloud storage. May be needed if generated name is already taken."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.storage_account_name == null || can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Storage account name must be between 3 and 24 characters long and contain only lowercase letters and numbers."
  }
}

variable "enable_nfs" {
  description = <<-EOT
    (Optional) Enable provisioning of an Azure NFS (Network File System) storage account.
    This NFS storage can be used for file-based persistent storage needs, mounting shared volumes to AKS nodes and pods.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "storage_account_name_nfs" {
  description = "(Optional) Name of the Azure NFS storage account to create. May be needed if generated name is already taken."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.storage_account_name_nfs == null || can(regex("^[a-z0-9]{3,24}$", var.storage_account_name_nfs))
    error_message = "NFS storage account name must be between 3 and 24 characters long and contain only lowercase letters and numbers."
  }
}

variable "system_vm_size" {
  description = "VM size for the default system node pool."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "cpu_vm_size" {
  description = "VM size for the CPU node pools (on-demand and spot)."
  type        = string
  default     = "Standard_D16s_v5"
}

variable "gpu_pool_configs" {
  description = <<-EOT
    (Optional) Configuration for GPU node pools. Empty by default — GPU pools are
    OPT-IN so a plain `terraform apply` never tries to create a GPU SKU (e.g. A100)
    that has no quota or capacity in your region. The CPU/system pools always deploy.

    The map key is a logical label (e.g. "T4", "A100"). The `name` field is used as
    the AKS node pool name and must be lowercase alphanumeric, max 8 chars (spot pools
    append "spot" for a 12-char AKS limit).

    Tip: run `./select-gpu.sh` to pick a GPU type from the Anyscale-supported catalog
    — or scan your chosen region for GPU SKUs that are both available AND have quota —
    and have it write this block into terraform.tfvars for you.

    Example (one on-demand + spot pool per entry):
      gpu_pool_configs = {
        T4   = { name = "gput4",   vm_size = "Standard_NC16as_T4_v3",     product_name = "NVIDIA-T4",   gpu_count = "1" }
        A100 = { name = "gpua100", vm_size = "Standard_NC24ads_A100_v4",  product_name = "NVIDIA-A100", gpu_count = "1" }
        H100 = { name = "h100x8",  vm_size = "Standard_ND96isr_H100_v5",  product_name = "NVIDIA-H100", gpu_count = "8" }
      }
  EOT
  type = map(object({
    name         = string
    vm_size      = string
    product_name = string
    gpu_count    = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.gpu_pool_configs : can(regex("^[a-z0-9]{1,8}$", v.name))
    ])
    error_message = "gpu_pool_configs name must be lowercase alphanumeric, max 8 characters (spot pools append 'spot' for a 12-char AKS limit)."
  }

  validation {
    condition = alltrue([
      for k, v in var.gpu_pool_configs : can(regex("^[1-9][0-9]*$", v.gpu_count))
    ])
    error_message = "gpu_pool_configs gpu_count must be a positive integer string (e.g. \"1\", \"8\")."
  }
}

variable "cors_rule" {
  description = <<-EOT
    (Optional)
    Object containing a rule of Cross-Origin Resource Sharing.
    The default allows GET, POST, PUT, HEAD, and DELETE
    access for the purpose of viewing logs and other functionality
    from within the Anyscale Web UI (*.anyscale.com).

    ex:
    ```
    cors_rule = {
      allowed_headers = ["*"]
      allowed_methods = ["GET", "POST", "PUT", "HEAD", "DELETE"]
      allowed_origins = ["https://*.anyscale.com"]
      expose_headers  = ["Accept-Ranges", "Content-Range", "Content-Length"]
    }
    ```
  EOT
  type = object({
    allowed_headers    = list(string)
    allowed_methods    = list(string)
    allowed_origins    = list(string)
    expose_headers     = list(string)
    max_age_in_seconds = optional(number, 0)
  })
  default = {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "POST", "PUT", "HEAD", "DELETE"]
    allowed_origins = ["https://*.anyscale.com"]
    expose_headers  = ["Accept-Ranges", "Content-Range", "Content-Length"]
  }
}

variable "storage_use_azuread" {
  description = "(Optional) Determines whether the provider uses AzureAD or the SharedKey from the Storage Account to connect to the Storage Blob & Queue APIs"
  type        = bool
  nullable    = false
  default     = false
}

variable "anyscale_operator_serviceaccount" {
  description = "(Optional) Kubernetes service account name the Anyscale operator runs as. The federated identity credential in aks.tf is bound to this service account name."
  type        = string
  default     = "anyscale-operator"
}

###############################################################################
# Azure Container Registry — for Anyscale workload images
###############################################################################
variable "enable_acr" {
  description = "(Optional) Create a customer-owned ACR for Anyscale workload images and grant the AKS kubelet identity AcrPull. Disable if you supply your own registry out-of-band."
  type        = bool
  nullable    = false
  default     = true
}

variable "acr_name" {
  description = "(Optional) Override the generated ACR name. Globally unique; 5-50 alphanumeric chars."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.acr_name == null || can(regex("^[a-zA-Z0-9]{5,50}$", var.acr_name))
    error_message = "ACR name must be 5-50 alphanumeric characters."
  }
}

variable "acr_sku" {
  description = "(Optional) ACR SKU. Premium is only required for Private Link / zone redundancy / customer-managed keys."
  type        = string
  nullable    = false
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.acr_sku)
    error_message = "acr_sku must be one of Basic, Standard, or Premium."
  }
}

variable "acr_zone_redundancy_enabled" {
  description = "(Optional) Enable zone redundancy on the ACR. Premium SKU only; ignored on Basic/Standard."
  type        = bool
  nullable    = false
  default     = false
}

###############################################################################
# Anyscale platform (Azure-managed control plane)
# These inputs drive the ARM `Anyscale.Platform/clouds` deployment and the
# `Anyscale.AKS.Operator` AKS extension. Defaults target
# https://console.azure.anyscale.com and the marketplace `anyscale-operator`
# plan — only override if you are testing against a non-default control plane.
###############################################################################
variable "anyscale_platform" {
  description = "(Optional) Tunables for the Anyscale.Platform/clouds ARM deployment and the Anyscale.AKS.Operator AKS extension."
  type = object({
    extension_resource_name          = optional(string, "anyscaleoperator")
    control_plane_url                = optional(string, "https://console.azure.anyscale.com")
    auth_audience                    = optional(string, "api://086bc555-6989-4362-ba30-fded273e432b/.default")
    agreement_api_version            = optional(string, "2026-07-01-preview")
    extension_configuration_settings = optional(map(string), {})
    plan_name                        = optional(string, "anyscale-operator")
    plan_publisher                   = optional(string, "anyscale1750870039553")
    plan_product                     = optional(string, "anyscale-operator-aks")
    release_train                    = optional(string, "stable")
    tags_by_resource                 = optional(map(map(string)), {})
  })
  default = {}
}

variable "anyscale_platform_contributors" {
  description = <<-EOT
    (Optional) Principals (users, groups, or service principals) to grant the
    "Anyscale Platform Contributor" role on the Anyscale cloud resource.

    IMPORTANT: Subscription Owner/Contributor on the underlying Azure resources
    does NOT carry over to the Anyscale resource provider. Creating Anyscale
    workspaces, jobs, or services requires this explicit Anyscale platform role
    on the cloud resource itself.

    Each entry needs the principal's object (principal) ID and its type
    (User | Group | ServicePrincipal). Example:

      anyscale_platform_contributors = [
        { principal_id = "00000000-0000-0000-0000-000000000000", principal_type = "User" },
        { principal_id = "11111111-1111-1111-1111-111111111111", principal_type = "Group" },
      ]
  EOT
  type = list(object({
    principal_id   = string
    principal_type = optional(string, "User")
  }))
  default = []

  validation {
    condition     = alltrue([for c in var.anyscale_platform_contributors : contains(["User", "Group", "ServicePrincipal"], c.principal_type)])
    error_message = "principal_type must be one of: User, Group, ServicePrincipal."
  }
}

variable "assign_current_user_platform_roles" {
  description = <<-EOT
    (Optional) When true (default), Terraform runs `az role assignment create`
    during apply to grant the signed-in `az` user both the
    "Anyscale Platform Contributor Role" and "Anyscale Platform Reader Role"
    on the Anyscale cloud resource.

    This lets whoever runs the deploy open the cloud in the Anyscale console and
    create workspaces/jobs/services without first looking up their own object
    ID. Set to false to skip (e.g. in CI where the service principal already has
    access, or when you assign roles exclusively via
    var.anyscale_platform_contributors). Requires the Azure CLI to be installed
    and logged in (the same `az login` the rest of the deploy relies on).
  EOT
  type        = bool
  default     = true
}

###############################################################################
# Envoy Gateway bootstrap
# Anyscale routes workspace and service traffic through an in-cluster Envoy
# Gateway. Defaults match the upstream Anyscale quickstart for AKS.
###############################################################################
variable "create_envoy_gateway" {
  description = <<-EOT
    (Optional) Install Envoy Gateway — the Helm release, the `EnvoyProxy` that
    pins the data plane to an external Azure Standard LoadBalancer, and the
    `GatewayClass`. Set to false to reuse an install the cluster already has,
    and point `envoy_gateway.gateway_class_name` at the existing class.

    The `Gateway` itself is always created: its HTTPS listeners reference TLS
    Secret names derived from this cloud's `cldrsrc_…` ID, so it cannot be
    shared between Anyscale clouds even on the same cluster.

    The GatewayClass you reuse must resolve to an `EnvoyProxy` whose
    `envoyService.type` is `LoadBalancer`. If it publishes the data plane any
    other way, the Gateway never gets a `status.addresses` entry and the apply
    fails at `terraform_data.wait_for_gateway_lb` — which dumps the
    GatewayClass and its EnvoyProxy on timeout so the cause is visible.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "create_operator_namespace" {
  description = <<-EOT
    (Optional) Create the `anyscale_operator_namespace` Kubernetes namespace.
    Set to false when adopting a cluster where that namespace already exists —
    for example one that has run an Anyscale operator before — since creating
    it again fails the apply.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "envoy_gateway" {
  description = "(Optional) Envoy Gateway install knobs. `namespace`, `release_name` and `chart_version` apply only when create_envoy_gateway=true; `gateway_class_name` names the class to create or, when reusing, the existing one to bind the Gateway to."
  type = object({
    namespace                        = optional(string, "envoy-gateway-system")
    release_name                     = optional(string, "eg")
    chart_version                    = optional(string, "v1.7.0")
    gateway_class_name               = optional(string, "eg")
    gateway_name                     = optional(string, "gateway")
    gateway_lb_wait_timeout_seconds  = optional(number, 600)
    gateway_lb_poll_interval_seconds = optional(number, 10)
  })
  default = {}
}

# NOTE: there is intentionally no kubeconfig_path variable. The
# kubernetes/helm/kubectl providers authenticate directly from the AKS
# cluster's admin cert attributes (see versions.tf), and the gateway-LB shell
# steps use an isolated ${path.module}/.kubeconfig written by
# terraform_data.aks_credentials. Nothing depends on ~/.kube/config, so the
# whole stack deploys in a single `terraform apply` regardless of what other
# kube contexts exist on the workstation.