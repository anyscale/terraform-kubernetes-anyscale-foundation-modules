# Anyscale on AKS — Private Networking, CPU only

A private AKS cluster for Anyscale: private API server, private storage and registry, optional Private Link to
the Anyscale control plane, and an NSG that can restrict egress to Azure destinations only.

**Scope: Azure infrastructure.** The Anyscale cloud and the operator are both created through ARM
(`Anyscale.Platform/clouds` + the `Anyscale.AKS.Operator` cluster extension), outside this example. Terraform
builds the infrastructure and surfaces the values that flow needs as outputs. The one in-cluster component you
install by hand is the ingress controller.

Use it as a starting point and adapt it to your own security requirements.

## What gets deployed

| Type | Resource | File |
|---|---|---|
| Network | Resource group, VNet (`10.42.0.0/16`), `aks-nodes` + `private-endpoints` subnets | `main.tf` |
| Network | NSG on the nodes subnet — the ingress and egress boundary | `main.tf` |
| Storage | ADLS Gen2 account + container, **blob and dfs private endpoints**, optional Premium NFS | `storage.tf` |
| Cluster | AKS with **private API server**, Azure CNI **overlay + Cilium**, workload identity | `aks.tf` |
| Cluster | CPU node pools — one on-demand and one spot per size, all scaling from zero | `aks.tf` |
| Identity | Operator user-assigned identity + federated credential + `Storage Blob Data Contributor` | `identity.tf` |
| Registry | **Premium ACR** behind a private endpoint, cache rules, `AcrPull` / `AcrPush` / Tasks roles | `acr.tf` |
| Anyscale | Private endpoint + private DNS zone for the control plane (opt-in) | `privatelink.tf` |

Egress uses AKS's default load-balancer outbound — there is no NAT gateway. `outbound_type` selects *how*
egress happens, not *whether*, and the NSG is what bounds it.

### Node pools

| Pool | VM size | vCPU | Memory | Capacity |
|---|---|---|---|---|
| `sys` | `Standard_D8s_v5` | 8 | 32 GiB | On-demand, min 1 / max 3 |
| `od8cpu` · `spot8cpu` | `Standard_D8s_v5` | 8 | 32 GiB | On-demand · Spot |
| `od16cpu` · `spot16cpu` | `Standard_D16s_v5` | 16 | 64 GiB | On-demand · Spot |

`sys` is the only untainted pool, so CoreDNS, the operator and ingress-nginx land there. Workload pools scale
from zero and carry `node.anyscale.com/capacity-type=<ON_DEMAND|SPOT>:NoSchedule`.

Three constraints worth knowing before resizing them:

* **Dsv5 has no local temp disk**, so ephemeral OS disks are unavailable — all pools use managed Premium SSDs.
* **AKS node pool names cap at 12 characters**, lowercase alphanumeric, letter-first. Hence `od8cpu`, not
  `ondemand_8cpu`. `cpu_instance_types` validates keys at ≤7 chars to leave room for the `spot` prefix and the
  `t` rotation suffix.
* **Allocatable is below nameplate.** A `D8s_v5` advertises 8 vCPU but kubelet reserves some, so a pod
  requesting `cpu: 8` never schedules on the `8cpu` pool — the autoscaler reports insufficient CPU and does
  nothing. Size one step up.

Spot draws on a **separate quota** from on-demand:

```bash
az vm list-usage --location westus2 -o table | grep -iE "DSv5|Spot|LowPriority"
```

## Feature switches

