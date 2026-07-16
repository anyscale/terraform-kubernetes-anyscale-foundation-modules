# Anyscale on AKS — Reference Deployment

One `terraform apply` stands up a new AKS cluster and registers it as an **Anyscale cloud on the Azure-hosted control plane** (`https://console.azure.anyscale.com`) — infrastructure, cloud registration, operator, and gateway in a single pass.

The default path uses only **GA Azure surface**. Preview features (managed GPU drivers, node auto-provisioning, App Insights OTLP) are strictly opt-in flags.

## What gets deployed

| Type | Resource | File |
|---|---|---|
| Azure infra | Resource group, VNet, AKS node subnet (`Microsoft.Storage` service endpoint) | `main.tf` |
| Azure infra | Storage account (**HNS / ADLS Gen2**, TLS 1.2, OAuth-default) + private blob container; optional Premium NFS account | `main.tf` |
| Azure infra | AKS cluster — Azure CNI **overlay + Cilium**, workload identity, system pool; CPU on-demand/spot pools; opt-in GPU on-demand/spot pools | `aks.tf` |
| Azure infra | User-assigned identity + federated credential + `Storage Blob Data Contributor` | `identity.tf` |
| Azure infra | ACR + kubelet `AcrPull` + operator `AcrPush` / `Container Registry Tasks Contributor` (image builder) | `acr.tf` |
| Anyscale | `Anyscale.Platform/clouds` + `clouds/cloudResources/default` (native azapi) | `anyscale.tf` |
| Anyscale | `Anyscale.AKS.Operator` marketplace extension (Entra workload-identity auth) | `anyscale.tf` |
| In-cluster | Envoy Gateway Helm release + `EnvoyProxy` (public LB with **deterministic DNS label**) + `GatewayClass eg` + 3-listener `Gateway` | `gateway.tf` |
| In-cluster | NVIDIA GPU operator (default `gpu_driver_mode = "operator"`, only when GPU pools exist) | `gpu.tf` |
| Observability | Azure Monitor workspace + managed Prometheus DCE/DCR/recording rules; Log Analytics + Container Insights (`enable_monitoring`, default on) | `monitoring.tf`, `prometheus.tf` |

### Deterministic gateway hostname

The gateway's LB service carries `service.beta.kubernetes.io/azure-dns-label-name: <cldrsrc-id>`, so its public hostname is known **at plan time**:

```
<cldrsrc-id-hyphenated>.<region>.cloudapp.azure.com
```

That hostname is baked directly into the operator extension's `networking.gateway.hostname` — no LB polling, no isolated kubeconfig, no `az k8s-extension update` follow-up. (A polling fallback exists only behind `internal_gateway = true`, where a private LB IP must be read back from the Gateway status.)

## Feature switches

| Variable | Default | Effect |
|---|---|---|
| `enable_monitoring` | `true` | Managed Prometheus + Container Insights + omsagent addon (GA) |
| `enable_otlp_app_insights` | `false` | App Insights OTLP logs/metrics/traces endpoints (**preview** API) |
| `gpu_driver_mode` | `"operator"` | `"operator"` = NVIDIA GPU operator chart (GA); `"managed"` = AKS-installed drivers (requires the `ManagedGPUExperiencePreview` feature) |
| `enable_node_auto_provisioning` | `false` | NAP / managed Karpenter via azapi patch + GPU NodePool (**preview**; needs `NodeAutoProvisioningPreview`) |
| `internal_gateway` | `false` | Internal Standard LB — VNet-only data plane; falls back to LB polling |
| `enable_nfs` | `false` | Premium NFS FileStorage account locked to the node subnet |
| `enable_acr` | `true` | Customer-owned ACR + pull/push/tasks role assignments |

## Prerequisites

