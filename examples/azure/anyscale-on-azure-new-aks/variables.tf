variable "azure_subscription_id" {
  description = "(Required) Azure subscription ID"
  type        = string
}

variable "azure_tenant_id" {
  description = "(Optional) Azure tenant ID (`az account show --query tenantId -o tsv`). Accepted for tfvars compatibility with the helper scripts; not currently referenced by resources."
  type        = string
  nullable    = true
  default     = null
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

variable "tags" {
  description = "(Optional) Tags applied to all taggable resources."
  type        = map(string)
  default = {
    Environment = "dev"
  }
}

variable "aks_cluster_name" {
  description = "(Optional) Name of the AKS cluster (and related resources)."
  type        = string
  default     = "anyscale-demo"
}

variable "azure_resource_group_name" {
  description = "(Optional) Resource group name. Defaults to \"<aks_cluster_name>-rg\"."
  type        = string
  nullable    = true
  default     = null
}

variable "anyscale_cloud_name" {
  description = "(Optional) Anyscale cloud name as it appears in the Anyscale console. Defaults to \"<aks_cluster_name>-cloud\"."
  type        = string
  nullable    = true
  default     = null
}

variable "anyscale_operator_namespace" {
  description = "(Optional) Kubernetes namespace for the Anyscale operator."
  type        = string
  default     = "anyscale-operator"
}

variable "anyscale_operator_serviceaccount" {
  description = "(Optional) Kubernetes service account name the Anyscale operator runs as. The federated identity credential in identity.tf is bound to this service account name."
  type        = string
  default     = "anyscale-operator"
}

###############################################################################
# Networking
###############################################################################
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

variable "aks_service_cidr" {
  description = "(Optional) CIDR block for Kubernetes Services. Cannot overlap with vnet_cidr."
  type        = string
  nullable    = false
  default     = "10.0.0.0/16"
}

variable "aks_pod_cidr" {
  description = "(Optional) CIDR block for pods. Azure CNI overlay assigns pod IPs from this range instead of the node subnet, so BYO-subnet sizing only has to cover nodes. Cannot overlap with vnet_cidr or aks_service_cidr."
  type        = string
  nullable    = false
  default     = "10.244.0.0/16"
}

variable "aks_cluster_dns_address" {
  description = "(Optional) DNS service address for the AKS cluster. If not set, a default is generated from aks_service_cidr."
  type        = string
  nullable    = true
  default     = null
}

variable "internal_gateway" {
  description = <<-EOT
    (Optional) When true, the Envoy Gateway is exposed on an INTERNAL Azure
    Standard LB (private IP in the node subnet) instead of a public LB.
    The Anyscale data plane is then reachable only from the VNet.

    Note: internal LBs have no public DNS label, so the deterministic-hostname
    shortcut is unavailable — Terraform falls back to polling the Gateway for
    its address (the reference-example behavior), and the address registered
    with the Anyscale control plane is a private IP.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

###############################################################################
# Node pools
###############################################################################
variable "system_vm_size" {
  description = <<-EOT
    VM size for the default system node pool (autoscaled 1-3). This pool hosts
    the Anyscale operator, Envoy Gateway, CoreDNS, and — when enable_monitoring
    is true — the omsagent and managed-Prometheus (ama-metrics) agents, so it
    needs some headroom. Standard_D4s_v5 (4 vCPU / 16 GB) is the safe default.
  EOT
  type        = string
  default     = "Standard_D4s_v5"
}

variable "cpu_vm_size" {
  description = <<-EOT
    VM size for the CPU node pools (on-demand and spot). These pools scale to
    zero, so this only sets the granularity of a scheduled Ray node, not idle
    cost. Standard_D8s_v5 (8 vCPU / 32 GB) is a moderate default; raise it for
    larger workloads.
  EOT
  type        = string
  default     = "Standard_D8s_v5"
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

variable "gpu_driver_mode" {
  description = <<-EOT
    (Optional) How NVIDIA drivers and the device plugin get onto GPU nodes.

      "operator" (default) — AKS skips driver install (gpu_driver = "None") and
        Terraform installs the NVIDIA GPU operator Helm chart, which manages the
        full driver + container-toolkit + device-plugin stack. GA everywhere.

      "managed" — AKS installs the driver stack (gpu_driver = "Install") and no
        GPU-operator chart is deployed. For the fully managed experience
        (drivers AND device plugin) register the `ManagedGPUExperiencePreview`
        feature first:
          az feature register --namespace Microsoft.ContainerService --name ManagedGPUExperiencePreview
        Without the preview feature, plain "Install" provides drivers only and
        you must deploy a device plugin yourself.
  EOT
  type        = string
  nullable    = false
  default     = "operator"

  validation {
    condition     = contains(["operator", "managed"], var.gpu_driver_mode)
    error_message = "gpu_driver_mode must be \"operator\" or \"managed\"."
  }
}

variable "gpu_operator_chart_version" {
  description = "(Optional) NVIDIA GPU operator Helm chart version (used when gpu_driver_mode = \"operator\")."
  type        = string
  default     = "v25.3.1"
}

variable "enable_node_auto_provisioning" {
  description = <<-EOT
    (Optional, PREVIEW) Enable AKS Node Auto Provisioning (managed Karpenter).
    Applied as an azapi patch on top of the GA cluster resource, plus a
    Karpenter NodePool for GPU workloads mirroring the awesome-aks demo.
    Requires the `NodeAutoProvisioningPreview` AKS feature flag on the
    subscription. Static pools from gpu_pool_configs continue to work alongside;
    NAP provisions additional capacity on demand.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "nap_gpu_sku_name" {
  description = "(Optional) VM SKU Karpenter may provision for GPU workloads when enable_node_auto_provisioning = true (karpenter.azure.com/sku-name requirement)."
  type        = string
  default     = "Standard_NC16as_T4_v3"
}

###############################################################################
# Storage
###############################################################################
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

variable "enable_blob_driver" {
  description = "(Optional) Enable the Azure Blob CSI driver on the AKS cluster. Required for mounting blob storage from pods."
  type        = bool
  nullable    = false
  default     = false
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

variable "cors_rule" {
  description = <<-EOT
    (Optional)
    Cross-Origin Resource Sharing rule on the blob service, used by the
    Anyscale console to render logs and artifacts in the browser. The default
    allows the Azure-hosted console (console.azure.anyscale.com) plus the
    *.anyscale.com console domains.
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
    allowed_origins = ["https://console.azure.anyscale.com", "https://*.anyscale.com"]
    expose_headers  = ["Accept-Ranges", "Content-Range", "Content-Length"]
  }
}

variable "storage_use_azuread" {
  description = "(Optional) Determines whether the provider uses AzureAD or the SharedKey from the Storage Account to connect to the Storage Blob & Queue APIs"
  type        = bool
  nullable    = false
  default     = false
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
# Observability (ported from the awesome-aks demo)
###############################################################################
variable "enable_monitoring" {
  description = <<-EOT
    (Optional) Deploy the Azure-managed observability stack: Azure Monitor
    workspace + managed Prometheus (data-collection rules, recording rule
    groups), Log Analytics + Container Insights, and the AKS omsagent addon.
    All GA. Disable for the absolute-minimum evaluation footprint.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "enable_otlp_app_insights" {
  description = <<-EOT
    (Optional, PREVIEW) Create an Application Insights component with OTLP
    logs/metrics/traces ingestion endpoints (Microsoft.Insights/components
    preview API) for Ray application telemetry. Requires enable_monitoring.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "log_analytics_retention_days" {
  description = "(Optional) Log Analytics workspace retention in days."
  type        = number
  nullable    = false
  default     = 30
}

###############################################################################
# Anyscale platform (Azure-managed control plane)
###############################################################################
variable "anyscale_platform" {
  description = "(Optional) Tunables for the Anyscale.Platform/clouds resources and the Anyscale.AKS.Operator AKS extension."
  type = object({
    extension_resource_name          = optional(string, "anyscaleoperator")
    control_plane_url                = optional(string, "https://console.azure.anyscale.com")
    auth_audience                    = optional(string, "api://086bc555-6989-4362-ba30-fded273e432b/.default")
    extension_configuration_settings = optional(map(string), {})
    plan_name                        = optional(string, "anyscale-operator")
    plan_publisher                   = optional(string, "anyscale1750870039553")
    plan_product                     = optional(string, "anyscale-operator-aks")
    release_train                    = optional(string, "stable")
    clouds_api_version               = optional(string, "2026-02-01-preview")
    agreements_api_version           = optional(string, "2026-07-01-preview")
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
variable "envoy_gateway" {
  description = "(Optional) Envoy Gateway install knobs."
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
