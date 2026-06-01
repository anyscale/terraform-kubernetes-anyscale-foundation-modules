# Anyscale on Azure

This is a step-by-step guide that deploys **Anyscale on Azure**. It deploys Azure Resources such as AKS, VNets, subnet and storage and adds two **Azure Resource Provider** integrations that make the cluster a managed Anyscale cloud:

1. **`Anyscale.Platform/clouds`** (deployed via `azapi_resource`) — registers the cloud with the Azure-hosted Anyscale control plane at `https://console.azure.anyscale.com` and produces a stable `cldrsrc_…` ID.
2. **`Microsoft.KubernetesConfiguration/extensions`** of type `Anyscale.AKS.Operator` (deployed via `azurerm_kubernetes_cluster_extension`) — installs the operator marketplace extension into the AKS cluster's `anyscale-operator` namespace, wired to the cloud above.

3. **Envoy Gateway** (Helm chart + `EnvoyProxy` + `GatewayClass` + `Gateway`) that the operator routes workspace and service traffic through — matching the upstream Anyscale-on-AKS quickstart.

After the apply finishes, the cloud is visible at `https://console.azure.anyscale.com` under the cloud name you chose.

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

Default is `westus2`. Older regions like `westus` are **not** supported by the Anyscale RP.

### Quota

- `Microsoft.ContainerService/managedClusters` quota of **at least 1** in the chosen region (default cap is 10 per region).
- VM family quota for `var.system_vm_size`, `var.cpu_vm_size`, and any `var.gpu_pool_configs` SKUs.

### Local tools

- Azure CLI (`az`) authenticated against the target tenant: `az login --tenant <tenant>`
- Terraform `>= 1.5.0`
- `kubectl`, `helm`, `bash` (Linux/macOS; WSL on Windows)

## Deploy

```bash
# From the example directory
terraform init
terraform apply
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

The Anyscale CLI ships a one-shot cloud health check that validates the operator can talk to the control plane, reach storage, and serve the gateway. Run it once per cloud:

```bash
# Point the CLI at the Azure-hosted control plane (add to ~/.bashrc or ~/.zshrc to make permanent)
export ANYSCALE_HOST=https://console.azure.anyscale.com
anyscale login

# Find the cloud ID (format cld_*). The Terraform output above is the
# Anyscale RESOURCE ID (cldrsrc_*) — the CLI uses the shorter cld_* form.
anyscale cloud list

# Run the verification — picks up your current kubectl context
anyscale cloud verify --id <cld_id>
```

A healthy cloud returns:

```
Overall Result: ALL 1 cloud resources verified successfully
```

If verify fails on instance-types, give the operator another minute to publish the default catalog and retry — that happens automatically after the operator pod transitions to Running.

After verify succeeds, the cloud is ready for workspaces and jobs. Launch them from the [Anyscale console](https://console.azure.anyscale.com) under your cloud's name.

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

