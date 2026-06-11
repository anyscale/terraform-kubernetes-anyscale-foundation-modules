# Anyscale Azure AKS Example
This example creates the resources to run Anyscale on Azure AKS with public networking.

The content of this module should be used as a starting point and modified to your own security and infrastructure
requirements.

## Getting Started

### Claude Code Guided Deployment

If you have [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed, you can use the built-in skill to get interactive, step-by-step deployment guidance:

```shell
claude
# Then type: /deploy-azure-aks
```

This will walk you through the full deployment process, check your prerequisites, and help you configure variables. You can also jump to a specific step (e.g., `/deploy-azure-aks envoy`, `/deploy-azure-aks register`, or `/deploy-azure-aks pvc`).

### Prerequisites

* [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/)
  * [Sign into the Azure CLI](https://learn.microsoft.com/en-us/cli/azure/get-started-with-azure-cli#sign-into-the-azure-cli)
* [kubectl CLI](https://kubernetes.io/docs/tasks/tools/)
* [helm CLI](https://helm.sh/docs/intro/install/)
* [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli/) (> v0.26.24)

### Creating Anyscale Resources

Steps for deploying Anyscale resources via Terraform:

* Review variables.tf and (optionally) create a `terraform.tfvars` file to override any of the defaults.
e.g. 
```hcl
azure_tenant_id       = "" # az account show --query tenantId -o tsv
azure_subscription_id = ""
azure_location        = ""
aks_cluster_name      = ""

# (Optional) Control plane URL. Default connects to the AWS-hosted Anyscale control plane.
# Set to "https://console.azure.anyscale.com" if your Anyscale organization is on the Azure control plane.
# anyscale_control_plane_url = "https://console.azure.anyscale.com"

# (Optional) Override the default GPU node pools. The default provisions
# both T4 and A100 pools; the example below restricts it to T4 only.
# Set to `{}` for a CPU-only cluster. Each entry's `name` must be lowercase
# alphanumeric and <= 8 characters (spot pools append "spot").
gpu_pool_configs = {
  T4 = {
    name         = "gput4"
    vm_size      = "Standard_NC16as_T4_v3"
    product_name = "NVIDIA-T4"
    gpu_count    = "1"
  }
}
```

* Apply the terraform

```shell
terraform init
terraform plan
terraform apply
```

If you are using a `tfvars` file, you will need to update the above commands accordingly.
Note the output from Terraform which includes example cloud registration, helm commands and the command to get the AKS credentials you will use below.

### Install the Kubernetes Requirements

The Anyscale Operator requires the following components:
* [Envoy Gateway](https://gateway.envoyproxy.io/) (other Gateway API implementations may be possible but are untested). Requires Kubernetes 1.30 or later.
* (Optional) [Nvidia device plugin](https://github.com/NVIDIA/k8s-device-plugin/tree/main?tab=readme-ov-file#deployment-via-helm) (required if utilizing GPU nodes)

**Note:** Ensure that you are authenticated to the AKS cluster for the remaining steps. You can use the command from the Terraform output:

```shell
# From terraform output: aks_get_credentials_command
az aks get-credentials --resource-group <azure_resource_group_name> --name <aks_cluster_name> --overwrite-existing
```

#### Install Envoy Gateway

Install the Envoy Gateway Helm chart:

```shell
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 \
  --namespace envoy-gateway-system \
  --create-namespace

kubectl wait --for=condition=available deployment/envoy-gateway \
  -n envoy-gateway-system --timeout=120s
```

A sample manifest, `sample-envoy-gateway.yaml`, has been provided in this repo. It contains three resources: an `EnvoyProxy` (with Azure load-balancer annotations), a `GatewayClass` named `eg`, and a `Gateway` named `gateway` in the `anyscale-operator` namespace with HTTP/HTTPS listeners.

The Gateway listeners reference TLS Secrets whose names embed the Anyscale cloud deployment ID, so the manifest is applied **after** running `anyscale cloud register` further down. For now, only the helm install above is needed; the [Apply Envoy Gateway Resources](#apply-envoy-gateway-resources) step below picks it back up once you have the cloud deployment ID.

#### (Optional) Install the Nvidia device plugin

A sample file, `sample-values_nvdp.yaml` has been provided in this repo. Please review for AKS requirements before using.

1. Create a YAML values file named: `values_nvdp.yaml`
2. Update the content with the following:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: "kubernetes.azure.com/accelerator"
          operator: Exists
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  - key: node.anyscale.com/capacity-type
    operator: Exists
    effect: NoSchedule
  - key: node.anyscale.com/accelerator-type
    operator: Exists
    effect: NoSchedule
  - key: kubernetes.azure.com/scalesetpriority
    operator: Exists
    effect: NoSchedule
```

3. Run:

```shell
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm upgrade nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --version 0.17.1 \
  --values values_nvdp.yaml \
  --create-namespace \
  --install
```

### Register the Anyscale Cloud

Ensure that you are logged into Anyscale with valid CLI credentials. (`anyscale login`)

Using the output from the Terraform modules, register the Anyscale Cloud. Choose a name for your cloud in Anyscale in `<anyscale_cloud_name>`. It should look something like:

```shell
anyscale cloud register \
  --name <anyscale_cloud_name> \
  --region ... \
  --provider azure \
  --compute-stack k8s \
  --azure-tenant-id ... \
  --anyscale-operator-iam-identity ...  \
  --cloud-storage-bucket-name 'abfss://<container>@<storage-account>.dfs.core.windows.net' \
  --cloud-storage-bucket-endpoint 'https://<storage-account>.blob.core.windows.net'
```

Note the **cloud deployment ID** (`cldrsrc_...`) printed at the end — you'll need it for the next two steps.

### Apply Envoy Gateway Resources

Create the operator namespace if it doesn't already exist:

```shell
kubectl create namespace anyscale-operator
```

Substitute `<cldrsrc-id>` in `sample-envoy-gateway.yaml` with the **dash-form** of the cloud deployment ID from the previous step. Kubernetes Secret names can't contain underscores, so the operator stores the cert as `anyscale-cldrsrc-<dash-form>-certificate`. The easiest way is to pipe through `sed` and `tr`:

```shell
CLOUD_ID=cldrsrc_xxx  # value from `anyscale cloud register`
sed "s/<cldrsrc-id>/$(echo $CLOUD_ID | tr _ -)/g" sample-envoy-gateway.yaml \
  | kubectl apply -f -
```

Wait for the Gateway's load-balancer to be provisioned (typically 10-30s), then capture its address for the operator install:

```shell
kubectl wait --for=condition=Programmed gateway/gateway \
  -n anyscale-operator --timeout=180s

GATEWAY_ADDRESS=$(kubectl get gateway gateway -n anyscale-operator \
  -o jsonpath='{.status.addresses[0].value}')
echo "Gateway address: $GATEWAY_ADDRESS"
```

### Install the Anyscale Operator

Update helm repo cache:

```
helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update
```

Using the `helm_upgrade_command` from the Terraform output, install the Anyscale Operator on the AKS Cluster. It should look something like:

> **Note:** The helm command includes `global.controlPlaneURL` set from your `anyscale_control_plane_url` variable. If you did not set this in `terraform.tfvars`, the default (`https://console.anyscale.com`) is used. Re-run `terraform apply` first if you need to correct the URL before installing the operator.

```shell
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --set-string global.cloudDeploymentId=cldrsrc_... \
  --set-string global.cloudProvider=azure \
  --set-string global.auth.iamIdentity=... \
  --set-string global.auth.audience=api://.../.default \
  --set-string workloads.serviceAccount.name=anyscale-operator \
  --set networking.gateway.enabled=true \
  --set-string networking.gateway.name=gateway \
  --set-string networking.gateway.namespace=anyscale-operator \
  --set-string networking.gateway.apiVersion=gateway.networking.k8s.io/v1 \
  --set-string networking.gateway.hostname=<gateway-lb-address> \
  --namespace anyscale-operator \
  --create-namespace \
  --wait \
  -i
```

Replace `<gateway-lb-address>` with the value returned by the `kubectl get gateway` command above.

**(Optional)** If you are using GPU types other than T4, follow these steps. A sample file, `sample-custom_values.yaml` has been provided in this repo. Make a copy as `custom_values.yaml` and update based on your GPU types before using.

```shell
helm upgrade anyscale-operator anyscale/anyscale-operator \
  ...
  -f custom_values.yaml \
  --create-namespace \
  -i
```

### (Optional) Enable Azure Blob CSI PVC for Workloads

Anyscale workloads can mount Azure Blob storage as shared persistent volumes via the Azure Blob CSI driver — useful for shared model artifacts, datasets, and checkpoints accessible from any Ray node. See the [Anyscale Azure PVC docs](https://docs.anyscale.com/clouds/azure/pvc) for the full background.

This module supports it out of the box behind the `enable_blob_driver` variable. When enabled, terraform:

1. Toggles `storage_profile.blob_driver_enabled = true` on the AKS cluster.
2. Grants four role assignments on the Anyscale storage account — the two CSI driver components authenticate as different identities and both need access:
   - **AKS control-plane (SystemAssigned) identity** — used by `csi-blob-controller` for dynamic container provisioning. Gets `Storage Blob Data Contributor` + `Storage Account Key Operator Service Role`.
   - **AKS kubelet (UserAssigned `<cluster>-agentpool`) identity** — used by `csi-blob-node` for pod-runtime mount. Gets the same two roles.

   Granting only one of the two identities causes either a 3-minute provisioning loop with 403 errors (controller can't create the container) or AADSTS70025 mount failures at pod startup (kubelet can't authenticate via MSI). Both are required.

To enable, set in your `terraform.tfvars`:

```hcl
enable_blob_driver = true
```

Then re-run `terraform apply` (safe to run against an existing cluster; only adds the role assignments).

#### When to create the PVC

You have two options:

- **Default — create now**: apply the PVC right after operator install (steps below). The PVC is ready by the time you deploy your first workload.
- **Create later**: skip this section for now. The terraform helper output stays available, so when you decide you want shared storage, come back and run the same commands. The cluster, CSI driver, and role assignments are already in place from `terraform apply` — only the K8s-side PVC apply + cloud-side registration are deferred.

The steps below apply to the "create now" path. If you're going with "create later", just bookmark this section and come back.

#### Apply the StorageClass + PVC

A sample manifest, `sample-blob-pvc.yaml`, is provided. It contains a `StorageClass` (`blobfuse-csi`) backed by the storage account terraform already provisioned, and a `PersistentVolumeClaim` (`anyscale-shared-fuse`, ReadWriteMany, 100 GiB) in the `anyscale-operator` namespace.

The easiest way to apply it is via the `pvc_apply_command` terraform output, which substitutes the storage-account and resource-group placeholders for you:

```shell
$(terraform output -raw pvc_apply_command)
```

Or substitute manually:

```shell
SA=$(terraform output -raw azure_storage_account_name)
RG=$(terraform output -raw azure_resource_group_name)
sed -e "s/<storage-account>/$SA/g" -e "s/<resource-group>/$RG/g" sample-blob-pvc.yaml \
  | kubectl apply -f -
```

Verify the PVC reaches `Bound`:

```shell
kubectl get pvc anyscale-shared-fuse -n anyscale-operator
```

#### Register the PVC with the Anyscale cloud

Anyscale needs the PVC referenced on the cloud's resource spec for workloads to mount it. The Anyscale CLI offers two paths; pick whichever fits your flow:

**Option A — set it at register time** (cleanest, but requires creating the namespace + applying the PVC *before* `anyscale cloud register`):

```shell
anyscale cloud register \
  ... \
  --persistent-volume-claim anyscale-shared-fuse
```

Note: `--persistent-volume-claim` is mutually exclusive with `--nfs-mount-target` / `--nfs-mount-path` and `--csi-ephemeral-volume-driver`. Don't combine with `enable_nfs = true` on the same cloud.

**Option B — update an existing cloud via resources YAML**:

There's no direct flag for this on `anyscale cloud update`; you patch the cloud's full resource spec via `-f`. The resources file is a full replacement (not a partial patch) and must include every field currently on the resource. Run `anyscale cloud get --name <cloud-name>` to see the current spec, then save it as `resources.yaml` with `file_storage` added:

```yaml
- cloud_resource_id: cldrsrc_xxx                # from `anyscale cloud get`
  name: k8s-azure-<region>
  provider: AZURE
  compute_stack: K8S
  region: <region>
  object_storage:
    bucket_name: abfss://<container>@<storage-account>.dfs.core.windows.net
    endpoint: https://<storage-account>.blob.core.windows.net
  azure_config:
    tenant_id: <azure-tenant-id>
  kubernetes_config:
    anyscale_operator_iam_identity: <operator-principal-id>
  file_storage:                                 # the new bit
    persistent_volume_claim: anyscale-shared-fuse
```

Then apply (pass `-y` to skip the diff prompt):

```shell
anyscale cloud update --name <anyscale-cloud-name> -f resources.yaml -y
```

See the [CloudResource schema](https://docs.anyscale.com/reference/cloud#cloudresource) for the full structure of the resources file.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | 4.26.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.26.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_federated_identity_credential.anyscale_operator_fic](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/federated_identity_credential) | resource |
| [azurerm_kubernetes_cluster.aks](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/kubernetes_cluster) | resource |
| [azurerm_kubernetes_cluster_node_pool.gpu_ondemand](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/kubernetes_cluster_node_pool) | resource |
| [azurerm_kubernetes_cluster_node_pool.gpu_spot](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/kubernetes_cluster_node_pool) | resource |
| [azurerm_kubernetes_cluster_node_pool.ondemand_cpu](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/kubernetes_cluster_node_pool) | resource |
| [azurerm_kubernetes_cluster_node_pool.spot_cpu](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/kubernetes_cluster_node_pool) | resource |
| [azurerm_resource_group.rg](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.aks_cp_blob_data_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.aks_cp_blob_key_operator](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.aks_kubelet_blob_data_contributor](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.aks_kubelet_blob_key_operator](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.anyscale_blob_contrib](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/role_assignment) | resource |
| [azurerm_storage_account.nfs](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/storage_account) | resource |
| [azurerm_storage_account.sa](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/storage_account) | resource |
| [azurerm_storage_container.blob](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/storage_container) | resource |
| [azurerm_subnet.nodes](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/subnet) | resource |
| [azurerm_user_assigned_identity.anyscale_operator](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/user_assigned_identity) | resource |
| [azurerm_virtual_network.vnet](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/virtual_network) | resource |
| [azurerm_location.example](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/data-sources/location) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aks_cluster_dns_address"></a> [aks\_cluster\_dns\_address](#input\_aks\_cluster\_dns\_address) | (Optional) DNS address for the AKS cluster. If not set, a default will be generated from aks\_cluster\_subnet\_cidr. | `string` | `null` | no |
| <a name="input_aks_cluster_name"></a> [aks\_cluster\_name](#input\_aks\_cluster\_name) | (Optional) Name of the AKS cluster (and related resources). | `string` | `"anyscale-demo"` | no |
| <a name="input_aks_cluster_subnet_cidr"></a> [aks\_cluster\_subnet\_cidr](#input\_aks\_cluster\_subnet\_cidr) | (Optional) CIDR block for the AKS cluster service subnet. Cannot overlap with vnet\_cidr or nodes\_subnet\_cidr. | `string` | `"10.0.0.0/16"` | no |
| <a name="input_anyscale_control_plane_url"></a> [anyscale\_control\_plane\_url](#input\_anyscale\_control\_plane\_url) | (Optional) Anyscale control plane URL. Use https://console.anyscale.com for the AWS control plane or https://console.azure.anyscale.com for the Azure control plane. | `string` | `"https://console.anyscale.com"` | no |
| <a name="input_anyscale_operator_namespace"></a> [anyscale\_operator\_namespace](#input\_anyscale\_operator\_namespace) | (Optional) Kubernetes namespace for the Anyscale operator. | `string` | `"anyscale-operator"` | no |
| <a name="input_azure_location"></a> [azure\_location](#input\_azure\_location) | (Optional) Azure region for all resources. | `string` | `"West US"` | no |
| <a name="input_azure_subscription_id"></a> [azure\_subscription\_id](#input\_azure\_subscription\_id) | (Required) Azure subscription ID | `string` | n/a | yes |
| <a name="input_azure_tenant_id"></a> [azure\_tenant\_id](#input\_azure\_tenant\_id) | Azure tenant ID. Can be found by running `az account show --query tenantId -o tsv`. | `string` | n/a | yes |
| <a name="input_cors_rule"></a> [cors\_rule](#input\_cors\_rule) | (Optional)<br/>Object containing a rule of Cross-Origin Resource Sharing.<br/>The default allows GET, POST, PUT, HEAD, and DELETE<br/>access for the purpose of viewing logs and other functionality<br/>from within the Anyscale Web UI (*.anyscale.com).<br/><br/>ex:<pre>cors_rule = {<br/>  allowed_headers = ["*"]<br/>  allowed_methods = ["GET", "POST", "PUT", "HEAD", "DELETE"]<br/>  allowed_origins = ["https://*.anyscale.com"]<br/>  expose_headers  = ["Accept-Ranges", "Content-Range", "Content-Length"]<br/>}</pre> | <pre>object({<br/>    allowed_headers    = list(string)<br/>    allowed_methods    = list(string)<br/>    allowed_origins    = list(string)<br/>    expose_headers     = list(string)<br/>    max_age_in_seconds = optional(number, 0)<br/>  })</pre> | <pre>{<br/>  "allowed_headers": [<br/>    "*"<br/>  ],<br/>  "allowed_methods": [<br/>    "GET",<br/>    "POST",<br/>    "PUT",<br/>    "HEAD",<br/>    "DELETE"<br/>  ],<br/>  "allowed_origins": [<br/>    "https://*.anyscale.com"<br/>  ],<br/>  "expose_headers": [<br/>    "Accept-Ranges",<br/>    "Content-Range",<br/>    "Content-Length"<br/>  ]<br/>}</pre> | no |
| <a name="input_cpu_vm_size"></a> [cpu\_vm\_size](#input\_cpu\_vm\_size) | VM size for the CPU node pools (on-demand and spot). | `string` | `"Standard_D16s_v5"` | no |
| <a name="input_enable_blob_driver"></a> [enable\_blob\_driver](#input\_enable\_blob\_driver) | (Optional) Enable the Azure Blob CSI driver on the AKS cluster. Required for mounting blob storage from pods. | `bool` | `false` | no |
| <a name="input_enable_nfs"></a> [enable\_nfs](#input\_enable\_nfs) | (Optional) Enable provisioning of an Azure NFS (Network File System) storage account.<br/>This NFS storage can be used for file-based persistent storage needs, mounting shared volumes to AKS nodes and pods. | `bool` | `false` | no |
| <a name="input_enable_operator_infrastructure"></a> [enable\_operator\_infrastructure](#input\_enable\_operator\_infrastructure) | (Optional) Enable blob storage, managed identity, federated identity credential,<br/>role assignment, and output registration/helm commands for the Anyscale operator.<br/>Set to false when using the Azure control plane, which provisions these via ARM templates. | `bool` | `true` | no |
| <a name="input_gpu_pool_configs"></a> [gpu\_pool\_configs](#input\_gpu\_pool\_configs) | (Optional) Full configuration for GPU node pools. The map key is a logical label<br/>(e.g. "T4", "A100"). The `name` field is used as the AKS node pool name and must<br/>be lowercase alphanumeric, max 8 chars (spot pools append "spot"). | <pre>map(object({<br/>    name         = string<br/>    vm_size      = string<br/>    product_name = string<br/>    gpu_count    = string<br/>  }))</pre> | <pre>{<br/>  "A100": {<br/>    "gpu_count": "1",<br/>    "name": "gpua100",<br/>    "product_name": "NVIDIA-A100",<br/>    "vm_size": "Standard_NC24ads_A100_v4"<br/>  },<br/>  "T4": {<br/>    "gpu_count": "1",<br/>    "name": "gput4",<br/>    "product_name": "NVIDIA-T4",<br/>    "vm_size": "Standard_NC16as_T4_v3"<br/>  }<br/>}</pre> | no |
| <a name="input_nodes_subnet_cidr"></a> [nodes\_subnet\_cidr](#input\_nodes\_subnet\_cidr) | (Optional) CIDR block for the AKS nodes subnet. | `string` | `"10.42.1.0/24"` | no |
| <a name="input_storage_account_name"></a> [storage\_account\_name](#input\_storage\_account\_name) | (Optional) Name of the Azure Storage account to create for cloud storage. May be needed if generated name is already taken. | `string` | `null` | no |
| <a name="input_storage_account_name_nfs"></a> [storage\_account\_name\_nfs](#input\_storage\_account\_name\_nfs) | (Optional) Name of the Azure NFS storage account to create. May be needed if generated name is already taken. | `string` | `null` | no |
| <a name="input_storage_use_azuread"></a> [storage\_use\_azuread](#input\_storage\_use\_azuread) | (Optional) Determines whether the provider uses AzureAD or the SharedKey from the Storage Account to connect to the Storage Blob & Queue APIs | `bool` | `false` | no |
| <a name="input_system_vm_size"></a> [system\_vm\_size](#input\_system\_vm\_size) | VM size for the default system node pool. | `string` | `"Standard_D2s_v5"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | (Optional) Tags applied to all taggable resources. | `map(string)` | <pre>{<br/>  "Environment": "dev",<br/>  "Test": "true"<br/>}</pre> | no |
| <a name="input_vnet_cidr"></a> [vnet\_cidr](#input\_vnet\_cidr) | (Optional) CIDR block for the VNet. | `string` | `"10.42.0.0/16"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_aks_get_credentials_command"></a> [aks\_get\_credentials\_command](#output\_aks\_get\_credentials\_command) | The command to get the AKS cluster credentials. |
| <a name="output_anyscale_operator_client_id"></a> [anyscale\_operator\_client\_id](#output\_anyscale\_operator\_client\_id) | Client ID of the Azure User Assigned Identity created for the cluster. |
| <a name="output_anyscale_operator_principal_id"></a> [anyscale\_operator\_principal\_id](#output\_anyscale\_operator\_principal\_id) | Principal ID of the Azure User Assigned Identity created for the cluster. |
| <a name="output_anyscale_registration_command"></a> [anyscale\_registration\_command](#output\_anyscale\_registration\_command) | The Anyscale registration command. |
| <a name="output_azure_aks_cluster_name"></a> [azure\_aks\_cluster\_name](#output\_azure\_aks\_cluster\_name) | Name of the Azure AKS cluster created for the cluster. |
| <a name="output_azure_nfs_storage_account_name"></a> [azure\_nfs\_storage\_account\_name](#output\_azure\_nfs\_storage\_account\_name) | Name of the Azure NFS Storage Account created for the cluster. |
| <a name="output_azure_resource_group_name"></a> [azure\_resource\_group\_name](#output\_azure\_resource\_group\_name) | Name of the Azure Resource Group created for the cluster. |
| <a name="output_azure_storage_account_name"></a> [azure\_storage\_account\_name](#output\_azure\_storage\_account\_name) | Name of the Azure Storage Account created for the cluster. |
| <a name="output_azure_storage_container_name"></a> [azure\_storage\_container\_name](#output\_azure\_storage\_container\_name) | Name of the Azure Storage Container created for the cluster. |
| <a name="output_helm_upgrade_command"></a> [helm\_upgrade\_command](#output\_helm\_upgrade\_command) | The helm upgrade command for installing the Anyscale operator. |
| <a name="output_pvc_apply_command"></a> [pvc\_apply\_command](#output\_pvc\_apply\_command) | Ready-to-run command to apply the sample Azure Blob CSI PVC manifest with<br/>placeholders substituted. Only emitted when enable\_blob\_driver = true.<br/>Requires the `anyscale-operator` namespace to already exist (the operator<br/>helm install creates it with --create-namespace). |
<!-- END_TF_DOCS -->
