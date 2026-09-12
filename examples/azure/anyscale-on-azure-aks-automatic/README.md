# Anyscale on AKS Automatic

One `terraform apply` stands up an **AKS Automatic** cluster and registers it as an Anyscale cloud on the Azure-hosted control plane (`https://console.azure.anyscale.com`) — infrastructure, cloud registration, operator, and gateway in a single pass.

This is the [`anyscale-on-azure`](../anyscale-on-azure) reference example re-cut onto AKS Automatic. Automatic removes a large chunk of what that example configures by hand — node pools, the Envoy Gateway chart, the NVIDIA GPU operator — and imposes constraints of its own: Entra-only cluster auth, enforced deployment safeguards, and a three-subnet BYO VNet.

## What gets deployed

| Type | Resource | File |
|---|---|---|
| Azure infra | Resource group, VNet, **three** subnets (delegated API-server `/28`, user nodes, system nodes) | `main.tf` |
| Azure infra | Cluster user-assigned identity + `Network Contributor` on the VNet | `main.tf` |
| Azure infra | Storage account (**HNS / ADLS Gen2**, TLS 1.2, OAuth-default) + private blob container; optional Premium NFS account | `main.tf` |
| Azure infra | `azurerm_kubernetes_automatic_cluster` — API Server VNet Integration, app-routing Istio, hosted-system subnets | `aks.tf` |
| Azure infra | azapi patches: **Gateway API installation** + nginx controller off, monitoring profile, **deployment-safeguards exclusion** | `aks.tf` |
| Azure infra | Entra RBAC grants (`RBAC Cluster Admin`, `Cluster User`) for the deploying principal | `aks.tf` |
| Azure infra | User-assigned identity + federated credential + `Storage Blob Data Contributor` | `identity.tf` |
| Azure infra | ACR + kubelet `AcrPull` + operator `AcrPush` / `Container Registry Tasks Contributor` | `acr.tf` |
| Anyscale | Subscription onboarding: `Anyscale.Platform` RP registration + agreement acceptance (one-time, both opt-out) | `anyscale.tf` |
| Anyscale | `Anyscale.Platform/clouds` + `clouds/cloudResources/default` (native azapi, **GA `2026-09-01`**) | `anyscale.tf` |
| Anyscale | `Anyscale.AKS.Operator` marketplace extension (Entra workload-identity auth, opt-out) | `anyscale.tf` |
| In-cluster | Operator namespace + 3-listener `Gateway` on `approuting-istio`, applied via `kubectl` | `gateway.tf` |
| In-cluster | Karpenter `AKSNodeClass` + GPU `NodePool`s with AKS-managed drivers (opt-in) | `gpu.tf` |
| Observability | Azure Monitor workspace + managed Prometheus DCE/DCR/recording rules; Log Analytics + Container Insights | `monitoring.tf`, `prometheus.tf` |

## Part 1 — How this differs from `anyscale-on-azure`

