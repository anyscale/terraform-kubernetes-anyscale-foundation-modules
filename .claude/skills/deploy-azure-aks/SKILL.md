---
name: deploy-azure-aks
description: Guide for deploying the Anyscale Azure AKS new cluster example from examples/azure/aks-new_cluster/. Use when the user asks about deploying, setting up, or configuring Azure AKS for Anyscale.
argument-hint: [step]
allowed-tools: Read, Bash, Grep, Glob
---

# Deploy Azure AKS for Anyscale

Walk the user through deploying the Azure AKS example at `examples/azure/aks-new_cluster/`.

If `$ARGUMENTS` specifies a step (e.g., "terraform", "envoy", "gpu", "register", "operator", "pvc"), skip to that step. Otherwise, guide from the beginning.
## Prerequisites

Ensure the user has:
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/) (signed in via `az login`)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/docs/intro/install/)
- [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli/) (>= v0.26.24)
- Terraform >= 1.0.0

## Step 1: Configure Terraform Variables

The user needs a `terraform.tfvars` file in `examples/azure/aks-new_cluster/`. Required variables:

```hcl
azure_tenant_id       = ""  # az account show --query tenantId -o tsv
azure_subscription_id = ""  # az account show --query id -o tsv
azure_location        = ""  # e.g. "Central US"
aks_cluster_name      = ""  # e.g. "my-anyscale-cluster"
```

Key optional variables:
- `gpu_pool_configs` - Map of GPU pool configs. Keys like "T4", "A100". Each needs `name` (max 8 lowercase alphanum chars), `vm_size`, `product_name`, `gpu_count`. Set to `{}` for CPU-only.
- `enable_nfs` - Enable NFS storage (default: false)
- `enable_blob_driver` - Enable Azure Blob CSI driver (default: false)
- `system_vm_size` - System node VM size (default: "Standard_D2s_v5")
- `cpu_vm_size` - CPU node VM size (default: "Standard_D16s_v5")
- `anyscale_control_plane_url` - Control plane URL (default: `https://console.anyscale.com` for AWS-hosted control plane). Set to `https://console.azure.anyscale.com` if the Anyscale organization is on the Azure control plane.

Read `examples/azure/aks-new_cluster/variables.tf` for the full list.

## Step 2: Apply Terraform

Run from `examples/azure/aks-new_cluster/`:

```shell
terraform init
terraform plan
terraform apply
```

Save the outputs - they contain commands for the remaining steps. Key outputs:
- `aks_get_credentials_command` - Command to authenticate kubectl
- `anyscale_registration_command` - Command to register the Anyscale cloud
- `helm_upgrade_command` - Command to install the Anyscale operator

## Step 3: Get AKS Credentials

Use the terraform output command:

```shell
# From terraform output: aks_get_credentials_command
az aks get-credentials --resource-group <rg-name> --name <cluster-name> --overwrite-existing
```

## Step 4: Install Envoy Gateway

The Anyscale Operator on AKS uses Envoy Gateway (Gateway API) instead of an ingress controller. Requires Kubernetes 1.30+.

Install the Envoy Gateway Helm chart:

```shell
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 \
  --namespace envoy-gateway-system \
  --create-namespace

kubectl wait --for=condition=available deployment/envoy-gateway \
  -n envoy-gateway-system --timeout=120s
```

The Gateway/EnvoyProxy/GatewayClass manifests are in `examples/azure/aks-new_cluster/sample-envoy-gateway.yaml`. They reference a TLS Secret name that embeds the Anyscale cloud deployment ID, so apply them after Step 6 (cloud register).

## Step 5 (Optional): Install Nvidia Device Plugin

Only needed if using GPU node pools. The sample values file is at `examples/azure/aks-new_cluster/sample-values_nvdp.yaml`.

```shell
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm upgrade nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --version 0.17.1 \
  --values sample-values_nvdp.yaml \
  --create-namespace \
  --install
```

## Step 6: Register the Anyscale Cloud

Ensure `anyscale login` is done, then use the registration command from terraform output:

```shell
anyscale cloud register \
  --name <anyscale_cloud_name> \
  --region <region> \
  --provider azure \
  --compute-stack k8s \
  --azure-tenant-id <tenant-id> \
  --anyscale-operator-iam-identity <principal-id> \
  --cloud-storage-bucket-name 'abfss://<container>@<storage-account>.dfs.core.windows.net' \
  --cloud-storage-bucket-endpoint 'https://<storage-account>.blob.core.windows.net'
```

