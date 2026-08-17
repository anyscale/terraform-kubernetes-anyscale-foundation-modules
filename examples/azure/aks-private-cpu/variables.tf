# ---------------------------------------------------------------------------------------------------------------------
# REQUIRED VARIABLES
# ---------------------------------------------------------------------------------------------------------------------

variable "azure_tenant_id" {
  description = <<-EOT
    (Required) Azure tenant ID.

    Find it with `az account show --query tenantId -o tsv`. Used in the Anyscale
    cloud registration command emitted by outputs.tf.
  EOT
  type        = string
}

variable "azure_subscription_id" {
  description = <<-EOT
    (Required) Azure subscription ID.

    Find it with `az account show --query id -o tsv`. No default - a
    subscription ID is deployment-specific, and defaulting to one means a
    mis-set tfvars silently deploys into someone else's.
  EOT
  type        = string
}

# ---------------------------------------------------------------------------------------------------------------------
# OPTIONAL VARIABLES
# ---------------------------------------------------------------------------------------------------------------------

variable "azure_location" {
  description = <<-EOT
    (Optional) Azure region for all resources.

    Note that the NSG service-tag rules in main.tf derive the regional tag
    (e.g. `AzureCloud.WestUS2`) by stripping spaces from this value. That tag
    covers only this region, which is the main thing to get right when the
    cluster and its dependencies are not co-located - see
    `additional_egress_rules`.

    The Anyscale PLS alias does NOT have to match this region; private endpoints
    can reach a Private Link service in any public region.
  EOT
  type        = string
  default     = "West US 2"
}

variable "aks_cluster_name" {
  description = "(Optional) Name of the AKS cluster, and the base name for related resources."
  type        = string
  default     = "pei-private"
}

variable "tags" {
  description = "(Optional) Tags applied to all taggable resources."
  type        = map(string)
  default = {
    Test        = "true"
    Environment = "dev"
    Repo        = "terraform-kubernetes-anyscale-foundation-modules"
    Example     = "azure/aks-private-cpu"
  }
}

variable "kubernetes_version" {
  description = "(Optional) Kubernetes version for the AKS cluster. Null uses the region's default."
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
  description = <<-EOT
    (Optional) Name of the Kubernetes service account the Anyscale operator runs as.

    This must match the subject of the federated identity credential in aks.tf -
    changing it here without reinstalling the operator breaks workload identity.
  EOT
  type        = string
  default     = "anyscale-operator"
}

# ---------------------------------------------------------------------------------------------------------------------
# NETWORKING
# ---------------------------------------------------------------------------------------------------------------------

variable "vnet_cidr" {
  description = "(Optional) CIDR block for the VNet."
  type        = string
  nullable    = false
  default     = "10.42.0.0/16"
}

variable "nodes_subnet_cidr" {
  description = <<-EOT
    (Optional) CIDR block for the AKS nodes subnet.

    This example uses Azure CNI **overlay**, so pods do NOT take IPs from this
    subnet - each node consumes exactly one. A /22 therefore holds ~1000 nodes.

    If you switch to node-subnet CNI (network_plugin_mode = null in aks.tf),
    every pod takes an IP from here and AKS pre-allocates `max_pods` per node,
    so a /22 would cap you at roughly 30 nodes instead.
  EOT
  type        = string
  nullable    = false
  default     = "10.42.0.0/22"
}

variable "private_endpoints_subnet_cidr" {
  description = <<-EOT
    (Optional) CIDR block for the private endpoints subnet.

    Private endpoints for the storage account, ACR and (optionally) the Anyscale
    control plane land here. Kept separate from the nodes subnet so the NSG
    rules on the nodes do not apply to endpoint NICs.
  EOT
  type        = string
  nullable    = false
  default     = "10.42.8.0/24"
}

variable "aks_pod_cidr" {
  description = <<-EOT
    (Optional) Pod CIDR for Azure CNI overlay.

    Must not overlap vnet_cidr, aks_service_cidr, or any network you peer with.
    Pod IPs live only inside the cluster and are NAT'd to the node IP on egress.
  EOT
  type        = string
  nullable    = false
  default     = "10.244.0.0/16"
}