| Concern | `anyscale-on-azure` (Standard) | This example (Automatic) |
|---|---|---|
| Cluster resource | `azurerm_kubernetes_cluster`, SKU Free/Standard | `azurerm_kubernetes_automatic_cluster` (azurerm **≥ 4.81.0**) |
| Compute | 5 hand-managed pools: `sys`, `cpu16`, `cpu16spot`, `gpu×N`, `gpuspot×N` | **Karpenter/NAP only.** Managed system pool + built-in default NodePool; we add GPU `NodePool` + `AKSNodeClass` CRs |
| GPU drivers | NVIDIA GPU operator Helm chart (default) or `gpu_driver = "Install"` | AKS-managed via the `EnableManagedGPUExperience` tag on the `AKSNodeClass` (needs `ManagedGPUExperiencePreview`) |
| Ingress | Envoy Gateway Helm release + `EnvoyProxy` + `GatewayClass eg` | Built-in app-routing **Istio**, `gatewayClassName: approuting-istio` — no Helm release, no GatewayClass to create |
| LB annotations | On the `EnvoyProxy` object | On the Gateway's `spec.infrastructure.annotations` (no `EnvoyProxy` exists) |
| Networking | Azure CNI overlay + Cilium configured explicitly; **1** node subnet | Overlay + Cilium are Automatic's defaults; BYO VNet requires **3** subnets |
| Cluster identity | `SystemAssigned` | **`UserAssigned`** (required for BYO VNet) + `Network Contributor` on the VNet |
| Cluster auth | Local admin certs from `kube_config` drive the helm/kubernetes/kubectl providers | Local accounts disabled, Entra RBAC enforced → `kubelogin` + an `Azure Kubernetes Service RBAC Cluster Admin` assignment |
| In-cluster apply | Terraform providers (`kubectl_manifest`, `helm_release`) | Rendered YAML + a `terraform_data` local-exec `kubectl apply` |
| Policy | none | Azure Policy + **deployment safeguards in Enforcement** → the Anyscale namespace must be excluded or the operator's pods are rejected at admission |
| Monitoring | `oms_agent` / `monitor_metrics` blocks on the typed resource | Typed resource exposes no monitoring blocks → `azapi_update_resource` patch |
| Regions | Anyscale-supported list (12) | Anyscale ∩ Automatic-GA (11) — **`westcentralus` drops out** |
| Unchanged | Subscription onboarding (`register_anyscale_resource_provider`, `accept_anyscale_platform_agreement`), Anyscale cloud + `cloudResources` via azapi on GA `2026-09-01`, optional operator extension (`install_operator_extension`) on workload identity, deterministic `<cldrsrc-id>.<region>.cloudapp.azure.com` hostname, storage / ACR / identity / prometheus | same |

### Variables that no longer exist

`system_vm_size`, `cpu_vm_size`, `gpu_driver_mode`, `gpu_operator_chart_version`, `enable_node_auto_provisioning`, `nap_gpu_sku_name`, `envoy_gateway`, and `enable_blob_driver`. AKS Automatic manages the system pool, always runs node auto-provisioning, installs GPU drivers itself, ships the Istio gateway implementation, and enables the storage CSI drivers by default. `gpu_pool_configs` becomes `gpu_nodepool_configs` with a slightly richer schema.

## Part 2 — How this differs from upstream `awesome-aks`

