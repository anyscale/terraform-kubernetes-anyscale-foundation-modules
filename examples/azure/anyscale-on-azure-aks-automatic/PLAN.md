# Plan — `anyscale-on-azure-aks-automatic`

Status: **implemented and verified end to end** against a real subscription
(westus2, 2026-07-26/27): `terraform apply` → operator Running → `terraform destroy` with
no orphans. See "Verification results" below.

Deviations from the plan as written, discovered while implementing:

- **`default_nginx_controller = "None"` is not accepted by the typed resource** — its schema
  only allows `AnnotationControlled` / `Internal` / `External`. Turning the nginx controller
  off entirely needs a third azapi patch (`app_routing` in `aks.tf`), so the count is
  three patches, not two.
- **`azapi_update_resource` has no `schema_validation_enabled` argument** (that is
  `azapi_resource` only), so the deployment-safeguards patch omits it.
- **Terraform has no user-defined functions**, so `gpu.tf` flattens on-demand/spot into a
  `gpu_nodepool_variants` list rather than calling a shared NodePool builder.
- `select-gpu.sh`'s existing object schema (`name`/`vm_size`/`product_name`/`gpu_count`) was
  already what the NodePool CRs need, so it is a `sed` rename plus wording, not a rewrite.
  `gpu_nodepool_configs` adds `enable_spot`, `max_gpus`, `image_family`, `os_disk_size_gb`.
- Added beyond the plan: `api_server_authorized_ip_ranges`,
  `aks_cluster_admin_principal_ids`, `enable_default_nginx_ingress_controller`,
  `deployment_safeguards_level`, `deployment_safeguards_api_version`,
  `gateway.api_ready_timeout_seconds`.

---

## Verification results (westus2, 2026-07-26/27)

Four bugs surfaced only under a real apply and a real workload. All four would have hit any
first-time user.

| # | Bug | Symptom | Fix |
|---|---|---|---|
| 1 | `deploymentSafeguards` addressed as a child of `managedClusters` | 404 on an otherwise correct PATCH | It is an **extension** resource: `<cluster-id>/providers/Microsoft.ContainerService/deploymentSafeguards/default`. Also moved to the GA `2025-07-01` API |
| 2 | `ingressProfile.gatewayAPI.installation` never set | `no matches for kind "Gateway"` — **`web_app_routing_ingress { istio_enabled = true }` does NOT install the Gateway API CRDs**, it only configures the Istio implementation. `gatewayApi` stayed `null` through an 18m reconcile | Folded `gatewayAPI.installation = "Standard"` into the ingress patch; made the bootstrap `depends_on` it (it was racing) and wait for the CRDs + GatewayClass instead of blind-retrying |
| 3 | `app_routing` and `monitoring` both PATCH the same managedCluster | `409 EtagMismatch` — ARM allows no concurrent cluster writes, and nothing in the graph ordered them | `depends_on` purely to serialize. **Any future cluster patch must join this chain** |
| 4 | `--cloud` documented as `anyscale_cloud_name` | `API Exception (404) ... "Cloud with name anyscale-auto-t1-cloud does not exist."` The control plane registers the cloud under its **full lowercased ARM resource ID** | Added the `anyscale_cloud_cli_name` output (`lower(arm_id)`); fixed README and `job.yaml`. Also note `cldrsrc_…` (cloud resource ID) and `cld_…` (CLI cloud ID) are different identifiers — the original `anyscale cloud verify --id` line conflated them |

Bug 2 is the instructive one: blind retries could not distinguish "still reconciling" from
"this field was never set", so the failure read as a timing flake for two full applies. The
bootstrap now waits on the specific object and prints the `ingressProfile.gatewayApi` check
on timeout.

Confirmed working on real infrastructure:

- Typed `azurerm_kubernetes_automatic_cluster` with 3-subnet BYO VNet and UserAssigned identity.
- Entra-only auth: `az aks get-credentials` + `kubelogin convert-kubeconfig -l azurecli`.
- Deployment-safeguards exclusion — operator `3/3 Running` for 9h, no restarts. **This is the
  single most likely thing to break on Automatic and it is invisible without the exclusion.**