| Variable | Default | Effect |
|---|---|---|
| `block_public_internet_egress` | `false` | Adds `Deny → Internet`. **Read [Egress](#egress) before enabling** |
| `allow_public_ingress` | `true` | Opens inbound 80/443 for a public ingress load balancer |
| `public_ingress_source_prefixes` | `["Internet"]` | Who may reach the ingress. Narrow to CIDRs to restrict |
| `enable_privatelink` | `false` | Private endpoint to the Anyscale control plane. Needs a PLS alias |
| `enable_acr` | `true` | Premium ACR + private endpoint + cache rules |
| `storage_public_network_access_enabled` | `false` | Public endpoint on your storage account. Off breaks UI log viewing |
| `enable_anyscale_storage_private_endpoint` | `false` | Private endpoint to Anyscale's storage. Needs their approval |
| `enable_nfs` | `false` | Premium Files NFS account + private endpoint |
| `additional_egress_service_tags` | `[]` | Extra outbound service tags — needed for cross-region deployments |

## Prerequisites

* [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), logged in (`az login`)
* [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
* `Standard DSv5 Family vCPUs` quota in your region

---

## 1. Deploy the infrastructure

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in azure_tenant_id at minimum

terraform init
terraform plan
terraform apply
```

## 2. Register the cloud through ARM

Hand these outputs to the ARM flow:

```bash
terraform output -json anyscale_cloud_registration_values
terraform output -json anyscale_operator_extension_settings
```

The first carries what `Anyscale.Platform/clouds` + `cloudResources` need — the operator's managed identity
principal ID, the `abfss://` bucket name and blob endpoint, and the ACR resource ID. The second carries the
extension's `configuration_settings`, minus `global.cloudDeploymentId`, which registration returns rather than
consumes.

`anyscale_control_plane_url` in your tfvars must match the environment you register against. Pointing the
operator at a different control plane than the one holding the cloud produces a `cloudDeploymentId` that does
not exist where the operator looks, and the failure gives no hint of the mismatch.

## 3. Install the ingress controller

The operator creates an Ingress per session but does **not** install a controller — the chart's
`ingress-nginx.enabled` defaults to `false`. Without one, Ingress resources sit with an empty `ADDRESS` and
nothing routes. The operator writes `ingressClassName: nginx`, so the controller has to own that class.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm pull ingress-nginx/ingress-nginx --version 4.12.1

# set controller.image.registry to your acr_login_server output first
az aks command invoke -g <rg> -n <cluster> \
  --file ingress-nginx-4.12.1.tgz --file sample-values_nginx.yaml \
  --command "helm upgrade ingress-nginx ./ingress-nginx-4.12.1.tgz \
               --namespace ingress-nginx --values sample-values_nginx.yaml \
               --create-namespace --install"
```

Three settings in `sample-values_nginx.yaml` are not optional:

* **Ingress class `nginx`** — matching what the operator emits. `controller.ingressClass` is the *legacy*
  annotation and does **not** rename the IngressClass; the name comes from `controller.ingressClassResource.name`.
  Get this wrong and you get a healthy controller that silently ignores every Ingress.
* **Clear `digest` and `digestChroot`.** A cache rule resolves the *tag* upstream to populate itself, so a
  digest-pinned pull of content it has never seen is the fragile path.
* **Turn autoscaling off.** The chart defaults to `maxReplicas: 11` with a 50% *memory* target, which the
  controller exceeds at idle — it scales straight to 11 pods serving no traffic.

### Why the chart is pulled locally

Both halves of an in-cluster install need handling when `block_public_internet_egress = true`:

| Fetched | By | Blocked because | Answer |
|---|---|---|---|
| **Helm chart** | `helm`, running **in-cluster** under `command invoke` | `kubernetes.github.io` is not an Azure endpoint | `helm pull` on your workstation, upload with `--file` |
| **Container images** | kubelet, on the nodes | `registry.k8s.io` is not an Azure endpoint | ACR cache rule + registry override in the chart |

`command invoke` runs the command **inside the cluster**, so `helm repo add` uses the *cluster's* egress, not
your workstation's — that is the part people miss.

Cache rules are **pull-triggered, not a mirror job**: nothing lands in your ACR until something asks *ACR* for
it. The registry override is therefore required; without it the nodes ask upstream directly, ACR is never
contacted, and the cache stays empty.

```
kubelet ──► privatelink.azurecr.io ──► ACR          ← inside the VNet, allowed by NSG rule 110
                                        │
                                        └──(ACR's own egress)──► registry.k8s.io
```

That upstream hop runs on ACR's service infrastructure, not your subnet, so `Deny → Internet` never applies to
it. `public_network_access_enabled = false` on the registry does not interfere either — that governs *inbound*
access.

**Anyscale's own images need none of this.** The operator image comes from `arcmktplaceprod.azurecr.io`, an
Azure endpoint already covered by the service tags. Ray workload images come from
`registry-<cloud-id>.<your-anyscale-domain>`, which resolves through the same Private Link endpoint as the
control plane.

## 4. Verify

```bash
RG=$(terraform output -raw azure_resource_group_name)
CL=$(terraform output -raw azure_aks_cluster_name)

az aks command invoke -g $RG -n $CL --command "kubectl get nodes"
az aks command invoke -g $RG -n $CL --command "kubectl get po -n anyscale-operator"
az aks command invoke -g $RG -n $CL --command "kubectl get po,svc -n ingress-nginx"
az aks command invoke -g $RG -n $CL --command "kubectl get ingress -A"
```

Want `Running` pods, an `EXTERNAL-IP` on the nginx Service (not `<pending>`), and Ingress resources showing
that same address.

**Confirm private endpoints were approved.** Cross-tenant connections sit `Pending` until the owner accepts,
and `terraform apply` reports success either way:

```bash
az network private-endpoint list -g $RG -o table \
  --query "[].{name:name, auto:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status, manual:manualPrivateLinkServiceConnections[0].privateLinkServiceConnectionState.status}"
```

**Confirm traffic takes the private path.** Resolve from inside the cluster and expect a `10.4x.8.x` answer —
the same hostname from outside the VNet returns a public IP, and that difference is the proof:

```bash
az aks command invoke -g $RG -n $CL \
  --command "kubectl -n kube-system exec ds/csi-azurefile-node -c azurefile -- getent hosts <control-plane-hostname>"
```

The CSI daemonset is used because it ships a full image with `getent`. CoreDNS and metrics-server are
distroless, and `kubectl run --image=busybox` fails when egress is blocked.

## 5. Connecting to the cluster

The API server is private, so `kubectl` and `helm` only work from inside the VNet. This example does not create
that connectivity.

| Option | Setup | Trade-off |
|---|---|---|
| **`az aks command invoke`** | none | What this example assumes. No interactive `kubectl`, no `logs -f` |
| Jumpbox + SSH tunnel | a small VM | Cheapest real `kubectl`; a SOCKS proxy resolves DNS remotely |
| Point-to-Site VPN | VPN gateway | Real `kubectl`; DNS needs a Private Resolver or an `/etc/hosts` entry |
| VNet peering | peering + DNS zone link | **Both** are required — a route alone gives a name that will not resolve |

There is **no equivalent of API server authorized IP ranges** for private clusters: that setting applies only
to public clusters and is mutually exclusive with private ones.

## Destroy

```bash
# 1. Delete the Anyscale cloud through ARM FIRST, while the operator is still
#    installed. The control plane rejects the delete with a 409 while sessions
#    are still draining, and the operator has to be alive for that to finish.
# 2. Then:
terraform destroy
```

Order matters: tearing down the cluster first leaves the cloud undeletable and wedges the resource group.

---

## What "private" means here

`private_cluster_enabled = true` makes **the API server** private and nothing else. It does not change what
nodes reach outbound.

| Private | How |
|---|---|
| AKS API server | Private endpoint + AKS-managed `privatelink.<region>.azmk8s.io` |
| Your storage account | blob + dfs private endpoints |
| Your ACR | Private endpoint + `privatelink.azurecr.io` |
| Anyscale control plane | Private endpoint against their Private Link Service (opt-in) |

| Still leaves the VNet | Why it cannot be private |
|---|---|
| Microsoft Entra | **No Private Link exists.** The operator exchanges its service-account token for an Entra token on every refresh |
| MCR | System images — kube-proxy, CoreDNS, Cilium, metrics-server, CSI |
| AKS binary mirror | kubelet, containerd, CNI plugins at provisioning |
| Azure Resource Manager | Cloud provider, CSI, autoscaler |

## Ingress

| Prio | Source → Destination | Ports | Purpose |
|---|---|---|---|
| 100 | `VirtualNetwork` → `VirtualNetwork` | all | Node-to-node, nodes → private endpoints |
| 200 | `public_ingress_source_prefixes` → `*` | 80, 443 | Your ingress. Only when `allow_public_ingress = true` |

Everything else inbound is dropped by the platform's `DenyAllInBound` at 65500.

Two non-obvious details, both of which produce a *convincing* failure when wrong:

* **A public Standard LB does not SNAT the client**, so the node sees the caller's real IP — traffic matching
  the `Internet` tag. AKS opens its own NSG in the node resource group for LoadBalancer services but does
  **not** touch a user-assigned NSG on the subnet, and both are evaluated.
* **The ports are the service ports, not the nodePorts.** AKS creates the LB rules with
  `backendPort == frontendPort` (floating IP), so nodePorts appear only in the health-probe config. Open the
  nodePort range instead and the probes pass, the LB reports healthy, the Service gets an `EXTERNAL-IP`, DNS
  resolves — and every real request is silently dropped.

## Egress

| Prio | Destination | Why |
|---|---|---|
| 110 | `VirtualNetwork` | Your private endpoints |
| 300 | `AzureActiveDirectory` | Entra token exchange. **Global, not regional** |
| 310 | `AzureResourceManager` | Cloud provider, CSI, autoscaler |
| 320 | `MicrosoftContainerRegistry` | MCR registry API |
| 330 | `AzureFrontDoor.FirstParty` | MCR image *layers* — a different tag from the registry API |
| 340 | `AzureCloud.<region>` | In-region Azure services |
| 350 | `Storage.<region>` | Storage in this region |
| 3900 | `Storage.<their-region>` | Only when `anyscale_storage_account` is set |
| 4000 | `Internet` — **DENY** | Only when `block_public_internet_egress = true` |

Rules 300+ are generated one per entry in `local.egress_service_tags`; extend with
`additional_egress_service_tags`. Priorities are banded so the three mechanisms cannot collide: 300–999
generated, 1000–3899 `additional_egress_rules`, 3900 Anyscale storage, 4000 the Deny.

**The `Internet` tag includes Azure's own public IP space**, which is why the allow rules must sit above the
Deny.

**A regional `AzureCloud.<region>` tag covers almost none of what the platform needs.** Resolving each host and
checking which tag actually contains the address:

| Host | Address | In `AzureCloud.WestUS2`? | Tag that does contain it |
|---|---|---|---|
| `login.microsoftonline.com` | `20.190.190.132` | no | `AzureActiveDirectory` |
| `mcr.microsoft.com` | `150.171.70.10` | no | `AzureFrontDoor.FirstParty` |
| `management.azure.com` | `4.150.240.10` | no | `AzureResourceManager` |
| `packages.aks.azure.com` | `23.212.62.207` | no | **none — Akamai CDN** |

`block_public_internet_egress` **defaults to `false` on purpose.** Bring the cluster up, confirm the operator
registers and workloads schedule, *then* enable it and re-verify. Enabling it on the first apply means
debugging NSG rules and cloud registration at once, and NSG failures are delayed and opaque — cached images and
unexpired tokens mask them for hours.

### Deploying in another region

The four global tags carry over unchanged. Only `<region>`-suffixed tags move — and Anyscale's resources do not
move with you:

```hcl
azure_location                 = "East US 2"
block_public_internet_egress   = true
additional_egress_service_tags = ["Storage.WestUS2"]   # ← Anyscale's region
```

## Private Link to the Anyscale control plane

```hcl
enable_privatelink                 = true
anyscale_privatelink_service_alias = "<prefix>.<guid>.<region>.azure.privatelinkservice"
anyscale_private_dns_zone_name     = "azure.anyscale-cloud.dev"
anyscale_privatelink_record_names  = ["*"]
anyscale_control_plane_url         = "https://cld-<id>.azure.anyscale-cloud.dev"
```

You need the **PLS alias** and the **exact hostname with its parent zone** from Anyscale. The alias does *not*
have to be in this cluster's region — a private endpoint must sit in its own VNet's region, but the service it
targets may be anywhere.

* **The connection is cross-tenant and manual.** Anyscale must approve it. `terraform apply` **succeeds** with
  the endpoint `Pending`, so a clean apply is not evidence the path works.
* **Keep the wildcard record.** Anyscale serves its image registry (`registry-<cloud-id>.<same domain>`) through
  this same endpoint. A per-hostname record would cover the control plane but not the registry, and image pulls
  would fail while the control plane looked healthy.
* **The private DNS zone is authoritative for its whole domain inside the VNet.** Any name in it without a
  record fails to resolve rather than falling back to public DNS.
* **This does not remove the need for egress.** Private Link carries control-plane traffic only.

## Known limits

**The egress allowlist is not provably complete.** It was assembled by reasoning about dependencies, which is
the method that already missed Entra once — the cluster looked healthy for hours before failing with
`DefaultAzureCredential: failed to acquire a token`. To verify properly, enable NSG flow logs and read the
denied flows, or deliberately exercise every external path: fresh workspace launch, snapshot, and a
scale-from-zero node pool.

**`packages.aks.azure.com` cannot be expressed as an NSG rule.** It resolves into Akamai space and is in no
Azure service tag. Running nodes are unaffected — the binaries are baked into the node image — but node image
upgrades and some provisioning paths can fail with the Deny on.

**Service tags are coarse.** `Storage.<region>` permits *any* storage account in that region. This is a
blast-radius control, not an exfiltration control — only FQDN filtering (Azure Firewall) or full
private-endpoint isolation gets you that.

**Storage with public access off breaks UI log viewing.** The Anyscale console fetches log blobs directly from
`*.blob.core.windows.net` in your browser, which is outside the VNet. That is what the `cors_rule` exists for.

## Production readiness

| This example | Hardening step |
|---|---|
| Public ingress load balancer | Internal LB; requires VNet access to open a workspace |
| Service-tag egress allowlist | Azure Firewall with FQDN rules — the only way to reach PyPI selectively |
| Anyscale storage reached publicly | Cross-tenant private endpoint, subject to their approval |
| Local Terraform state | Remote backend (`azurerm` with a state storage account) |
| LRS storage, Free-tier AKS SLA | ZRS/GRS replication, `sku_tier = "Standard"` |
| Local account auth on the cluster | Entra-only auth with `kubelogin`, local accounts disabled |
| Single zone | Zone-redundant node pools |