Upstream: [`pauldotyu/awesome-aks` → `2026-07-15-anyscale-on-aks-automatic`](https://github.com/pauldotyu/awesome-aks/tree/main/2026-07-15-anyscale-on-aks-automatic).

**Kept:** AKS Automatic itself, the `approuting-istio` gateway class, the DNS-label hostname trick, the deployment-safeguards namespace exclusion, the managed-GPU `AKSNodeClass`, and `sample-workload/`.

**Added:**

| | |
|---|---|
| Variables | Instead of hardcoded `anyscale<NN>` names |
| BYO VNet | Upstream uses the AKS-managed network |
| Feature switches | `enable_monitoring`, `enable_otlp_app_insights`, `enable_nfs`, `enable_acr`, `internal_gateway`, `api_server_authorized_ip_ranges` |
| Single-apply gateway | Upstream stops at writing `anyscale-gateway.yaml` and tells you to `kubectl apply` it yourself |
| Destroy hook | Upstream `terraform destroy` wedges: the operator extension is torn down first, and the Anyscale RP then returns 409 on the cloud delete |
| Platform role self-grant | Subscription Owner does *not* carry over to the Anyscale RP |
| Typed cluster resource | Instead of a raw azapi `managedClusters` body |
| Single-region default | Upstream splits `location` from `anyscale_cloud_location`; that split is available here as an override but both default to one region |
| Tooling | `terraform.tfvars.example`, helper scripts, production-readiness guidance |

## Prerequisites

- **Azure CLI ≥ 2.86** logged in (`./azure-login.sh`), **Terraform ≥ 1.5**, and the **Anyscale CLI** for verification.
- **`kubectl` and `kubelogin`** — both required, unlike the `anyscale-on-azure` sibling where kubectl is optional. Automatic issues no admin certificate, so the bootstrap authenticates with an Entra token:
  ```bash
  az aks install-cli    # installs kubectl AND kubelogin
  ```
- A subscription with these resource providers registered. `Anyscale.Platform` is handled for you by `register_anyscale_resource_provider` (default true); the rest are not: `Anyscale.Platform`, `Microsoft.Authorization`, `Microsoft.ContainerRegistry`, `Microsoft.ContainerService`, `Microsoft.Insights`, `Microsoft.ManagedIdentity`, `Microsoft.Monitor`, `Microsoft.Network`, `Microsoft.OperationalInsights`, `Microsoft.PolicyInsights`, `Microsoft.Resources`, `Microsoft.Storage`
  (`az provider register --namespace <name>`; the azurerm provider is configured with `resource_provider_registrations = "none"`).
  `Microsoft.PolicyInsights` is the one the `anyscale-on-azure` sibling does not need — deployment safeguards depend on it.
- **The Anyscale.Platform subscription agreement** must be Active before `Anyscale.Platform/clouds` can be created. `accept_anyscale_platform_agreement` (default true) accepts it for you — read that variable's description in `variables.tf` first, since it gives marketplace consent non-interactively. To handle it yourself, set the variable to false and run:
  ```bash
  az rest --method POST \
    --url "https://management.azure.com/subscriptions/<sub>/providers/Anyscale.Platform/agreements/default/accept?api-version=2026-09-01"
  ```
  Either way, the cloud resource carries a precondition that fails with an actionable message rather than letting the RP reject the PUT mid-apply.
- A region in the Anyscale ∩ AKS-Automatic intersection — `./select-region.sh` scans quota and writes `azure_location` for you.
- The deploying principal needs `Azure Kubernetes Service RBAC Cluster Admin` on the cluster. **The stack self-assigns it** (`assign_current_principal_cluster_access`, default true), which requires permission to create role assignments — i.e. Owner or User Access Administrator on the resource group.
- **Required preview features.** The Gateway API surface is preview, and without both of these the gateway bootstrap fails with `no matches for kind "Gateway"`:
  ```bash
  az feature register --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview
  az feature register --namespace Microsoft.ContainerService --name AppRoutingIstioGatewayAPIPreview
  # wait for both to report Registered, then propagate:
  az provider register --namespace Microsoft.ContainerService
  ```
  Check with `az feature list --namespace Microsoft.ContainerService --query "[?contains(name,'GatewayAPI')].{name:name,state:properties.state}" -o table`. Registration is asynchronous.
- Only if you configure GPU NodePools:
  ```bash
  az feature register --namespace Microsoft.ContainerService --name ManagedGPUExperiencePreview
  az provider register --namespace Microsoft.ContainerService   # propagate
  ```

## Deploy

```bash
./azure-login.sh                 # ① authenticate + pick subscription
./select-region.sh               # ② quota-scan → write azure_location to terraform.tfvars
./select-gpu.sh                  # ③ optional: opt into GPU NodePools
cp terraform.tfvars.example terraform.tfvars   # fill in azure_subscription_id etc.

terraform init
terraform plan
terraform apply                  # ④ infra → cloud registration → gateway → operator
```

**Expect ~60 minutes for a cold apply.** Measured on a clean westus2 deploy: cluster create `8m30s`, ingress-profile reconcile `24m52s` (it installs the Gateway API CRDs — slow and unavoidable, and it ranged 16–25 min across runs), monitoring patch `5m9s`, gateway bootstrap `13s`, operator extension `17m3s`. `terraform destroy` takes ~15 min.

> **Region quota trap:** several Anyscale-supported regions default to a **total regional core limit of 10**, which is not enough for the AKS Automatic system pool — the cluster create fails late. `./select-region.sh` scans for this; check it before picking a region.

### Helper scripts

| Script | Purpose |
|---|---|
| `azure-login.sh` | Azure CLI sign-in and subscription selection |
| `select-region.sh` | Scan subscription quota across the supported regions and write `azure_location` |
| `select-gpu.sh` | Opt into GPU capacity by writing a `gpu_nodepool_configs` block |
| `scan-regional-quotas.sh` | Standalone CPU/GPU quota report (the engine behind `select-region.sh`) |
| `diagnose-head-pod.sh` | Post-deploy triage when a Ray head pod won't schedule |

### What the bootstrap does

`gateway.tf` renders `anyscale-namespace.yaml`, `anyscale-gateway.yaml`, and (when GPU is configured) `nvidia-nodepool.yaml` to disk — all gitignored — then runs one local-exec:

```
az aks get-credentials --file ./.kubeconfig     # isolated, never ~/.kube/config
kubelogin convert-kubeconfig -l azurecli        # Entra token from the existing az login
kubectl apply -f …                              # namespace → gateway → GPU NodePools
```

Between the namespace and the Gateway it **waits for the Gateway API CRDs and the `approuting-istio` GatewayClass to actually exist** (up to `gateway.api_ready_timeout_seconds`, default 20 min). The ingress-profile patch returns as soon as ARM accepts it, but the CRDs land in the cluster minutes later. `triggers_replace` keys on manifest *content*, so editing a listener re-applies on the next `terraform apply`.

> **If the bootstrap times out waiting for Gateway API CRDs**, check `az aks show … --query ingressProfile.gatewayApi`. If it's `null`, the two preview features above are not registered — no amount of retrying fixes that.

### Deterministic gateway hostname

The Gateway's `spec.infrastructure.annotations` carry `service.beta.kubernetes.io/azure-dns-label-name: <cldrsrc-id>`, so the load balancer's public hostname is known **at plan time**:

```
<cldrsrc-id-hyphenated>.<region>.cloudapp.azure.com
```

That hostname is baked directly into the operator extension's `networking.gateway.hostname` — no LB polling, no `az k8s-extension update` follow-up. (A polling fallback exists only behind `internal_gateway = true`, where a private LB IP must be read back from the Gateway status.)

## Feature switches

| Variable | Default | Effect |
|---|---|---|
| `enable_deployment_safeguards_exclusion` | `true` | Excludes the Anyscale namespace from Azure Policy enforcement. **Leave this on** — see below |
| `enable_monitoring` | `true` | Managed Prometheus + Container Insights + omsagent, applied as an azapi patch |
| `enable_otlp_app_insights` | `false` | App Insights OTLP endpoints + the cluster's appMonitoring profile (**preview**) |
| `internal_gateway` | `false` | Internal Standard LB — VNet-only data plane; falls back to LB polling |
| `api_server_authorized_ip_ranges` | `[]` | Narrow the public API server to known egress IPs. Must include wherever Terraform runs, or the bootstrap's `kubectl` is locked out |
| `enable_default_nginx_ingress_controller` | `false` | Keep app routing's nginx controller (a second public LB) alongside Istio |
| `enable_nfs` | `false` | Premium NFS FileStorage account locked to the node subnet |
| `enable_acr` | `true` | Customer-owned ACR + pull/push/tasks role assignments |
| `gpu_nodepool_configs` | `{}` | Karpenter GPU NodePools with AKS-managed drivers |
| `register_anyscale_resource_provider` | `true` | Registers the `Anyscale.Platform` RP on the subscription (one-time) |
| `accept_anyscale_platform_agreement` | `true` | Accepts the Anyscale.Platform subscription agreement (one-time). **Read the variable's description first** — Terraform gives marketplace consent on your behalf |
| `install_operator_extension` | `true` | `false` skips the AKS extension so you can `helm install` the operator yourself; the identity, federated credential and role assignments are created either way |

### Subscription onboarding

Identical to the `anyscale-on-azure` sibling. `Anyscale.Platform/clouds` cannot be created until the subscription has the resource provider registered **and** the Anyscale agreement accepted. Both are one-time, per-subscription, and both are on by default:

```
register_anyscale_resource_provider → az provider register --namespace Anyscale.Platform
accept_anyscale_platform_agreement  → POST Anyscale.Platform/agreements/default/accept
```

The agreement step checks current status first, accepts only if needed, then polls until `Active` (acceptance is not immediately consistent). Set either to `false` if your org does these centrally or requires human sign-off — the cloud resource carries a precondition that fails with the exact `az` command to run if the agreement still isn't `Active`.

Both API versions are pinned by `var.anyscale_platform` (`clouds_api_version`, `agreements_api_version`) and default to `2026-09-01`, the GA version.

### About deployment safeguards

AKS Automatic runs Azure Policy deployment safeguards at **Enforcement** level, which also applies the **baseline** Pod Security Standards through AKS-managed `ValidatingAdmissionPolicy` objects.

Exactly one of those policies blocks the Anyscale operator, confirmed on a real deploy by removing the exclusion and watching the Deployment go to zero pods:

```
ValidatingAdmissionPolicy 'aks-managed-baseline-privileged-containers' denied request:
Privileged init containers are disallowed
```

The privileged init container is `azwi-proxy-init` — **Microsoft's** workload-identity proxy, injected by the `azure.workload.identity/inject-proxy-sidecar` annotation on the operator chart, not something Anyscale ships. The Ray container additionally requests `SYS_PTRACE`, which is a baseline capability violation but not a privileged-container one.

Two things safeguards do **not** do here, despite the common shorthand:

- *Running as root* is a **restricted**-profile rule. Automatic enforces **baseline**, so it never applies.
- *Missing resource limits* are **mutated** to a default (500m / 2048Mi), not denied.

Without the exclusion patch, the operator's pods are denied at admission and the symptom is a Deployment stuck at `0/1` replicas, not an obvious policy error.

**The exclusion is broader than the problem, and that is an AKS limitation.** `excludedNamespaces` is all-or-nothing per namespace: exempting `anyscale-operator` exempts it from all ~20 enforcing policies, even though only two containers violate only two of them. There is no way to exempt just the privileged-containers policy and keep the other eleven. The safeguards **level** is deliberately not a variable — Microsoft documents changing it cluster-wide as unsupported on Automatic, so namespace exclusion is the only supported lever. If a real workload turns up rejections in another namespace, widen `deployment_safeguards_excluded_namespaces`.

## Verify

```bash
az aks get-credentials -g $(terraform output -raw azure_resource_group_name) \
                       -n $(terraform output -raw azure_aks_cluster_name)
kubelogin convert-kubeconfig -l azurecli      # required — no local accounts

kubectl get nodes                             # managed system pool Ready
kubectl get po -n anyscale-operator           # operator Running ← the safeguards test
kubectl get gateway -n anyscale-operator      # Programmed once the operator mints the TLS secrets

export ANYSCALE_HOST=https://console.azure.anyscale.com
anyscale login
anyscale cloud list                           # the cloud should appear

# End-to-end: proves the operator was admitted AND Karpenter provisions on demand.
cd sample-workload
anyscale job submit -f job.yaml \
  --cloud "$(cd .. && terraform output -raw anyscale_cloud_cli_name)" --wait
```

The workload fans out slot-holding tasks that the head pod cannot drain alone, then compares the hostnames that ran them against the head's own. It **exits non-zero if nothing ran off-head**, so a green run is real evidence of scale-out rather than a claim about it. Expect it to take a few minutes: a real deploy went Nominated → NodeReady in 46s, and the fan-out deliberately outlasts that.

> **The `--cloud` value is not the cloud's Azure name.** The Anyscale control plane registers the cloud under its **full ARM resource ID, lowercased** — so `--cloud anyscale-auto-t1-cloud` fails with `API Exception (404) ... "Cloud with name ... does not exist."` Use the `anyscale_cloud_cli_name` output, which renders the correct value. Note also that `anyscale_cloud_resource_id` (`cldrsrc_…`) and the CLI's cloud ID (`cld_…`) are **different identifiers**; `anyscale cloud list` shows the `cld_…` one.

The Gateway's HTTPS listeners report `Programmed=False` until the Anyscale operator creates the TLS Secrets they reference. That is expected immediately after apply — the load balancer and its DNS label are allocated as soon as the Gateway exists, which is what the extension needs.

A summary of every ID you need lands in `anyscale-aks-cloud.yaml` (gitignored) after apply. If a workspace pod won't schedule, run `./diagnose-head-pod.sh`.

## Destroy

```bash
terraform destroy
```

Destroy ordering is handled automatically: a destroy-time hook deletes the Anyscale cloud (child `cloudResources` first, retrying while the control plane drains sessions) **while the operator is still installed**, before the extension and cluster are torn down — otherwise the Anyscale RP returns 409 and wedges the resource group. Upstream `awesome-aks` has no equivalent and does wedge.

## Production readiness

This example optimizes for a fast, single-command first deploy. AKS Automatic already covers several things the `anyscale-on-azure` sibling leaves to you — Entra-only cluster auth, node auto-upgrade and OS patching, Azure Policy, a Standard-tier SLA — so the remaining gap is narrower. Before running real workloads:

| Evaluation default | Hardening step |
|---|---|
| Public AKS API server | `api_server_authorized_ip_ranges` (include your egress IP). A fully private API server is **out of scope here** — the bootstrap needs data-plane reach; a private-API-server variant is tracked separately and is not in this repo yet |
| Public gateway LB | `internal_gateway = true` (VNet-only data plane) |
| Public storage / ACR endpoints | Private endpoints; ACR needs `acr_sku = "Premium"` |
| Anyscale namespace excluded from safeguards | Cannot be narrowed further — `excludedNamespaces` is all-or-nothing per namespace (see [About deployment safeguards](#about-deployment-safeguards)). Keep the namespace list short, and audit workload pods against the safeguards rules yourself since admission no longer does it for you |
| Local Terraform state | Remote backend (e.g. the `azurerm` backend with a state storage account) |
| LRS storage, single zone | ZRS/GRS replication; Karpenter NodePools with zone spread requirements |
| No NetworkPolicy objects | Cilium is enforcing-capable out of the box — write policies for the Anyscale namespace |

## Known risks

- `azurerm_kubernetes_automatic_cluster` is a recent addition. If it proves unreliable, the fallback is upstream's raw `azapi_resource … managedClusters` body — everything downstream reads through locals, so only `aks.tf` changes.
- The managed-GPU experience, the App Insights OTLP API, and the Gateway API surface are preview. The Anyscale.Platform `clouds`, `clouds/cloudResources` and `agreements` APIs default to **GA `2026-09-01`**, exercised against a real apply. API versions stay variables (`deployment_safeguards_api_version`, `anyscale_platform.clouds_api_version`, `anyscale_platform.agreements_api_version`) because they will keep moving.
- The default nginx ingress controller is created during cluster creation and removed by a patch immediately after, so a first apply briefly allocates a public IP that is then deleted.

## License

Apache License 2.0 — see [`LICENSE`](../../../LICENSE) and [`NOTICE`](../../../NOTICE). This deployment is derived from and adapts two upstream examples: [anyscale/terraform-kubernetes-anyscale-foundation-modules](https://github.com/anyscale/terraform-kubernetes-anyscale-foundation-modules) (Apache 2.0) and [pauldotyu/awesome-aks](https://github.com/pauldotyu/awesome-aks) (MIT).