Note the returned cloud deployment ID (e.g. `cldrsrc_...`) — needed in the next two steps.

## Step 7: Apply Envoy Gateway Resources

Create the operator namespace if it doesn't already exist:

```shell
kubectl create namespace anyscale-operator
```

In `examples/azure/aks-new_cluster/sample-envoy-gateway.yaml`, replace every occurrence of `<cldrsrc-id>` with the **dash-form** of the cloud deployment ID from Step 6. Kubernetes Secret names can't contain underscores, so the operator stores the cert Secret as `anyscale-cldrsrc-<dash-form>-certificate` — if the register command returned `cldrsrc_abc123xyz`, substitute `cldrsrc-abc123xyz`.

One-liner that does the substitution + apply in one shot:

```shell
CLOUD_ID=cldrsrc_xxx   # value from Step 6
sed "s/<cldrsrc-id>/$(echo $CLOUD_ID | tr _ -)/g" sample-envoy-gateway.yaml \
  | kubectl apply -f -
```

Wait for the gateway LB to be provisioned (typically 10-30s), then capture its address (needed in the next step):

```shell
kubectl wait --for=condition=Programmed gateway/gateway \
  -n anyscale-operator --timeout=180s

GATEWAY_ADDRESS=$(kubectl get gateway gateway -n anyscale-operator \
  -o jsonpath='{.status.addresses[0].value}')
echo "Gateway address: $GATEWAY_ADDRESS"
```

## Step 8: Install the Anyscale Operator

```shell
helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update
```

Use the `helm_upgrade_command` from the terraform output — it already has `global.controlPlaneURL` set correctly from your `anyscale_control_plane_url` variable. Replace `<cloud-deployment-id>` with the ID from Step 6 and `<gateway-lb-address>` with the value captured in Step 7:

```shell
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --set-string global.cloudDeploymentId=<cloud-deployment-id> \
  --set-string global.controlPlaneURL=<from-terraform-output> \
  --set-string global.cloudProvider=azure \
  --set-string global.auth.iamIdentity=<client-id> \
  --set-string global.auth.audience=api://086bc555-6989-4362-ba30-fded273e432b/.default \
  --set-string workloads.serviceAccount.name=anyscale-operator \
  --set networking.gateway.enabled=true \
  --set-string networking.gateway.name=gateway \
  --set-string networking.gateway.namespace=anyscale-operator \
  --set-string networking.gateway.apiVersion=gateway.networking.k8s.io/v1 \
  --set-string networking.gateway.hostname=<gateway-lb-address> \
  --namespace anyscale-operator \
  --create-namespace \
  -i
```

The `global.controlPlaneURL` value comes from the terraform output — do not hardcode it. The default is `https://console.anyscale.com` (AWS-hosted control plane); it is `https://console.azure.anyscale.com` only if `anyscale_control_plane_url` was set accordingly in Step 1.

For custom GPU types (other than T4), copy `sample-custom_values.yaml` to `custom_values.yaml`, edit it, and add `-f custom_values.yaml` to the helm command.

## Step 9 (Optional): Enable Azure Blob CSI PVC for workloads

Only run this if you want Anyscale workloads to mount Azure Blob storage as a shared `PersistentVolumeClaim` (useful for shared model artifacts, datasets, checkpoints). See https://docs.anyscale.com/clouds/azure/pvc.

The user has two timing options once the CSI driver is enabled:
- **Default — create now**: do steps 2-4 below right after operator install.
- **Create later**: do step 1 now (so the driver + role assignments are in place), but defer steps 2-4 until shared storage is actually needed. The terraform helper output (`pvc_apply_command`) stays available.

1. Set `enable_blob_driver = true` in `terraform.tfvars` and re-run `terraform apply`. This toggles the AKS Blob CSI driver and grants both `Storage Blob Data Contributor` + `Storage Account Key Operator Service Role` to **both** the AKS control-plane (SystemAssigned) identity AND the AKS kubelet (UserAssigned `<cluster>-agentpool`) identity. Both are needed: control plane for `csi-blob-controller` to dynamically provision the blob container, kubelet for `csi-blob-node` to mount it at pod-runtime. Granting only one identity surfaces either a 3-min 403 provisioning loop or an AADSTS70025 mount failure.