variable "aks_service_cidr" {
  description = "(Optional) Kubernetes service CIDR. Must not overlap vnet_cidr or aks_pod_cidr."
  type        = string
  nullable    = false
  default     = "10.0.0.0/16"
}

variable "aks_cluster_dns_address" {
  description = "(Optional) kube-dns service IP. Null derives the .10 address from aks_service_cidr."
  type        = string
  nullable    = true
  default     = null
}

variable "allow_public_ingress" {
  description = <<-EOT
    (Optional) Allow inbound traffic from the internet to the Kubernetes nodePort range.

    Required when the ingress controller uses a PUBLIC load balancer, which is
    this example's default. An Azure Standard Load Balancer with a public
    frontend does not SNAT the client, so the node sees the original client's
    public IP - traffic that matches the `Internet` service tag and is otherwise
    dropped by the platform's DenyAllInBound rule.

    AKS manages NSG rules for LoadBalancer services on its own NSG in the node
    resource group, not on the user-assigned NSG this example attaches to the
    subnet. Both are evaluated, so this rule is needed independently.

    Set to false if you switch the ingress controller to an internal load
    balancer (`service.beta.kubernetes.io/azure-load-balancer-internal: "true"`).
    Client traffic then originates inside the VNet and the AllowVnetInbound rule
    already covers it.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "public_ingress_ports" {
  description = <<-EOT
    (Optional) Destination ports opened inbound by `allow_public_ingress`.

    These are the ingress controller's SERVICE ports, not its nodePorts.

    That is counterintuitive, so it is worth being explicit. AKS creates the
    load balancing rules with `backendPort == frontendPort` (floating IP / DSR),
    meaning the load balancer forwards to 80 and 443 on the node and the node's
    dataplane does the port mapping. The nodePorts appear only in the HEALTH
    PROBE configuration.

    Opening the nodePort range instead produces a convincing failure: the probes
    succeed, the load balancer reports healthy, the Service gets an EXTERNAL-IP,
    DNS resolves - and every real request is dropped. Ports 80/443 are what
    actually carry traffic.

    If you front the cluster with something using different ports, list them
    here. The nodePort range is only needed if floating IP is disabled, which is
    not the AKS default.
  EOT
  type        = list(string)
  nullable    = false
  default     = ["80", "443"]
}

variable "public_ingress_source_prefixes" {
  description = <<-EOT
    (Optional) Sources permitted inbound by `allow_public_ingress`.

    Defaults to the `Internet` service tag - anyone. Narrow it to a CIDR list to
    restrict who can reach the ingress, e.g. an office egress IP as a `/32`.

    A public Standard Load Balancer does not SNAT the client, so the node sees
    the original caller and a `/32` here matches it rather than a load balancer
    address.

    CIDRs and service tags cannot be mixed: several values render as
    `source_address_prefixes`, which rejects tags; a single value renders as
    `source_address_prefix`, which accepts either.

    ex:
    ```
    public_ingress_source_prefixes = ["203.0.113.45/32"]
    ```
  EOT
  type        = list(string)
  nullable    = false
  default     = ["Internet"]

  validation {
    condition     = length(var.public_ingress_source_prefixes) > 0
    error_message = "public_ingress_source_prefixes must have at least one entry - set allow_public_ingress = false to close the rule instead."
  }
}

variable "anyscale_storage_account" {
  description = <<-EOT
    (Optional) The Anyscale-owned storage account that serves images and dependencies.

    Declaring it does two things:

    1. When `block_public_internet_egress` is true, an explicit NSG allow rule is
       created for `Storage.<region>`. If the account is in the same region as
       this cluster the built-in `AzureCloud.<region>` rule already covers it and
       the extra rule is redundant - but it states the dependency explicitly, and
       it keeps working if you later narrow that broad AzureCloud allow.

    2. When `enable_anyscale_storage_private_endpoint` is also true, a private
       endpoint is created against the account so the traffic never leaves the
       VNet at all. See that variable for the caveats.

    Leave null to rely on the built-in AzureCloud allow.

    Note the granularity limit: the NSG rule uses a service tag, which permits
    reaching **any** storage account in that region, not just this one. Only the
    private endpoint makes access specific to this account.

    ex:
    ```
    anyscale_storage_account = {
      subscription_id     = "..."
      resource_group_name = "..."
      name                = "anyscaleimages"
      region              = "West US 2"
    }
    ```
  EOT
  type = object({
    subscription_id     = string
    resource_group_name = string
    name                = string
    # Defaults to var.azure_location when omitted.
    region = optional(string)
  })
  nullable = true
  default  = null
}

variable "enable_anyscale_storage_private_endpoint" {
  description = <<-EOT
    (Optional) Create a private endpoint to the Anyscale storage account.

    Requires `anyscale_storage_account`. This is the only way to make access to
    that account genuinely private - a service tag rule cannot narrow past
    "any storage account in the region".

    Two caveats:

    * The connection is **cross-subscription and manual**. Whoever owns the
      account has to approve the request; the endpoint sits in `Pending` until
      they do. If it is an Anyscale-owned account, that is a conversation with
      them, the same as the control plane PLS.
    * The A record lands in the `privatelink.blob.core.windows.net` zone this
      example already creates for its own storage account. That zone is
      authoritative for the whole domain inside the VNet, so once it exists,
      **any** `*.blob.core.windows.net` name without a record in it fails to
      resolve from inside the VNet rather than falling back to public DNS.
      Enabling this is what makes that bite: if the cluster needs to reach other
      storage accounts, they need records too.

    Defaults to false - start with the NSG rule and only take this on once you
    have the approval path sorted.
  EOT
  type        = bool
  nullable    = false
  default     = false

  validation {
    condition     = !var.enable_anyscale_storage_private_endpoint || var.anyscale_storage_account != null
    error_message = "anyscale_storage_account must be set when enable_anyscale_storage_private_endpoint is true."
  }
}

variable "additional_egress_service_tags" {
  description = <<-EOT
    (Optional) Extra Azure service tags permitted outbound, on top of the built-in set.

    The built-in set is in `main.tf` (`local.egress_service_tags`):
    `AzureActiveDirectory`, `AzureResourceManager`, `MicrosoftContainerRegistry`,
    `AzureFrontDoor.FirstParty`, plus `AzureCloud.<region>` and
    `Storage.<region>`.

    Add entries here for dependencies outside that set - most commonly
    `Storage.<other-region>` when Anyscale's storage account is not co-located
    with this cluster.

    One NSG rule is generated per tag, with priorities assigned from 300 upward.

    ex:
    ```
    additional_egress_service_tags = ["Storage.EastUS", "AzureMonitor"]
    ```
  EOT
  type        = list(string)
  nullable    = false
  default     = []
}

variable "additional_egress_rules" {
  description = <<-EOT
    (Optional) Extra outbound NSG allow rules, evaluated above the Deny.

    The built-in allow rule uses `AzureCloud.<region>`, which is **region
    scoped** - it covers Azure endpoints in `azure_location` and nowhere else.
    Anything the cluster must reach in a different region needs an entry here,
    or it is dropped once `block_public_internet_egress` is true.

    The known case is **Anyscale's own storage account**, which serves images
    and dependencies. This configuration has no knowledge of which account or
    region that is - ask Anyscale, then add the matching tag. If it is in West
    US 2 the built-in rule already covers it and nothing is needed here.

    Prefer `additional_egress_service_tags` when the destination is a service
    tag - it feeds the generated rules and cannot collide with them. Use this
    variable only for what a tag cannot express: a specific CIDR, a non-443
    port, a protocol restriction.

    Priorities must be in 1000-3899, clear of the generated service-tag rules
    (300-999), the Anyscale storage rule (3900) and the Deny (4000). Azure
    rejects duplicate priorities within a direction with SecurityRuleConflict.

    ex:
    ```
    additional_egress_rules = {
      AnyscaleStorage = {
        priority    = 310
        destination = "Storage.EastUS"
        protocol    = "Tcp"
        ports       = "443"
      }
    }
    ```

    Note the same caveat as the built-in rule: `Storage.EastUS` permits reaching
    *any* storage account in that region, not just Anyscale's. Service tags
    cannot express a single account - that needs FQDN filtering.
  EOT
  type = map(object({
    priority    = number
    destination = string
    protocol    = optional(string, "*")
    ports       = optional(string, "*")
  }))
  nullable = false
  default  = {}

  validation {
    condition = alltrue([
      for k, v in var.additional_egress_rules : v.priority >= 1000 && v.priority <= 3899
    ])
    error_message = "additional_egress_rules priorities must be between 1000 and 3899 - clear of the generated service-tag rules (300-999), the Anyscale storage rule (3900) and the Deny (4000). Overlapping priorities fail the apply with SecurityRuleConflict."
  }
}

variable "block_public_internet_egress" {
  description = <<-EOT
    (Optional) Add an NSG rule denying outbound traffic to the `Internet` service tag.

    The nodes subnet NSG always allows outbound to the regional `AzureCloud`
    service tag, which covers everything the platform needs: Microsoft Entra
    (workload identity token exchange), MCR (system images), Azure Resource
    Manager, the AKS binary mirror, and Azure Storage - including the Anyscale
    storage account that serves images and dependencies.

    Setting this to true adds a lower-priority Deny rule for `Internet`, which
    blocks everything that is NOT an Azure endpoint: PyPI, Hugging Face, GitHub
    and Docker Hub. Platform images from non-Azure registries (ingress-nginx
    from registry.k8s.io, the Anyscale operator image) must then be mirrored
    into the ACR via `acr_cache_rules` - see acr.tf.

    **Default is false on purpose.** Bring the cluster up, confirm the operator
    registers and workloads schedule, then flip this to true and re-verify.
    Enabling it on the first apply means debugging NSG rules and Anyscale
    registration at the same time, and the failures are late and opaque - nodes
    that will not provision, image pulls that hang rather than error.

    ex:
    ```
    block_public_internet_egress = true
    ```
  EOT
  type        = bool
  nullable    = false
  default     = false
}

# ---------------------------------------------------------------------------------------------------------------------
# NODE POOLS
# ---------------------------------------------------------------------------------------------------------------------

variable "system_vm_size" {
  description = <<-EOT
    (Optional) VM size for the `sys` (system) node pool.

    This pool is untainted, so it is where CoreDNS, the Anyscale operator,
    ingress-nginx and anything else without an Anyscale toleration lands.

    Note that the Dsv5 family has no local temp disk, so ephemeral OS disks are
    unavailable - every pool in this example uses managed OS disks.
  EOT
  type        = string
  default     = "Standard_D8s_v5"
}

variable "cpu_instance_types" {
  description = <<-EOT
    (Optional) CPU node pool configuration.

    One on-demand and one spot pool is created per entry, named `od<key>` and
    `spot<key>`. Both scale from zero and are tainted with
    `node.anyscale.com/capacity-type=<ON_DEMAND|SPOT>:NoSchedule`.

    Each size gets its own pool rather than being listed together. The AKS
    cluster autoscaler assumes every node in a pool has identical CPU and
    memory, and makes incorrect scale-up decisions when they differ.

    **The key names the instance, not what a pod can request.** Kubelet reserves
    capacity for itself and the OS, so allocatable is always below nameplate - a
    Standard_D8s_v5 advertises 8 vCPU but a pod requesting `cpu: 8` will never
    schedule on it, and the autoscaler reports insufficient CPU without scaling
    up. Size each pool one step above the largest pod request you intend to
    place on it.

    AKS node pool names are capped at 12 characters, lowercase alphanumeric,
    starting with a letter - hence `od8cpu` rather than `ondemand_8cpu`. The
    validation below enforces the limit including the `spot` prefix.

    ex:
    ```
    cpu_instance_types = {
      "8cpu"  = { vm_size = "Standard_D8s_v5" }
      "16cpu" = { vm_size = "Standard_D16s_v5" }
    }
    ```
  EOT
  type = map(object({
    vm_size   = string
    min_count = optional(number, 0)
    max_count = optional(number, 10)
  }))
  default = {
    # 8 vCPU / 32 GiB
    "8cpu" = {
      vm_size = "Standard_D8s_v5"
    }
    # 16 vCPU / 64 GiB - use for a full 8-CPU Ray worker
    "16cpu" = {
      vm_size = "Standard_D16s_v5"
    }
  }

  validation {
    condition = alltrue([
      for k, v in var.cpu_instance_types : can(regex("^[a-z0-9]+$", k))
    ])
    error_message = "cpu_instance_types keys must be lowercase alphanumeric (they become part of the AKS node pool name)."
  }

  validation {
    condition = alltrue([
      for k, v in var.cpu_instance_types : length("spot${k}t") <= 12
    ])
    error_message = "cpu_instance_types keys must be 7 characters or fewer - AKS node pool names are capped at 12, the spot pools prepend 'spot', and temporary_name_for_rotation appends 't'."
  }
}

variable "system_node_pool_disk_size_gb" {
  description = "(Optional) OS disk size for the system node pool, in GB."
  type        = number
  nullable    = false
  default     = 128
}

variable "node_pool_disk_size_gb" {
  description = <<-EOT
    (Optional) OS disk size for the CPU workload node pools, in GB.

    Anyscale and Ray images are large. 128 GB is enough for a bare cluster but
    runs tight once several cluster environments are cached on a node. Note that
    the Dsv5 family has no temp disk, so this is a managed (network-attached)
    Premium SSD - larger disks cost more but also get more IOPS.
  EOT
  type        = number
  nullable    = false
  default     = 256
}

# ---------------------------------------------------------------------------------------------------------------------
# STORAGE
# ---------------------------------------------------------------------------------------------------------------------

variable "storage_account_name" {
  description = "(Optional) Override the generated storage account name. Must be globally unique."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.storage_account_name == null || can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Storage account name must be 3-24 characters, lowercase letters and numbers only."
  }
}

