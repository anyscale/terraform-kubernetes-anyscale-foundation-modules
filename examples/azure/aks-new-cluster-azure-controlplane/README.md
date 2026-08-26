# Anyscale on Azure

This is a step-by-step guide that deploys **Anyscale on Azure**. It deploys Azure Resources such as AKS, VNets, subnet and storage and adds two **Azure Resource Provider** integrations that make the cluster a managed Anyscale cloud:

1. **`Anyscale.Platform/clouds`** (deployed via `azapi_resource`) — registers the cloud with the Azure-hosted Anyscale control plane at `https://console.azure.anyscale.com` and produces a stable `cldrsrc_…` ID.
2. **`Microsoft.KubernetesConfiguration/extensions`** of type `Anyscale.AKS.Operator` (deployed via `azurerm_kubernetes_cluster_extension`) — installs the operator marketplace extension into the AKS cluster's `anyscale-operator` namespace, wired to the cloud above.

3. **Envoy Gateway** (Helm chart + `EnvoyProxy` + `GatewayClass` + `Gateway`) that the operator routes workspace and service traffic through — matching the upstream Anyscale-on-AKS quickstart.

After the apply finishes, the cloud is visible at `https://console.azure.anyscale.com` under the cloud name you chose.

> **Scope:** this example optimizes for a fast, single-command first deploy — local Terraform state, AKS Free tier, a single zone, a public API server, and a public gateway LB. That's ideal for evaluation but **not** a production posture. Before you run real workloads, work through [Production readiness](#production-readiness), which maps each default to the variable or file that hardens it.

## What this guide deploys

| Type | Resource | Created by |
|---|---|---|
| Azure infra | Resource group, VNet, AKS subnet | `main.tf` |
| Azure infra | Storage account + blob container | `main.tf` |
| Azure infra | AKS cluster  | `aks.tf` |
| Azure infra | User-assigned managed identity, federated credential, `Storage Blob Data Contributor` role assignment | `aks.tf` |
| Azure infra | Azure Container Registry + kubelet `AcrPull` role assignment | `acr.tf` |
| Anyscale | `Anyscale.Platform/clouds` ARM deployment via AzAPI | `anyscale.tf` |
| Anyscale | `Anyscale.AKS.Operator` AKS extension | `anyscale.tf` |
| In-cluster | Envoy Gateway Helm release (v1.7.0) | `envoy-gateway.tf` |
| In-cluster | `EnvoyProxy` + `GatewayClass eg` + `Gateway` with TLS Secrets named from the cloud resource ID | `envoy-gateway.tf` |

## Repository layout

```
aks-new-cluster-azure-controlplane/
├── README.md                    # this guide
│
├── azure-login.sh               # ① az login + set subscription
├── select-region.sh             # ② scan quota → pick a supported region → write terraform.tfvars
├── select-gpu.sh                # ③ (optional) opt into GPU node pools → write terraform.tfvars
├── scan-regional-quotas.sh      #   shared quota-scan library (called by ② and ③, not run on its own)
│
├── versions.tf                  # provider versions + in-cluster (kubernetes/helm) provider auth
├── variables.tf                 # all inputs + validation (region, VM sizes, CIDRs, GPU pools…)
├── terraform.tfvars.example     # template — copy to terraform.tfvars
├── terraform.tfvars             # your values (gitignored); seeded by the helper scripts
├── main.tf                      # resource group, VNet, AKS subnet, storage account + blob container
├── aks.tf                       # AKS cluster, system/CPU/GPU node pools, UAMI + federated cred + role
├── acr.tf                       # Azure Container Registry + kubelet AcrPull role
├── anyscale.tf                  # Anyscale.Platform/clouds + Anyscale.AKS.Operator extension
├── envoy-gateway.tf             # Envoy Gateway Helm release + EnvoyProxy + GatewayClass + Gateway
├── outputs.tf                   # cloud name/ID, gateway LB hostname, kubeconfig command; writes anyscale-aks-cloud.yaml
│
├── diagnose-head-pod.sh         # post-deploy troubleshooting: why won't a workload pod schedule?
│
└── anyscale-aks-cloud.yaml      # generated on apply — deployment summary (gitignored; embeds ARM IDs)
```

### Order of execution