2. Apply the sample StorageClass + PVC. Easiest path is the terraform helper output that pre-substitutes the storage account / resource group placeholders:

```shell
$(terraform output -raw pvc_apply_command)
```

3. Verify the PVC is `Bound`:

```shell
kubectl get pvc anyscale-shared-fuse -n anyscale-operator
```

4. Register the PVC with the Anyscale cloud so workloads can mount it. Two paths depending on whether the cloud is already registered:

   **At register time** — pass `--persistent-volume-claim anyscale-shared-fuse` to `anyscale cloud register`. Mutually exclusive with NFS / CSI-ephemeral flags. Requires the PVC to exist before register, so you'd create the namespace and apply the PVC earlier in the flow.

   **For an already-registered cloud** — `anyscale cloud update` has no direct flag for this; you patch the cloud's full resource spec via `-f`. The resources file is a **full replacement** (not a partial patch), so you must include every field currently on the resource (run `anyscale cloud get --name <cloud-name>` to see them), then add `file_storage`:

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

   CloudResource schema: https://docs.anyscale.com/reference/cloud#cloudresource

## Teardown

Order matters here. Uninstalling the Anyscale Operator before terminating its workloads orphans the workload pods (the operator is the one that responds to `anyscale service terminate` / `workspace_v2 terminate` and removes the pods). Orphaned pods then hold the PVC's finalizer and block `kubectl delete pvc`, and the Anyscale control plane keeps the sessions as "active", which blocks `anyscale cloud delete` with a 409 conflict. Do the steps in order:

```shell
# 1. Terminate all Anyscale workloads FIRST (services, workspaces, jobs).
#    The operator handles graceful pod shutdown for these.
anyscale service list --cloud <cloud-name>
anyscale service terminate -n <each-service-name>          # repeat per service

anyscale workspace_v2 list --cloud <cloud-name>
anyscale workspace_v2 terminate --id <each-workspace-id>   # repeat per workspace

# 2. Wait for workload pods to actually disappear from the anyscale-operator
#    namespace. Only the `anyscale-operator-*` pod should remain.
kubectl get pods -n anyscale-operator -w   # Ctrl-C once the workload (k-*) pods are gone

# 3. Delete the Anyscale cloud record BEFORE uninstalling the operator, so
#    Anyscale sees a clean state and the operator gets to handle the
#    deregistration. (Pass -y to skip the confirm prompt.)
anyscale cloud delete --name <cloud-name> -y

# 4. Uninstall the operator + delete the PVC/Gateway/Envoy resources.
helm uninstall anyscale-operator -n anyscale-operator
kubectl delete pvc anyscale-shared-fuse -n anyscale-operator --ignore-not-found
kubectl delete storageclass blobfuse-csi --ignore-not-found
kubectl delete gateway gateway -n anyscale-operator --ignore-not-found
kubectl delete -f sample-envoy-gateway.yaml --ignore-not-found
helm uninstall eg -n envoy-gateway-system

# (Optional) NVIDIA device plugin, only if it was installed.
helm uninstall nvdp -n nvidia-device-plugin

# 5. Finally, destroy the Azure infrastructure.
cd examples/azure/aks-new_cluster && terraform destroy
```

If a PVC is stuck in `Terminating` because an orphaned pod still references it (Step 1 was skipped or didn't fully complete), unblock with:

```shell
# Find the pods still holding it
kubectl get pods -n anyscale-operator
# Force-delete any leftover workload pods (k-* names)
kubectl delete pod <pod-name> -n anyscale-operator --force --grace-period=0
# If the PVC is still stuck, remove its finalizer
kubectl patch pvc anyscale-shared-fuse -n anyscale-operator \
  -p '{"metadata":{"finalizers":null}}' --type=merge
```

If `anyscale cloud delete` returns a 409 Conflict listing active clusters, those are orphan session records on Anyscale's side. Either wait for the heartbeat timeout (15-60 min), terminate them from the Anyscale UI (`https://console.anyscale.com/projects/<project-id>/clusters/<ses-id>`), or call the Python SDK's `terminate_cluster` directly.

## Troubleshooting

If the user hits issues, check:
- `kubectl get nodes` - Verify nodes are ready
- `kubectl get pods -A` - Check for failing pods
- `az aks show -g <rg> -n <cluster>` - Verify cluster state
- Ensure the Azure subscription has quota for the requested VM sizes