variable "storage_public_network_access_enabled" {
  description = <<-EOT
    (Optional) Allow access to the storage account over its public endpoint.

    This example creates blob and dfs private endpoints regardless, so traffic
    from inside the VNet always resolves to a private IP. This flag controls
    whether the public endpoint also works.

    **Two consequences of leaving this false:**

    * Log viewing in the Anyscale UI breaks. The browser fetches log blobs
      directly from `*.blob.core.windows.net`, which is what the `cors_rule`
      below exists for. From outside the VNet those fetches fail.
    * `terraform apply` creates the blob container through the Resource Manager
      API (the container resource is keyed by `storage_account_id`, not the data
      plane), so container creation is expected to work - but if you hit a data
      plane authorization error on first apply, set this to true, apply, and set
      it back.

    ex:
    ```
    storage_public_network_access_enabled = true
    ```
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "cors_rule" {
  description = <<-EOT
    (Optional) CORS rule on the storage account's blob service.

    The default allows the Anyscale web UI (*.anyscale.com) to read logs and
    other objects directly from the browser. Note that this only has an effect
    when `storage_public_network_access_enabled` is true - with the public
    endpoint off, the browser cannot reach the account at all.
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
  description = "(Optional) Whether the azurerm provider uses Entra ID rather than shared keys for the Storage data plane."
  type        = bool
  nullable    = false
  default     = false
}

variable "enable_blob_driver" {
  description = "(Optional) Enable the Azure Blob CSI driver on the cluster. Required to mount blob storage from pods."
  type        = bool
  nullable    = false
  default     = false
}

variable "enable_nfs" {
  description = <<-EOT
    (Optional) Create a Premium FileStorage account for NFS shared storage.

    Optional for Anyscale. This is the rough Azure equivalent of EFS in the AWS
    examples. When enabled it gets its own private endpoint and private DNS
    zone (`privatelink.file.core.windows.net`).
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "storage_account_name_nfs" {
  description = "(Optional) Override the generated NFS storage account name. Must be globally unique."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.storage_account_name_nfs == null || can(regex("^[a-z0-9]{3,24}$", var.storage_account_name_nfs))
    error_message = "NFS storage account name must be 3-24 characters, lowercase letters and numbers only."
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# CONTAINER REGISTRY
# ---------------------------------------------------------------------------------------------------------------------

variable "enable_acr" {
  description = <<-EOT
    (Optional) Create an Azure Container Registry with a private endpoint.

    The registry serves two purposes in this example:

    1. It is the image build target for Anyscale cluster environments - the
       operator needs AcrPush and Container Registry Tasks Contributor, which
       acr.tf grants.
    2. When `block_public_internet_egress` is true it is the ONLY way platform
       images from non-Azure registries reach the cluster, via `acr_cache_rules`.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "acr_name" {
  description = "(Optional) Override the generated ACR name. Must be globally unique."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.acr_name == null || can(regex("^[a-zA-Z0-9]{5,50}$", var.acr_name))
    error_message = "ACR name must be 5-50 alphanumeric characters."
  }
}

variable "acr_cache_rules" {
  description = <<-EOT
    (Optional) ACR cache rules mirroring upstream images into the private registry.

    Each entry creates an `azurerm_container_registry_cache_rule`. On the first
    pull of `<acr>.azurecr.io/<target_repo>:<tag>`, ACR fetches the image from
    `source_repo` and caches it.

    **Why this works even with egress blocked:** ACR performs the upstream fetch
    from its own service infrastructure, not from your VNet. Your nodes pull
    from ACR over the private endpoint; the upstream hop never traverses the
    nodes subnet, so the `Deny Internet` NSG rule does not apply to it. Setting
    `public_network_access_enabled = false` on the registry does not interfere
    either - that governs inbound access to your registry, not ACR's outbound.

    Anonymous cache rules are subject to upstream rate limits. Docker Hub in
    particular throttles unauthenticated pulls; attach a credential set to the
    rule (not modelled here) if you hit that.

    After applying, override the image registry in your helm values so workloads
    pull the mirrored copy - e.g. for ingress-nginx:

    ```
    controller:
      image:
        registry: <acr_login_server>
    ```

    ex:
    ```
    acr_cache_rules = {
      "ingress-nginx-controller" = {
        source_repo = "registry.k8s.io/ingress-nginx/controller"
        target_repo = "ingress-nginx/controller"
      }
    }
    ```
  EOT
  type = map(object({
    source_repo = string
    target_repo = string
  }))
  default = {
    "ingress-nginx-controller" = {
      source_repo = "registry.k8s.io/ingress-nginx/controller"
      target_repo = "ingress-nginx/controller"
    }
    "ingress-nginx-certgen" = {
      source_repo = "registry.k8s.io/ingress-nginx/kube-webhook-certgen"
      target_repo = "ingress-nginx/kube-webhook-certgen"
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# ANYSCALE CONTROL PLANE PRIVATE LINK
# ---------------------------------------------------------------------------------------------------------------------

variable "anyscale_control_plane_url" {
  description = <<-EOT
    (Optional) The Anyscale control plane URL the operator connects to.

    For the Azure-hosted production control plane this is
    `https://console.azure.anyscale.com`. For a per-deployment dev endpoint it
    looks like `https://cld-<id>.azure.anyscale-cloud-dev.dev`.

    This value is emitted in the helm command from outputs.tf as
    `global.controlPlaneURL`.
  EOT
  type        = string
  default     = "https://console.azure.anyscale.com"
}

variable "anyscale_auth_audience" {
  description = <<-EOT
    (Optional) Entra token audience the operator requests when authenticating.

    This identifies the Anyscale application in Microsoft Entra and is emitted
    in the helm command as `global.auth.audience`. The default is the audience
    used by the Azure-hosted Anyscale control plane; a dev deployment may use a
    different application ID, so confirm it alongside the control plane URL.
  EOT
  type        = string
  default     = "api://086bc555-6989-4362-ba30-fded273e432b/.default"
}

variable "enable_privatelink" {
  description = <<-EOT
    (Optional) Create a Private Endpoint to the Anyscale control plane.

    When enabled, privatelink.tf creates a private endpoint against the Anyscale
    Private Link Service, a private DNS zone, and records so that in-cluster
    workloads resolve the control plane hostname to a private IP inside the VNet
    rather than over the public internet.

    This is the Azure analog of the AWS PrivateLink interface endpoint in
    examples/aws/eks-private-cpu/privatelink.tf.

    Requires `anyscale_privatelink_service_alias`. Note that this does NOT
    remove the need for egress - nodes still reach Microsoft Entra, MCR, Azure
    Resource Manager and the Anyscale storage account through the cluster's
    normal egress path.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "anyscale_privatelink_service_alias" {
  description = <<-EOT
    (Optional) Alias of the Anyscale Private Link Service to connect to.

    Anyscale provides this for your cloud deployment. It looks like
    `<prefix>.<guid>.<region>.azure.privatelinkservice`.

    The alias does not have to be in this cluster's region. A private endpoint
    must sit in the same region as its own VNet, but a Private Link service can
    be accessed from approved private endpoints in any public region - so reuse
    the alias Anyscale gave you even when deploying elsewhere.

    The connection is created as a MANUAL connection because it is cross-tenant:
    the endpoint sits in `Pending` state until Anyscale approves it on their
    side. That handshake happens after your first apply.

    Required when `enable_privatelink` is true.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_privatelink || length(var.anyscale_privatelink_service_alias) > 0
    error_message = "anyscale_privatelink_service_alias must be set when enable_privatelink is true."
  }
}

variable "anyscale_private_dns_zone_name" {
  description = <<-EOT
    (Optional) Private DNS zone created for Anyscale control plane resolution.

    Only used when `enable_privatelink` is true. The zone is linked to this
    example's VNet, so it resolves only from inside the VNet.

    **The zone is authoritative for its whole domain inside the VNet.** Once
    `azure.anyscale-cloud-dev.dev` exists as a private zone linked to this VNet,
    no other name in that domain resolves publicly from inside it. Use the
    narrowest zone that covers your control plane hostname, or keep the wildcard
    record below.

    ex:
    ```
    anyscale_private_dns_zone_name = "azure.anyscale-cloud-dev.dev"
    ```
  EOT
  type        = string
  default     = "azure.anyscale-cloud-dev.dev"
}

variable "anyscale_privatelink_record_names" {
  description = <<-EOT
    (Optional) Records created in the private DNS zone, each without the zone suffix.

    Every entry becomes an A record pointing at the private endpoint's IP.
    Combined with `anyscale_private_dns_zone_name`, an entry forms the FQDN that
    resolves to the endpoint, e.g.
    `cld-abc123.azure.anyscale-cloud-dev.dev`.

    `"*"` creates a wildcard record. Because the private zone is authoritative
    for the whole domain inside the VNet, any name in it without a record fails
    to resolve rather than falling back to public DNS - a wildcard avoids having
    to enumerate every hostname the operator talks to. This mirrors the AWS
    example, which uses `["*"]` for the same reason. Note that a wildcard does
    not cover the zone apex; add `"@"` as an entry if you need it.

    Required when `enable_privatelink` is true.

    ex:
    ```
    anyscale_privatelink_record_names = ["*"]
    anyscale_privatelink_record_names = ["cld-abc123"]
    ```
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !var.enable_privatelink || length(var.anyscale_privatelink_record_names) > 0
    error_message = "anyscale_privatelink_record_names must be set when enable_privatelink is true."
  }
}