- **Deterministic hostname**, the riskiest port (annotation moved from `EnvoyProxy` to the
  Gateway's `spec.infrastructure.annotations`):
  `cldrsrc-2na19fk7le9dsnzct5lf5sppuw.westus2.cloudapp.azure.com` → `20.252.59.31`, the LB.
- GPU `AKSNodeClass` + `NodePool` accepted by Karpenter, both `Ready`.
- Monitoring patch: `omsagent`/`metrics`/`containerInsights` all true, `ama-logs` Running.
- **Destroy**: pre-delete hook deleted the cloud in 11s with zero retries, then
  `Destroy complete! Resources: 45 destroyed` — no 409 wedge, no orphaned RG or node RG.

Timings varied across runs — the ingress-profile reconcile ranged **16–25 min**. See the
cold-path table below for the authoritative numbers. A cold apply is roughly an hour, not
the 20–35 min the first draft of the README implied.

### Cold-path run (the authoritative one)

The fixes above were each verified as they were added, but on a partly-built cluster.
A final run from zero — empty Azure, empty state, all fixes in place from the start —
produced `Apply complete! Resources: 45 added, 0 changed, 0 destroyed` with **zero errors**
and zero `409`s. That is the run these numbers come from:

| Resource | Cold-path duration |
|---|---|
| `azurerm_kubernetes_automatic_cluster.aks` | 8m30s |
| `azapi_update_resource.app_routing` | 24m52s |
| `azapi_update_resource.monitoring` | 5m9s (serialized behind app_routing — bug 3's fix under real contention) |
| `terraform_data.cluster_bootstrap` | 13s (CRDs already present — bug 2's fix working) |
| `azurerm_kubernetes_cluster_extension.anyscale_operator` | 17m3s |

Ray workload: `anyscale job submit -f sample-workload/job.yaml` reached **SUCCEEDED in 2m40s**,
and Karpenter provisioned `aks-default-6w8g9` (`Standard_D4as_v6`) from the built-in `default`
NodePool to host it — so on-demand provisioning is proven, not just the NodePool manifests.

### Still not verified

- **GPU drivers.** The `gput4` NodePool and AKSNodeClass go `Ready`, and Karpenter provisions
  CPU nodes on demand, but no GPU node was ever provisioned: the smoke test's GPU branch needs
  a CUDA-capable image (`RUN_GPU_CHECK=1` plus an `image_uri`), which this run did not build.
  The `EnableManagedGPUExperience` tag path is therefore still unproven end to end.
- `internal_gateway = true`, `enable_nfs`, `enable_otlp_app_insights` — all left at defaults.
  `internal_gateway` in particular is inherited from the `new-aks` sibling and has a known
  gap here: it registers a private LB IP but this example creates no private DNS zones for
  the `*.i/*.s.azure.anyscaleuserdata.com` wildcards that `private-aks` considered necessary.
- Only one region (westus2) and one GPU SKU (T4). Note that eastus2/westus3/southcentralus
  had a **total regional core limit of 10** on the test subscription — too small for the
  Automatic system pool, which is a quota trap worth checking before picking a region.
- Spot: westus2 `lowPriorityCores` limit was 3, too small for a 16-vCPU spot node, so
  `enable_spot = false` throughout. The spot NodePool rendering is unit-verified but never
  applied to a cluster.

## Context

Three Anyscale-on-Azure Terraform stacks exist today, and none of them is an AKS **Automatic** variant
carrying the quality bar of the Anyscale reference example:

| Stack | What it is |
|---|---|
| [`pauldotyu/awesome-aks` → `2026-07-15-anyscale-on-aks-automatic`](https://github.com/pauldotyu/awesome-aks/tree/main/2026-07-15-anyscale-on-aks-automatic) | Upstream demo. AKS Automatic, ~950 lines of HCL, hardcoded names, manual `kubectl apply` of the gateway, no destroy handling. |
| `examples/azure/anyscale-on-azure-new-aks` (this repo) | The polished reference. **Standard** AKS, one-apply UX, BYO VNet, feature switches, helper scripts, destroy-ordering hook, production-readiness guidance. |
| `AKS-Anyscale-Private-Cluster-Sample` | The private/hardened lab built on top of the reference. |

The goal is a fourth stack: **the `new-aks` example re-cut onto AKS Automatic**, living beside its
siblings so all three can be compared directly. Automatic removes a large chunk of what `new-aks`
configures by hand (node pools, Envoy Gateway, GPU operator, the NAP toggle) and imposes constraints of
its own (Entra-only cluster auth, enforced deployment safeguards, a delegated API-server subnet). This is
a re-cut, not a copy.

---

## Part 1 — Comparison

### `anyscale-on-azure-new-aks` (Standard) vs. this example (Automatic)

| Concern | `anyscale-on-azure-new-aks` | `anyscale-on-azure-aks-automatic` |
|---|---|---|
| Cluster resource | `azurerm_kubernetes_cluster`, SKU Free/Standard | `azurerm_kubernetes_automatic_cluster` (azurerm **≥ 4.81.0**, released 2026-07-14) |
| Compute | 5 hand-managed pools: `sys`, `cpu16`, `cpu16spot`, `gpu×N`, `gpuspot×N` | **Karpenter/NAP only.** Managed system pool + default NodePool are built in; we add GPU/spot `NodePool` + `AKSNodeClass` CRs |
| GPU drivers | NVIDIA GPU operator Helm chart (default) or `gpu_driver = "Install"` | AKS-managed drivers via the `EnableManagedGPUExperience` tag on the `AKSNodeClass` (needs `ManagedGPUExperiencePreview`) |
| Ingress | Envoy Gateway Helm release + `EnvoyProxy` + `GatewayClass eg` | Built-in app-routing **Istio**, `gatewayClassName: approuting-istio` — no Helm release, no GatewayClass to create |
| Networking | Azure CNI overlay + Cilium configured explicitly; **1** node subnet | Overlay + Cilium are Automatic's defaults; BYO VNet requires **3** subnets — API server (delegated to `Microsoft.ContainerService/managedClusters`, ≥ /28), user node, system node |
| Cluster identity | `SystemAssigned` | **`UserAssigned`** (required for BYO VNet) + `Network Contributor` on the VNet |
| Cluster auth | Local admin certs from `kube_config` drive the helm/kubernetes/kubectl providers | Local accounts disabled, Entra RBAC enforced → `kubelogin` + an `Azure Kubernetes Service RBAC Cluster Admin` assignment |
| In-cluster apply | Terraform providers (`kubectl_manifest`, `helm_release`) | Rendered YAML + a `terraform_data` local-exec `kubectl apply` |
| Policy | none | Azure Policy + **deployment safeguards in Enforcement** → the Anyscale namespaces must be excluded or the operator's pods are rejected at admission |
| Monitoring | `oms_agent` / `monitor_metrics` blocks on the typed resource | Typed resource exposes no monitoring blocks → `azapi_update_resource` patch |
| Regions | Anyscale-supported list (12) | Anyscale ∩ Automatic-GA: `eastus`, `eastus2`, `westus2`, `westus3`, `southcentralus`, `westeurope`, `swedencentral`, `uksouth`, `australiaeast`, `southeastasia`, `northeurope` — **`westcentralus` drops out** |
| Unchanged | Anyscale cloud + `cloudResources` via azapi, operator extension on workload identity, deterministic `<cldrsrc-id>.<region>.cloudapp.azure.com` hostname, storage / ACR / identity / prometheus | same |

### Upstream `awesome-aks` automatic vs. this example

**Kept from upstream:** AKS Automatic itself, the `approuting-istio` gateway class, the DNS-label hostname
trick, the deployment-safeguards namespace exclusion, the managed-GPU `AKSNodeClass`, and `sample-workload/`.

**Added on top:**

- Variables instead of hardcoded `anyscale<NN>` names.
- BYO VNet (upstream uses the managed network).
- Feature switches (`enable_monitoring`, `enable_otlp_app_insights`, `enable_nfs`, `enable_acr`, `internal_gateway`).
- Single-apply gateway bootstrap — upstream stops at writing `anyscale-gateway.yaml` and tells you to apply it.
- The destroy-time cloud pre-delete hook. Upstream `terraform destroy` wedges: the operator extension is
  torn down first, and the Anyscale RP then returns 409 on the cloud delete.
- Anyscale Platform role self-grant (subscription Owner does *not* carry over to the Anyscale RP).
- `terraform.tfvars.example`, helper scripts, and the production-readiness table.
- Typed `azurerm_kubernetes_automatic_cluster` instead of a raw azapi body.
- Single-region default. Upstream splits `location` (`switzerlandnorth`) from `anyscale_cloud_location`
  (`eastus`); we keep that split available as an override but default both to one region.

---

## Part 2 — Implementation

**Location:** `examples/azure/anyscale-on-azure-aks-automatic/`

### Key design decisions

1. **Typed cluster resource.** `azurerm_kubernetes_automatic_cluster` covers `hosted_system`
   (`node_subnet_id` + `system_node_subnet_id`), `api_server_access.subnet_id`, `private_cluster`, and
   `web_app_routing_ingress { istio_enabled = true }`. This preserves the `new-aks` philosophy — typed GA
   resource, azapi only for what the schema can't reach. Upstream used a raw azapi body because the typed
   resource did not exist yet.
   *Fallback:* if 4.81.0 proves flaky, swap in upstream's
   `azapi_resource … managedClusters@2026-05-02-preview` body — everything downstream reads through
   locals, so only `aks.tf` changes.
2. **Two azapi patches** on top of the typed cluster:
   - monitoring profile — `addonProfiles.omsagent` + `azureMonitorProfile.metrics` /
     `.containerInsights` / (optional) `.appMonitoring` OTLP;
   - `Microsoft.ContainerService/deploymentSafeguards@2025-05-02-preview` → `excludedNamespaces`.
3. **Kubelet identity is not exported** by the typed resource (attributes are `identity`, `kube_config`,
   `oidc_issuer_url`, `node_resource_group_id`, FQDNs). Read it with a `data "azapi_resource"` on the
   cluster ID with `response_export_values = ["properties.identityProfile"]` to wire the `AcrPull`
   assignment that `acr.tf` currently gets from `kubelet_identity[0].object_id`.
4. **In-cluster bootstrap.** `templatefile` renders YAML to disk, then one `terraform_data` local-exec:
   `az aks get-credentials --file ./.kubeconfig` → `kubelogin convert-kubeconfig -l azurecli` →
   `kubectl apply` for namespace, then gateway, then GPU NodePools. Isolated kubeconfig, gitignored,
   never touches `~/.kube/config`. `triggers_replace` keyed on the rendered manifest contents so edits
   re-apply.
5. **GPU via NAP.** `gpu_nodepool_configs` (map, empty by default) renders `AKSNodeClass` + `NodePool` CRs
   carrying the Anyscale taints (`nvidia.com/gpu=present`, `node.anyscale.com/accelerator-type=GPU`,
   `node.anyscale.com/capacity-type`) that the operator's existing
   `anyscale_extension_configuration_defaults` tolerations in `anyscale.tf` already match. Optional spot
   NodePool per entry. CPU capacity comes from Automatic's built-in default NodePool — no CPU pools to define.
6. **Dropped from `new-aks`:** `gpu.tf`'s GPU-operator Helm release and its toleration block, every
   `azurerm_kubernetes_cluster_node_pool`, the `helm` / `kubernetes` / `kubectl` providers, and the
   `enable_node_auto_provisioning`, `gpu_driver_mode`, `gpu_operator_chart_version`, `nap_gpu_sku_name`,
   `system_vm_size`, `cpu_vm_size`, `envoy_gateway` variables. NAP is always on; drivers are always
   AKS-managed.

### File-by-file

| File | Source | Work |
|---|---|---|
| `versions.tf` | `new-aks` | azurerm `>= 4.81.0, < 5.0.0`; keep azapi, random, local, external. Delete the helm / kubernetes / kubectl provider blocks (they authenticate with certs that Automatic does not issue) |
| `main.tf` | `new-aks` | Keep RG, `random_string` suffix + name locals, storage account (HNS + CORS + container), optional NFS. **Rewrite the network section:** 3 subnets — `apiserver` (delegated, `/28`), `nodes`, `systemnodes` — plus a cluster UAMI and `Network Contributor` on the VNet. NFS `network_rules` point at the `nodes` subnet as before |
| `aks.tf` | rewrite | Typed automatic cluster; the two azapi patches; the azapi data read for kubelet identity; `Azure Kubernetes Service RBAC Cluster Admin` self-assignment so the bootstrap's `kubectl` is authorized |
| `gateway.tf` | rewrite | Render `anyscale-gateway.yaml` — namespace + `Gateway` on `approuting-istio`, 3 listeners (HTTP, `*.i.…`, `*.s.…`), DNS-label annotation under `spec.infrastructure.annotations` (upstream's placement; `new-aks` puts it on the `EnvoyProxy`). Plus the bootstrap local-exec. Keep the `internal_gateway` LB-polling path from `new-aks` — the `kubectl` machinery is already present |
| `gpu.tf` | rewrite | Render `nvidia-nodepool.yaml` from `gpu_nodepool_configs` |
| `anyscale.tf` | `new-aks`, near-verbatim | Change `networking.gateway.className` → `approuting-istio`; `depends_on` the bootstrap instead of `kubectl_manifest.gateway`. Keep cloud + `cloudResources`, contributor grants, self-grant, and the **pre-delete destroy hook** unchanged |
| `acr.tf` | `new-aks` | Copy; repoint `kubelet_acr_pull` at the azapi-read kubelet object ID |
| `identity.tf` | `new-aks` | Copy; `issuer` comes from the automatic cluster's `oidc_issuer_url` |
| `monitoring.tf`, `prometheus.tf` | `new-aks` | Copy as-is; retarget the cluster reference in the Prometheus DCR association |
| `variables.tf` | `new-aks` | Prune the six variables listed in decision 6. Add `apiserver_subnet_cidr`, `system_nodes_subnet_cidr`, `gpu_nodepool_configs`, `deployment_safeguards_excluded_namespaces`, `anyscale_cloud_location`. Narrow the `azure_location` validation list to the Anyscale ∩ Automatic-GA intersection |
| `outputs.tf` | `new-aks` + upstream | Keep all; add the OTLP endpoints (upstream has them as top-level outputs) and the gateway hostname. Keep the `anyscale-aks-cloud.yaml` summary file |
| `README.md` | new | Both comparison tables above + prereqs, deploy, verify, destroy, production-readiness |
| `terraform.tfvars.example`, `.gitignore` | `new-aks` | `.gitignore` adds the rendered `anyscale-gateway.yaml` / `nvidia-nodepool.yaml` |
| `azure-login.sh`, `select-region.sh`, `select-gpu.sh`, `diagnose-head-pod.sh` | `new-aks` | Copy. `select-region.sh` region list → the intersection; `select-gpu.sh` writes `gpu_nodepool_configs` instead of `gpu_pool_configs` |
| `sample-workload/{job.yaml,main.py}` | upstream | Copy |

### New prerequisites to document

- `kubelogin` (`az aks install-cli` installs both it and `kubectl`).
- Azure CLI ≥ 2.86.
- `Microsoft.PolicyInsights` registered, on top of the providers `new-aks` already lists.
- `ManagedGPUExperiencePreview` registered when using GPU NodePools.
- The deploying principal needs `Azure Kubernetes Service RBAC Cluster Admin` — the stack self-assigns it.

## Verification

1. `terraform fmt -check` and `terraform init && terraform validate`.
2. `terraform plan` against a real subscription with `azure_location = "eastus2"` — confirm
   `networking.gateway.hostname` is **not** `(known after apply)`, i.e. the deterministic-hostname trick
   survived the port.
3. `terraform apply`, then:
   - `kubectl get nodes` — managed system pool Ready.
   - `kubectl get po -n anyscale-operator` — operator Running. This is the real test of the
     deployment-safeguards exclusion; without it admission rejects the operator's pods.
   - `kubectl get gateway -n anyscale-operator` — Programmed once the operator mints the TLS secrets.
   - `anyscale cloud verify --id $(terraform output -raw anyscale_cloud_id)` with
     `ANYSCALE_HOST=https://console.azure.anyscale.com`.
   - `anyscale job submit -f sample-workload/job.yaml --cloud <name> --wait`. With a GPU NodePool
     configured this also proves NAP provisions a GPU node with AKS-managed drivers.
4. `terraform destroy` — must finish without the 409 wedge, proving the pre-delete hook carried over.

## Risks

- `azurerm_kubernetes_automatic_cluster` is one release old. Fallback documented in decision 1.
- Deployment safeguards may reject Anyscale *workload* pods, not just the operator's. The excluded-namespace
  list is a variable so it can be widened after the first real workload run.
- Anyscale on Azure, managed GPU, and OTLP App Insights are all preview surface; the region intersection
  and API versions will move.