- **Azure CLI** logged in (`./azure-login.sh`), **Terraform >= 1.5**, **kubectl** (only needed for `internal_gateway = true`), and the **Anyscale CLI** for verification.
- A subscription with these resource providers registered: `Anyscale.Platform`, `Microsoft.Authorization`, `Microsoft.ContainerRegistry`, `Microsoft.ContainerService`, `Microsoft.Insights`, `Microsoft.ManagedIdentity`, `Microsoft.Monitor`, `Microsoft.Network`, `Microsoft.OperationalInsights`, `Microsoft.Resources`, `Microsoft.Storage`
  (`az provider register --namespace <name>`; the azurerm provider is configured with `resource_provider_registrations = "none"`).
- An [Anyscale-supported region](https://learn.microsoft.com/azure/anyscale-on-azure/supported-regions) — `./select-region.sh` scans quota and writes `azure_location` for you.
- Preview features only if you opt in:
  ```bash
  az feature register --namespace Microsoft.ContainerService --name ManagedGPUExperiencePreview   # gpu_driver_mode = "managed"
  az feature register --namespace Microsoft.ContainerService --name NodeAutoProvisioningPreview   # enable_node_auto_provisioning = true
  ```

## Deploy

```bash
./azure-login.sh                 # ① authenticate + pick subscription
./select-region.sh               # ② quota-scan → write azure_location to terraform.tfvars
./select-gpu.sh                  # ③ optional: opt into GPU pools
cp terraform.tfvars.example terraform.tfvars   # fill in azure_subscription_id etc.

terraform init
terraform plan
terraform apply                  # ④ infra → cloud registration → operator + gateway, one apply
```

### Helper scripts

| Script | Purpose |
|---|---|
| `azure-login.sh` | Azure CLI sign-in and subscription selection |
| `select-region.sh` | Scan subscription quota across Anyscale-supported regions and write `azure_location` |
| `select-gpu.sh` | Opt into GPU pools by writing a `gpu_pool_configs` block (no GPU pools by default) |
| `scan-regional-quotas.sh` | Standalone CPU/GPU quota report (the engine behind `select-region.sh`) |
| `diagnose-head-pod.sh` | Post-deploy triage when a Ray head pod won't schedule |

## Verify

```bash
az aks get-credentials -g $(terraform output -raw azure_resource_group_name) \
                       -n $(terraform output -raw azure_aks_cluster_name)
kubectl get po -A                # operator + envoy-gateway pods Running

export ANYSCALE_HOST=https://console.azure.anyscale.com
anyscale login
anyscale cloud list              # the cloud from `terraform output anyscale_cloud_name`
```

A summary of every ID you need lands in `anyscale-aks-cloud.yaml` (gitignored) after apply. If a workspace pod won't schedule, run `./diagnose-head-pod.sh`.

## Destroy

```bash
terraform destroy
```

Destroy ordering is handled automatically: a destroy-time hook deletes the Anyscale cloud (child `cloudResources` first, retrying while the control plane drains sessions) **while the operator is still installed**, before the extension and cluster are torn down — otherwise the Anyscale RP returns 409 and wedges the resource group.

## Production readiness

This example optimizes for a fast, single-command first deploy. The BYO VNet (`main.tf`) is the prerequisite for the network-isolation steps below and is already in place. Before running real workloads:

| Evaluation default | Hardening step |
|---|---|
| Public AKS API server | `private_cluster_enabled = true` + private DNS zone (requires runner network line-of-sight), or at minimum `api_server_access_profile.authorized_ip_ranges` |
| Public gateway LB | `internal_gateway = true` (VNet-only data plane) |
| Public storage / ACR endpoints | Private endpoints; ACR needs `acr_sku = "Premium"` |
| Cluster-admin cert auth for in-cluster providers | Entra-only auth + `kubelogin` exec plugin; disable local accounts |
| Local Terraform state | Remote backend (e.g. the `azurerm` backend with a state storage account) |
| LRS storage, single zone, Free-tier AKS SLA | ZRS/GRS replication, zone-redundant pools, `sku_tier = "Standard"` |

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). This deployment is derived from and adapts two upstream examples: [anyscale/terraform-kubernetes-anyscale-foundation-modules](https://github.com/anyscale/terraform-kubernetes-anyscale-foundation-modules) (Apache 2.0) and [pauldotyu/awesome-aks](https://github.com/pauldotyu/awesome-aks) (MIT).