The `.tf` files are **not** run by hand or in filename order — Terraform builds a dependency graph and a single `terraform apply` resolves the correct order itself (the intra-apply phases are listed under [Deploy](#deploy)). What you run, in sequence, is:

| # | Command | Purpose |
|---|---|---|
| 0 | `cp terraform.tfvars.example terraform.tfvars` | Create your local values file; fill in subscription ID, tenant ID, resource group, and cloud name |
| 1 | `./azure-login.sh` | Authenticate `az` and select the target subscription |
| 2 | `./select-region.sh` | Find a supported region with quota and write `azure_location` to `terraform.tfvars` |
| 3 | `./select-gpu.sh` *(optional)* | Opt into GPU pools; writes `gpu_pool_configs` to `terraform.tfvars` |
| 4 | `terraform init` | Download providers/modules |
| 5 | `terraform plan` | Preview the change set; review what will be created before committing |
| 6 | `terraform apply` | Provision Azure infra → register the Anyscale cloud → install the operator + gateway |
| 7 | `anyscale cloud verify` | Confirm the cloud is healthy (see [Verify](#verify)) |
| 8 | `./diagnose-head-pod.sh` *(only if needed)* | Capture scheduling/autoscaler reasons when a workload pod stays Pending |

### How it works

Step 0 seeds `terraform.tfvars` from the template (gitignored). Steps 1–3 are a pre-flight: they make sure you're pointed at the right subscription and that the region you pick actually has the CPU/GPU **quota** to host the pools `aks.tf` will create — the most common first-apply failure is choosing a region with no capacity. Steps 1–3 only edit `terraform.tfvars`; they create nothing.

Step 5 is the whole deployment in one command. Terraform stands up the Azure infrastructure, then uses the new cluster's admin credentials to register the managed Anyscale cloud (`anyscale.tf`) and wire up ingress (`envoy-gateway.tf`) — all ordered automatically by resource dependencies. After it finishes, the cloud appears at `https://console.azure.anyscale.com` and you verify it (step 6). Step 7 is reactive: run it only when a workspace/job won't start, to capture exactly why the Ray head pod can't be scheduled.

## Prerequisites

### Azure permissions

You need a Microsoft Entra account that can:

1. **Sign in** to the target tenant and subscription.
2. **Contribute** at the subscription (or target resource group) level — to create the resource group, networking, AKS, storage, identity, and role assignments.
3. **Create service principals from external Microsoft Entra tenants** (Cloud Application Administrator / Application Administrator / Global Administrator). This is needed once per tenant for the Anyscale control plane SP:
   ```bash
   az ad sp create --id 086bc555-6989-4362-ba30-fded273e432b
   ```
4. **Accept Azure Marketplace terms** for the Anyscale operator plan, once per subscription:
   ```bash
   az vm image terms accept \
     --publisher anyscale1750870039553 \
     --offer anyscale-operator-aks \
     --plan anyscale-operator
   ```

### Resource providers

```bash
for provider in \
  Anyscale.Platform \
  Microsoft.KubernetesConfiguration \
  Microsoft.ContainerService \
  Microsoft.ContainerRegistry \
  Microsoft.ManagedIdentity \
  Microsoft.Network \
  Microsoft.OperationalInsights \
  Microsoft.Resources \
  Microsoft.Storage \
  Microsoft.Authorization; do
  az provider register --namespace "$provider"
done
```

### Region

`var.azure_location` must be one of the regions where `Anyscale.Platform/clouds` is supported:

> `westcentralus`, `eastus`, `eastus2`, `westus2`, `westus3`, `southcentralus`, `westeurope`, `swedencentral`, `uksouth`, `australiaeast`, `southeastasia`, `northeurope`

Default is `westus2`. Older regions like `westus` are **not** supported by the Anyscale RP — `terraform plan`/`apply` rejects any other value via a validation on `azure_location`.

**Pick a region interactively.** Rather than guessing which supported region has capacity, run the helper script. It prints the supported regions, scans your subscription's CPU/GPU quota in each, lists only the deployable ones, and writes your choice into `terraform.tfvars`:

```bash
./azure-login.sh        # or: az login && az account set --subscription <id>
./select-region.sh      # informs → scans quota → prompts → writes azure_location

# Options:
./select-region.sh --detailed   # also print the full per-region quota report
./select-region.sh --no-write    # scan + choose only; don't edit terraform.tfvars
MIN_CPU_VCPUS=12 ./select-region.sh   # lower the deployable threshold
```

### Quota

- `Microsoft.ContainerService/managedClusters` quota of **at least 1** in the chosen region (default cap is 10 per region).
- VM family quota for `var.system_vm_size`, `var.cpu_vm_size`, and any `var.gpu_pool_configs` SKUs.

`./select-region.sh` checks regional vCPU and CPU-family headroom for you across the supported regions. For a standalone, full quota report (CPU + per-GPU-family across all or specific regions) use `./scan-regional-quotas.sh` directly — e.g. `NODE_VM_SIZE=Standard_D16s_v5 ./scan-regional-quotas.sh`.

Quota and capacity can also vary *within* a region. If only some availability zones can serve the VM sizes you picked, pin the pools with `node_pool_zones = ["3"]` (unset by default, which lets Azure place nodes without a zone constraint).

#### Worked example — minimum quota to try this out

The default `system_vm_size` (`Standard_D2s_v5`) and `cpu_vm_size` belong to the **DSv5** family, so both draw from the same *Standard DSv5 Family vCPUs* quota **and** the *Total Regional vCPUs* quota in your region. A minimal CPU-only deployment (no GPU pools) needs roughly:

| Pool | Sizing | vCPUs |
|------|--------|-------|
| System pool | autoscales 1–3 × `Standard_D2s_v5` (peak 3) | ~6 |
| CPU pool peak | e.g. 2 × `Standard_D8s_v5` | 16 |
| **Total DSv5 family** | minimum to launch a small workload | **~24** (32 for headroom) |

So make sure your region has at least **~24 vCPU free** in *both* the DSv5 family and Total Regional quotas before applying — `./select-region.sh` reports both. If quota is tight, shrink `cpu_vm_size` (e.g. `Standard_D4s_v5`) so the worker pool fits the free headroom.

> **Troubleshooting:** if a workspace/job stays stuck with `autoscaler ... Launching instances failed: could not launch any instances` and the cluster-autoscaler reports `Scale-up failed ... HTTPStatusCode: 409 ... OperationNotAllowed ... exceeding approved Total Regional Cores quota`, you are out of regional vCPU quota. Either request an increase (*Subscriptions → Usage + quotas* in the portal) or set a smaller `cpu_vm_size` and re-apply. Changing `cpu_vm_size` on an existing pool requires `temporary_name_for_rotation` (already set on the CPU pools in `aks.tf`); Terraform rotates the pool in place.

### GPU node pools (opt-in)

GPU pools are **not created by default** (`var.gpu_pool_configs` is empty). This is deliberate: hardcoding a GPU SKU like A100 makes `terraform apply` fail in any region/subscription that has no A100 quota or capacity — the most common first-apply error. The CPU and system pools always deploy.

**Pick a GPU type interactively.** Rather than guessing a SKU that may not exist in your region, run the helper. It asks which GPU type you want from the Anyscale-supported catalog — or, if you don't have one in mind, scans your chosen region for GPU SKUs that are **both available to your subscription AND have vCPU quota** — and writes the `gpu_pool_configs` block into `terraform.tfvars`:

```bash
./azure-login.sh        # or: az login && az account set --subscription <id>
./select-gpu.sh         # asks for a GPU type → or scans the region → writes tfvars

# Options:
./select-gpu.sh --scan              # jump straight to the region scan
./select-gpu.sh --region eastus2    # validate against a specific region
./select-gpu.sh --no-write          # choose only; don't edit terraform.tfvars
```

Each GPU type you select becomes one **on-demand** pool and one **spot** pool (autoscaling 0–10), defined by `azurerm_kubernetes_cluster_node_pool.gpu_ondemand`/`gpu_spot` in `aks.tf`. To set the pools by hand instead, populate `gpu_pool_configs` directly (see `terraform.tfvars.example`).

### Local tools

- Azure CLI (`az`) authenticated against the target tenant: `az login --tenant <tenant>`
- Terraform `>= 1.5.0`
- `kubectl`, `helm`, `bash` (Linux/macOS; WSL on Windows)

## Deploy

```bash
# From the example directory
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum: azure_subscription_id, azure_tenant_id,
# azure_resource_group_name, anyscale_cloud_name

terraform init
terraform plan     # preview the change set; optionally save it: terraform plan -out=tfplan
terraform apply    # or apply the saved plan exactly: terraform apply tfplan
```

`azure_resource_group_name` and `anyscale_cloud_name` have **no defaults**, so unless you supply them, `terraform apply` prompts for them at the start:

```
var.azure_resource_group_name
  Resource group name. ...
  Enter a value: my-rg

var.anyscale_cloud_name
  Anyscale cloud name as it appears in the Anyscale console. ...
  Enter a value: my-cloud
```

Press Enter on an empty value to fall back to `<aks_cluster_name>-rg` / `<aks_cluster_name>-cloud`. To skip the prompts (e.g. CI/automation), supply them non-interactively via `terraform.tfvars`, `-var`, or `TF_VAR_azure_resource_group_name` / `TF_VAR_anyscale_cloud_name` — a non-interactive `terraform apply -auto-approve` will **fail** if these aren't provided some other way.

That's it. Expect 15–20 minutes, dominated by AKS cluster creation (8 min) and the Anyscale extension reconciling the operator (~5 min). The apply orchestrates these phases automatically in a single command:

1. Resource group, VNet, storage, UAMI, federated credential, role assignment
2. AKS cluster + node pools
3. The kubernetes/helm/kubectl providers authenticate directly from the AKS cluster's admin cert attributes (no kubeconfig file, no `az aks get-credentials` for the providers), so they connect to the freshly-created cluster within the same apply. `terraform_data.aks_credentials` additionally writes an isolated `./.kubeconfig` (gitignored) used only by the gateway-LB shell steps.
4. `azapi_resource.anyscale_platform` runs the ARM template, producing `cldrsrc_…`
5. Envoy Gateway Helm install → `EnvoyProxy` → `GatewayClass eg` → `Gateway` (HTTPS listeners reference TLS Secrets whose names are derived from `cldrsrc_…`; the Secrets don't exist yet — the operator will create them next)
6. `terraform_data.wait_for_gateway_lb` polls `kubectl get gateway gateway -n anyscale-operator -o jsonpath='{.status.addresses[0].value}'` until the Azure LB hostname appears
7. `azurerm_kubernetes_cluster_extension.anyscale_operator` installs the operator marketplace extension with `networking.gateway.hostname` set to the LB address from step 6. The operator authenticates via Microsoft Entra **workload identity** (no CLI token) and creates the TLS Secrets — at which point the Gateway listeners reconcile to `Programmed=True`.

After the apply, useful Terraform outputs:

```bash
terraform output anyscale_cloud_name          # the cloud as it appears in the console
terraform output anyscale_cloud_resource_id   # cldrsrc_…
terraform output gateway_lb_hostname          # the public LB IP
terraform output aks_get_credentials_command  # refresh kubeconfig manually
```

### Use an existing AKS cluster

By default this example creates the resource group, VNet, subnet, AKS cluster and node pools. To layer Anyscale onto a cluster you already run, set:

```hcl
create_aks_cluster        = false
existing_aks_cluster_name = "my-existing-aks"
azure_resource_group_name = "the-group-holding-that-cluster"
```

Everything else is unchanged — storage, ACR, the operator identity and federated credential, the Anyscale cloud, Envoy Gateway and the operator extension are all created against the adopted cluster.

**The cluster must already have:**

| Requirement | Why | Fix |
| --- | --- | --- |
| OIDC issuer enabled | The operator's federated identity credential federates against it | `az aks update -g <rg> -n <cluster> --enable-oidc-issuer --enable-workload-identity` |
| Microsoft Entra workload identity enabled | The operator authenticates to the control plane with a workload-identity token, not a CLI token | same command |
| Local accounts enabled | The `kubernetes`/`helm`/`kubectl` providers in `versions.tf` authenticate with the cluster's client certificate, which Azure only issues when local accounts are on | `az aks update -g <rg> -n <cluster> --enable-local-accounts`, or fork `versions.tf` to use an `exec` block running `kubelogin get-token` |
| A region where `Anyscale.Platform/clouds` exists | The cloud, storage account, ACR and operator identity are all deployed there | move the cluster, or pick a different one |

Terraform checks all four during `plan` (see `terraform_data.existing_aks_preflight` in `aks_existing.tf`) and fails with the relevant `az` command in the error, before creating anything.

**Node pools.** `create_node_pools` defaults to `true`, so Terraform adds the Anyscale CPU and GPU pools to the adopted cluster, carrying the `node.anyscale.com/capacity-type`, `node.anyscale.com/accelerator-type` and `nvidia.com/gpu` taints the operator tolerates. Their subnet is read from the cluster's first agent pool; override with `existing_node_subnet_id`. Set `create_node_pools = false` if the cluster's own pools already carry those taints — if they carry a *different* taint scheme, override the tolerations via `anyscale_platform.extension_configuration_settings` instead, or Anyscale workloads will land on your system nodes.

**Other notes for this mode.** `azure_location`, `vnet_cidr`, `nodes_subnet_cidr` and `aks_cluster_subnet_cidr` are unused — the adopted resource group's region and the cluster's own network win. `enable_nfs` needs the node subnet to carry the `Microsoft.Storage` service endpoint; Terraform adds it to subnets it creates, but not to one you bring. `terraform destroy` removes only what Terraform created: the Anyscale cloud, operator extension, gateway, storage, ACR, identity and any node pools it added. The cluster, its resource group and its network are left alone.

Two related flags work independently of `create_aks_cluster`, for creating a cluster inside infrastructure you already have:

- `create_resource_group = false` — create everything except the resource group
- `existing_node_subnet_id = "/subscriptions/…/subnets/…"` — create the cluster in an existing subnet instead of a new VNet

### Deployment summary file

The apply also writes a YAML summary of the deployment to **`anyscale-aks-cloud.yaml`** in this directory (via the `local_file.cloud_summary` resource in `outputs.tf`). Because it depends on the cloud, operator-extension, and gateway resources, Terraform writes it only once those are in place, so it always reflects the finished deployment:

```yaml
anyscale_cloud:
  name: <cloud-name>
  resource_id: cldrsrc_…
  arm_id: /subscriptions/…/providers/Anyscale.Platform/clouds/<cloud-name>
  console_url: https://console.azure.anyscale.com
  operator_namespace: anyscale-operator
azure:
  resource_group: <rg>
  aks_cluster: <cluster>
  storage_account: <sa>
  acr_login_server: <acr>.azurecr.io
gateway:
  lb_hostname: <lb-address>
commands:
  get_credentials: az aks get-credentials --resource-group <rg> --name <cluster> --overwrite-existing
```

The file embeds ARM resource IDs (which include your subscription ID), so it is **gitignored** — treat it as a local deployment record, not a committed artifact.

## Grant team access

**Azure subscription Owner/Contributor does NOT let you (or your teammates) create Anyscale workspaces, jobs, or services.** Those workload operations require the **`Anyscale Platform Contributor Role`** assigned *on the Anyscale cloud resource itself* — permissions on the underlying Azure resources do not carry over to the Anyscale resource provider. (The Anyscale RP publishes three roles: `Anyscale Platform Administrator Role`, `Anyscale Platform Contributor Role`, `Anyscale Platform Reader Role`. The Azure portal's role-picker label may drop the trailing "Role", but the role definition keeps it — Terraform needs the exact name.)

You can grant it two ways:

**Terraform (recommended for repeatable setups)** — populate `var.anyscale_platform_contributors` with the object IDs of the users/groups/SPs that need access:

```hcl
anyscale_platform_contributors = [
  { principal_id = "<user-object-id>",  principal_type = "User" },
  { principal_id = "<group-object-id>", principal_type = "Group" },
]
```

On the next `terraform apply`, Terraform assigns `Anyscale Platform Contributor Role` to each principal, scoped to the cloud resource (`azurerm_role_assignment.anyscale_platform_contributor` in `anyscale.tf`). Look up an object ID with `az ad user show --id <upn> --query id -o tsv` or `az ad group show --group <name> --query id -o tsv`.

**Azure portal (manual / ad-hoc)** — navigate to your Anyscale cloud resource in the Azure portal, select **Access control (IAM) > Add > Add role assignment**, and assign **`Anyscale Platform Contributor`** to the appropriate users, groups, or service principals.

> The cloud resource is at `<resource-group> > Anyscale.Platform/clouds/<cloud-name>` — `terraform output anyscale_cloud_arm_id` gives the full ID.

## Verify

### Cluster-side health

```bash
# Refresh kubeconfig (if needed)
eval "$(terraform output -raw aks_get_credentials_command)"

# Operator should be Running 3/3 with 0 restarts
kubectl get pods -n anyscale-operator

# GatewayClass should be Accepted=True; Gateway should have an ADDRESS and PROGRAMMED=True
kubectl get gatewayclass eg
kubectl get gateway -n anyscale-operator

# The operator creates these two TLS Secrets after it comes up
kubectl get secret -n anyscale-operator | grep certificate
```

### Anyscale-side health (`anyscale cloud verify`)

The Anyscale CLI ships a one-shot cloud health check that validates the operator can talk to the control plane, reach storage, and serve the gateway. Run it once per cloud.

> **This is a manual, human-driven step — it is intentionally not part of `terraform apply`.** The deployed cloud authenticates the operator via Microsoft Entra workload identity, *not* a CLI token (see [Authentication](#authentication)). `anyscale login` is an interactive browser flow that produces a personal credential, so it can't run unattended inside Terraform — and wiring a personal token into the apply would reintroduce exactly the human-credential dependency this module avoids. Run verify yourself after the apply finishes.

> **Public Preview limitation:** during Public Preview, the Anyscale CLI supports only **read** operations against Azure cloud resources. Manage clouds and cloud resources through the **Anyscale Clouds Resource Provider in the Azure portal** (this Terraform module is one such management path). The CLI commands below — `cloud list`, `cloud verify`, `job submit` — are all read/workload operations and are supported.

**One-time CLI setup** (point the CLI at the Azure-hosted control plane, then authenticate). Add the `export` to `~/.bashrc` or `~/.zshrc` and start a new shell to make it permanent:

```bash
export ANYSCALE_HOST=https://console.azure.anyscale.com
anyscale login   # interactive browser login — produces your personal CLI credential
```

**Run verify** (repeatable, once per cloud):

```bash
# Make sure your kubectl context points at the cluster you just deployed.
# Use the output `aks_get_credentials_command`, or:
kubectl config use-context <cluster-name>

# Find the cloud ID (format cld_*). The Terraform output above is the
# Anyscale RESOURCE ID (cldrsrc_*) — the CLI uses the shorter cld_* form.
anyscale cloud list

# Run the verification. The CLI prompts you to select your kubectl context
# and confirm the operator namespace; confirm to proceed.
anyscale cloud verify --id <cld_id>
```

A healthy cloud returns:

```
Overall Result: ALL 1 cloud resources verified successfully
```

If verify fails on instance-types, give the operator another minute to publish the default catalog and retry — that happens automatically after the operator pod transitions to Running.

After verify succeeds, the cloud is ready for workspaces and jobs. Launch them from the [Anyscale console](https://console.azure.anyscale.com) under your cloud's name, or submit one from the CLI as shown next.

### Run your first workload

With the CLI authenticated (above), submit a small Ray job to confirm end-to-end scheduling against the cloud.

Create `main.py`:

```python
import ray
import time

num_ray_tasks = 5

@ray.remote
def process(x):
    if x == (num_ray_tasks - 1):
        print("Hello from one of the Running Ray Tasks!")
        time.sleep(200)
    return x * 2

result = ray.get([process.remote(x) for x in range(num_ray_tasks)])
print("The job result is", result)
```

Create `job.yaml` in the same directory:

```yaml
name: my-first-job
working_dir: .
entrypoint: python main.py
max_retries: 1
```

Submit the job, using the cloud **name** as it appears in the Anyscale console or `anyscale cloud list` (during Public Preview it starts with `/subscriptions/`):

```bash
anyscale job submit -f job.yaml --cloud <cloud-name>
```

The command returns a URL to track job status and view output in the Anyscale console.

### Run a ready-made template

Once the cloud verifies, the fastest way to exercise a realistic, end-to-end workload is a prebuilt example template. Open it in the console and select the cloud you just deployed as the compute target:

- **Model Composition / RecSys** — [console.azure.anyscale.com/template-preview/model-composition-recsys](https://console.azure.anyscale.com/template-preview/model-composition-recsys)

The template ships with its own workspace, dependencies, and runbook, so you don't write any config — it launches against your cloud and shows multi-model serving working on the AKS pools this module created. Browse the full catalog at [console.azure.anyscale.com](https://console.azure.anyscale.com) under **Templates**.

## Authentication

The Anyscale operator running in the cluster authenticates to `console.azure.anyscale.com` via **Microsoft Entra workload identity**:

```
K8s ServiceAccount: anyscale-operator/anyscale-operator
        │ (OIDC token)
        ▼
AKS OIDC issuer (.oidc_issuer_url)
        │
        ▼
azurerm_federated_identity_credential.anyscale_operator_fic
        │
        ▼
azurerm_user_assigned_identity.anyscale_operator (UAMI)
        │ (registered as the cloud's operator principal by the ARM template)
        ▼
Anyscale.Platform/clouds/<cloud-name>
        │
        ▼
console.azure.anyscale.com (validates AAD token, accepts the operator)
```

## Production readiness

This example trades hardening for a one-command first deploy. Before you run real workloads, work through the items below. Each names the Terraform argument or variable that controls it — keep environment-specific values (regions, IP ranges, SKUs, sizes) in `variables.tf` / `terraform.tfvars`, not as literals baked into the resource blocks.

> The cluster intentionally ships with several `checkov:skip` annotations in `aks.tf` — they're a precise inventory of what's deferred for the demo. The sections below address each one.

### 1. Remote Terraform state — do this first

Local `terraform.tfstate` is fine for a trial, but it lives only in this directory: lose the directory and you lose the ability to manage (or cleanly destroy) the cloud, and no teammate can collaborate. Move to a remote `backend "azurerm"` (blob storage, with native blob-lease locking — no extra lock table needed), then run `terraform init -migrate-state`. Keep the state storage account in its own locked-down resource group.

### 2. Cluster resilience — `aks.tf`

- **Control-plane SLA** — the cluster uses the AKS Free tier (best-effort API server). Set the SKU tier to Standard for the financially-backed uptime SLA.
- **Availability zones** — pin the system and worker pools across the zones your region offers so a single-AZ failure can't take the cloud down. Zones can't be added to an existing pool in place, so decide before the first apply.
- **Patching** — set an automatic upgrade channel and a maintenance window (`automatic_upgrade_channel` / `maintenance_window`) so node and control-plane patches land on a schedule instead of never.

### 3. Network exposure — `aks.tf`, `envoy-gateway.tf`

- **API server** — public by default. Make the cluster private, or restrict it to an authorized-IP allow-list sourced from a variable.
- **Workload ingress** — the Envoy gateway publishes a public load balancer. For private-only access, switch it to an internal LB and reach it over VPN / ExpressRoute / VNet peering.
- **Egress (easy to get wrong):** the operator dials the control plane *outbound* — the control plane never connects in. So a private cluster works fine **as long as** egress is open to `console.azure.anyscale.com`, Microsoft Entra, your ACR, and your storage account. If you force traffic through a firewall (`outbound_type = userDefinedRouting`), allow those FQDNs explicitly or workloads will hang at startup.

### 4. Identity — change `aks.tf` and `versions.tf` together

Disabling the local admin account and using Microsoft Entra RBAC is the right hardening — **but in this module the two files are coupled.** `versions.tf` authenticates the in-cluster `kubernetes` / `helm` / `kubectl` providers with the cluster's **admin client certificate** (`kube_config`), which exists *only while local accounts are enabled*. Disable local accounts without changing the providers and the single-apply bootstrap breaks. If you harden identity, also switch those providers to Entra auth — `kube_admin_config` (available once Entra RBAC is on) or an `exec` block running `kubelogin`. Change both, or neither.

### 5. Observability — `aks.tf`

No metrics or logs are shipped today. Add an `oms_agent` profile pointed at a Log Analytics workspace for Container Insights, so node, pod, and control-plane telemetry are queryable.

### 6. Data & secrets — `main.tf`

- **Storage durability** — the primary storage account is locally redundant. Choose a zone- or geo-redundant replication type for the bucket that holds checkpoints, logs, and artifacts, and enable blob versioning plus a soft-delete retention window.
- **Secrets** — the module manages none. Use Azure Key Vault with the CSI Secrets Store driver for workload secrets → https://docs.anyscale.com/admin/azure/key-vault

### 7. Registry — `acr.tf` (already variable-driven)

For production, raise the ACR SKU to Premium and enable zone redundancy (both are existing variables); Premium unlocks Private Link and customer-managed keys. Disable the bundled ACR only if you bring your own registry — and then grant its kubelet identity `AcrPull`.

### 8. Capacity — `variables.tf`

The [Quota](#quota) walkthrough sizes for a first launch (~24 vCPU). For production, size `cpu_vm_size` and `gpu_pool_configs` for steady-state peak and request matching VM-family + Total Regional vCPU quota — the autoscaler can never exceed quota you don't have. The CPU pools set `temporary_name_for_rotation`, so changing a pool's VM size rotates it in place instead of forcing a destroy.

### 9. Anyscale-specific

- **Head-node fault tolerance** is not available at the cloud level on Kubernetes. For a service that must survive a head-pod restart, set `ray_gcs_external_storage_config` in the service config and run your own Redis-compatible store → https://docs.anyscale.com/administration/resource-management/head-node-fault-tolerance#manual
- **Zero-downtime service upgrades** require an ingress controller the operator can patch. Envoy Gateway (this example) qualifies — keep it rather than swapping in a static ingress.
- **Release train** — keep `anyscale_platform.release_train = "stable"` for production; use `preview` only in a separate non-prod cloud.

### 10. Operating it

- Run `terraform plan` in CI against the remote state and require review — never `apply -auto-approve` to a production cloud.
- Protect head nodes with PodDisruptionBudgets, and remember to remove them before an AKS node-pool upgrade.
- After any change, confirm health with `anyscale cloud verify` ([Verify](#verify)); if a workload won't schedule, run `./diagnose-head-pod.sh`.

## Destroy

1. **Stop long-running workspaces / services first for a clean drain.** The hook waits up to 15 minutes (900s) for the control plane to drain sessions during the cloud delete. If you have heavy workloads running, terminating them in the console first makes teardown faster and avoids hitting that timeout.
2. **`anyscale cloud delete` is not supported on Azure today.** Cloud deletion goes through the ARM provider — which is what the hook's `az resource delete` does.
3. Run

    ```bash
    terraform destroy
    ```

## Customisation

The new variables this example adds on top of `aks-new_cluster`:

| Variable | Purpose | Default |
|---|---|---|
| `gpu_pool_configs` | GPU node pools to create (one on-demand + one spot pool per entry). Opt-in — see [GPU node pools](#gpu-node-pools-opt-in). Run `./select-gpu.sh` to fill it. | `{}` (no GPU pools) |
| `azure_resource_group_name` | Override the resource group name. | `<aks_cluster_name>-rg` |
| `anyscale_cloud_name` | Override the cloud name surfaced in the Anyscale console. | `<aks_cluster_name>-cloud` |
| `anyscale_platform.control_plane_url` | Anyscale control plane URL. Override for staging/preview deployments. | `https://console.azure.anyscale.com` |
| `anyscale_platform.release_train` | AKS extension release train: `stable` or `preview`. | `stable` |
| `anyscale_platform.extension_configuration_settings` | Extra Helm values for the operator extension (e.g. custom instance-type defaults). Merged on top of the example's tolerations. | `{}` |
| `envoy_gateway.chart_version` | Pinned Envoy Gateway Helm chart version. | `v1.7.0` |
| `envoy_gateway.gateway_lb_wait_timeout_seconds` | Maximum seconds to wait for the LB allocation before terraform fails. | `600` |
| `enable_acr` | Create a customer-owned ACR for workload images and grant kubelet `AcrPull`. Disable if you supply your own registry out-of-band. | `true` |
| `acr_sku` | ACR SKU. Premium is only needed for Private Link / zone redundancy / customer-managed keys. | `Standard` |
| `acr_zone_redundancy_enabled` | Enable zone redundancy. Premium-only; ignored otherwise. | `false` |
| `acr_name` | Override the generated ACR name. Must be 5-50 alphanumeric chars and globally unique. | derived from `aks_cluster_name` |

The Anyscale-specific variables defined in `variables.tf` are intentionally narrow — the deep tuning surface (compute configs, GPU node selectors, autoscaler bounds, instance-type catalogs) is handled inside the operator via Helm values, exposed through `anyscale_platform.extension_configuration_settings` if you need to override.

