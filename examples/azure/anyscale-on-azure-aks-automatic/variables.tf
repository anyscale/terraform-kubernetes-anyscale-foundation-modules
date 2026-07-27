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
    (Optional) Azure region for all Azure resources, including the AKS
    Automatic cluster. Must be in the INTERSECTION of two lists: regions where
    `Anyscale.Platform/clouds` is supported, and regions where AKS Automatic is
    generally available.

    That intersection is: eastus, eastus2, westus2, westus3, southcentralus,
    westeurope, swedencentral, uksouth, australiaeast, southeastasia,
    northeurope.

    NOTE FOR USERS COMING FROM `anyscale-on-azure-new-aks`: `westcentralus` is
    valid there but NOT here — Anyscale supports it, AKS Automatic does not.

    Tip: run `./select-region.sh` to print the supported regions, scan your
    subscription's CPU/GPU quota in each, and pick a deployable region.
  EOT
  type        = string
  default     = "westus2"

  # Single source of truth for the supported-region intersection. Keep in sync
  # with select-region.sh, the README, and terraform.tfvars.example.
  validation {
    condition = contains([
      "eastus", "eastus2", "westus2", "westus3",
      "southcentralus", "westeurope", "swedencentral", "uksouth",
      "australiaeast", "southeastasia", "northeurope",
    ], var.azure_location)
    error_message = <<-EOT
      azure_location must be a region supported by BOTH Anyscale.Platform/clouds
      and AKS Automatic: eastus, eastus2, westus2, westus3, southcentralus,
      westeurope, swedencentral, uksouth, australiaeast, southeastasia,
      northeurope. (westcentralus is Anyscale-supported but has no AKS
      Automatic, so it is not valid in this example.) Run ./select-region.sh to
      scan quota and pick one.
    EOT
  }
}

variable "anyscale_cloud_location" {
  description = <<-EOT
    (Optional) Region for the `Anyscale.Platform/clouds` resource, when it must
    differ from `azure_location`. Defaults to `azure_location` — a single-region
    deployment is the intended shape of this example.

    This override exists because the upstream awesome-aks demo splits the two
    (cluster in one region, Anyscale cloud in another) and that split is
    occasionally necessary when AKS Automatic is available somewhere the
    Anyscale RP is not, or vice versa. Note that the deterministic gateway
    hostname is derived from `azure_location` (the load balancer's region), not
    from this value.
  EOT
  type        = string
  nullable    = true
  default     = null
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
  default     = "anyscale-auto"
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
  description = "(Optional) Kubernetes namespace for the Anyscale operator. This namespace is automatically added to the deployment-safeguards exclusion list — see enable_deployment_safeguards_exclusion."
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
#
# AKS Automatic with a BYO VNet needs THREE subnets (the `new-aks` sibling
# needs one). Azure CNI overlay is Automatic's default, so pods do not consume
# addresses from any of them.
###############################################################################
variable "vnet_cidr" {
  description = "(Optional) CIDR block for the VNet."
  type        = string
  nullable    = false
  default     = "10.42.0.0/16"
}

variable "apiserver_subnet_cidr" {
  description = <<-EOT
    (Optional) CIDR for the API Server VNet Integration subnet. This subnet is
    delegated to `Microsoft.ContainerService/managedClusters` and must be at
    least a /28 — Azure rejects anything smaller. Nothing else may share it.
  EOT
  type        = string
  nullable    = false
  default     = "10.42.0.0/28"
}

variable "nodes_subnet_cidr" {
  description = "(Optional) CIDR for the user node subnet. Karpenter provisions every workload node here."
  type        = string
  nullable    = false
  default     = "10.42.1.0/24"
}

variable "system_nodes_subnet_cidr" {
  description = "(Optional) CIDR for the AKS-managed system node pool subnet (CoreDNS, metrics-server, the Karpenter controller, the app-routing Istio controller)."
  type        = string
  nullable    = false
  default     = "10.42.2.0/24"
}

variable "api_server_authorized_ip_ranges" {
  description = <<-EOT
    (Optional) CIDRs allowed to reach the AKS API server. Empty (the default)
    means the API server accepts connections from anywhere — convenient for a
    first deploy, and the first thing to change for a real one. Add at minimum
    the egress IP of wherever Terraform and the gateway bootstrap run.
  EOT
  type        = set(string)
  nullable    = false
  default     = []
}

# NOTE: there is deliberately no `private_cluster_enabled` here. The in-cluster
# bootstrap talks to the API server over the data plane, so a private API server
# would leave the deployment half-built. See the long comment in aks.tf, and use
# `anyscale-on-azure-private-aks` for private deployments.

variable "internal_gateway" {
  description = <<-EOT
    (Optional) When true, the Anyscale gateway is exposed on an INTERNAL Azure
    Standard LB (private IP in the node subnet) instead of a public LB. The
    Anyscale data plane is then reachable only from the VNet.

    Note: internal LBs have no public DNS label, so the deterministic-hostname
    shortcut is unavailable — Terraform falls back to polling the Gateway for
    its address, and the address registered with the Anyscale control plane is
    a private IP.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "enable_default_nginx_ingress_controller" {
  description = <<-EOT
    (Optional) Keep the app-routing default nginx ingress controller. False by
    default: this example routes all Anyscale traffic through the Istio
    `Gateway`, so the nginx controller would only add a second public load
    balancer. Set true if you also want app routing's nginx `Ingress` support
    for your own non-Anyscale workloads.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

###############################################################################
# Cluster access (Entra RBAC)
#
# AKS Automatic disables local accounts. A kubeconfig alone authorizes nothing
# — every caller needs an AKS RBAC role assignment.
###############################################################################
variable "assign_current_principal_cluster_access" {
  description = <<-EOT
    (Optional) Grant the principal running Terraform "Azure Kubernetes Service
    RBAC Cluster Admin" and "Azure Kubernetes Service Cluster User Role" on the
    cluster. Required for the in-cluster bootstrap in gateway.tf — without it
    the first `kubectl apply` fails with a 403. Set false only if the deploying
    principal already holds equivalent access.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "aks_cluster_admin_principal_ids" {
  description = "(Optional) Additional Entra object IDs (users, groups, service principals) to grant \"Azure Kubernetes Service RBAC Cluster Admin\" on the cluster."
  type        = set(string)
  nullable    = false
  default     = []
}

###############################################################################
# GPU capacity (Karpenter NodePools)
#
# There is no `system_vm_size` / `cpu_vm_size` here, and no `gpu_driver_mode`,
# `gpu_operator_chart_version`, `enable_node_auto_provisioning`, or
# `nap_gpu_sku_name`. AKS Automatic manages the system pool, provisions CPU
# capacity from its built-in Karpenter NodePool, and installs GPU drivers
# itself. Only GPU NodePools need declaring.
###############################################################################
variable "gpu_nodepool_configs" {
  description = <<-EOT
    (Optional) Karpenter GPU NodePools to create. Empty by default — GPU is
    OPT-IN so a plain `terraform apply` never asks for a GPU SKU (e.g. A100)
    that has no quota or capacity in your region. CPU capacity always works via
    Automatic's built-in default NodePool.

    Each entry renders an `AKSNodeClass` (with the AKS-managed GPU driver tag)
    plus an on-demand `NodePool`, and a spot `NodePool` when `enable_spot` is
    true. Nodes carry the same Anyscale taints as the static GPU pools in the
    `anyscale-on-azure-new-aks` sibling, so operator tolerations are identical.

    The map key is a logical label (e.g. "T4", "A100"). `name` is used for the
    AKSNodeClass and NodePool object names; the spot pool appends "spot".

    Tip: run `./select-gpu.sh` to pick a GPU type from the Anyscale-supported
    catalog — or scan your chosen region for GPU SKUs that are both available
    AND have quota — and have it write this block into terraform.tfvars.

    Example:
      gpu_nodepool_configs = {
        T4   = { name = "gput4",   vm_size = "Standard_NC16as_T4_v3",    product_name = "NVIDIA-T4",   gpu_count = "1" }
        A100 = { name = "gpua100", vm_size = "Standard_NC24ads_A100_v4", product_name = "NVIDIA-A100", gpu_count = "1", max_gpus = 8 }
      }
  EOT
  type = map(object({
    name         = string
    vm_size      = string
    product_name = string
    gpu_count    = string
    # Also create a spot NodePool for this SKU.
    enable_spot = optional(bool, true)
    # Hard ceiling on GPUs this NodePool may provision. Karpenter scales to
    # zero when idle, so this bounds a runaway workload, not idle cost.
    max_gpus        = optional(number, 16)
    image_family    = optional(string, "Ubuntu2204")
    os_disk_size_gb = optional(number, 128)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.gpu_nodepool_configs : can(regex("^[a-z0-9]([a-z0-9-]{0,10}[a-z0-9])?$", v.name))
    ])
    error_message = "gpu_nodepool_configs name must be a lowercase RFC-1123 label, max 12 characters (the spot NodePool appends 'spot')."
  }

  validation {
    condition = alltrue([
      for k, v in var.gpu_nodepool_configs : can(regex("^[1-9][0-9]*$", v.gpu_count))
    ])
    error_message = "gpu_nodepool_configs gpu_count must be a positive integer string (e.g. \"1\", \"8\")."
  }
}

###############################################################################
# Deployment safeguards (Azure Policy)
#
# AKS Automatic turns these on in Enforcement level. The Anyscale operator and
# the Ray pods it creates do not satisfy them — see the long comment on the
# patch in aks.tf.
###############################################################################
variable "enable_deployment_safeguards_exclusion" {
  description = <<-EOT
    (Optional) Patch the cluster's deployment safeguards to exclude the
    Anyscale namespaces from Azure Policy enforcement.

    LEAVE THIS ON. AKS Automatic runs deployment safeguards in Enforcement, and
    the Anyscale operator's pods (elevated init container, no resource limits
    on control-plane-shaped Ray pods) are rejected at admission without the
    exclusion. The failure looks like an operator deployment stuck at 0/1, not
    like a policy error.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "deployment_safeguards_excluded_namespaces" {
  description = <<-EOT
    (Optional) Extra namespaces to exclude from deployment safeguards, on top of
    `anyscale_operator_namespace` (which is always included). Widen this if a
    real workload run turns up pods being rejected in another namespace —
    preferable to dropping the safeguards level cluster-wide.
  EOT
  type        = list(string)
  nullable    = false
  default     = []
}

variable "deployment_safeguards_level" {
  description = "(Optional) Deployment safeguards level for namespaces that are NOT excluded. \"Enforcement\" (the AKS Automatic default) or \"Warning\"."
  type        = string
  nullable    = false
  default     = "Enforcement"

  validation {
    condition     = contains(["Enforcement", "Warning"], var.deployment_safeguards_level)
    error_message = "deployment_safeguards_level must be \"Enforcement\" or \"Warning\"."
  }
}

variable "deployment_safeguards_api_version" {
  description = <<-EOT
    (Optional) ARM API version for the `Microsoft.ContainerService/deploymentSafeguards`
    extension resource. Defaults to the GA version. Check what your subscription
    offers with:
      az provider show -n Microsoft.ContainerService \
        --query "resourceTypes[?resourceType=='deploymentSafeguards'].apiVersions"
  EOT
  type        = string
  nullable    = false
  default     = "2025-07-01"
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
# Observability
###############################################################################
variable "enable_monitoring" {
  description = <<-EOT
    (Optional) Deploy the Azure-managed observability stack: Azure Monitor
    workspace + managed Prometheus (data-collection rules, recording rule
    groups), Log Analytics + Container Insights, and the omsagent addon.

    On this stack the cluster-side half arrives as an azapi PATCH rather than
    typed `oms_agent` / `monitor_metrics` blocks — `azurerm_kubernetes_automatic_cluster`
    exposes neither. Same end state; see aks.tf.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "enable_otlp_app_insights" {
  description = <<-EOT
    (Optional, PREVIEW) Create an Application Insights component with OTLP
    logs/metrics/traces ingestion endpoints (Microsoft.Insights/components
    preview API) for Ray application telemetry, and turn on the cluster's
    appMonitoring profile. Requires enable_monitoring.
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
# Gateway
#
# No chart version, no release name, no GatewayClass name: AKS Automatic
# installs and manages the app-routing Istio controller and registers the
# `approuting-istio` GatewayClass. Only the Gateway object is ours.
###############################################################################
variable "gateway" {
  description = "(Optional) Anyscale Gateway knobs. The class name is fixed at `approuting-istio` by AKS Automatic and is therefore not configurable here."
  type = object({
    name = optional(string, "gateway")
    # How long the bootstrap waits for the Gateway API CRDs and the
    # `approuting-istio` GatewayClass to appear after the ingress-profile patch
    # reconciles. 10+ minutes is normal; the default leaves headroom.
    api_ready_timeout_seconds = optional(number, 1200)
    lb_wait_timeout_seconds   = optional(number, 600)
    lb_poll_interval_seconds  = optional(number, 10)
  })
  default = {}
}
