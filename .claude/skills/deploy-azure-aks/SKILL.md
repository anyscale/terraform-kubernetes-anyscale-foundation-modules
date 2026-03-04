---
name: deploy-azure-aks
description: Guide for deploying the Anyscale Azure AKS new cluster example from examples/azure/aks-new_cluster/. Use when the user asks about deploying, setting up, or configuring Azure AKS for Anyscale.
argument-hint: [step]
allowed-tools: Read, Bash, Grep, Glob
---

# Deploy Azure AKS for Anyscale

Walk the user through deploying the Azure AKS example at `examples/azure/aks-new_cluster/`.

If `$ARGUMENTS` specifies a step (e.g., "terraform", "nginx", "gpu", "register", "operator"), skip to that step. Otherwise, guide from the beginning.

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

## Step 4: Install Nginx Ingress Controller

```shell
helm repo add nginx https://kubernetes.github.io/ingress-nginx
helm upgrade ingress-nginx nginx/ingress-nginx \
  --version 4.12.1 \
  --namespace ingress-nginx \
  --values sample-values_nginx.yaml \
  --create-namespace \
  --install
```

The sample values file is at `examples/azure/aks-new_cluster/sample-values_nginx.yaml`.

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

## Step 7: Install the Anyscale Operator

```shell
helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update
```

Then use the helm command from terraform output, replacing `<cloud-deployment-id>` with the ID from the cloud register step:

```shell
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --set-string global.cloudDeploymentId=<cloud-deployment-id> \
  --set-string global.controlPlaneURL=https://console.azure.anyscale.com \
  --set-string global.cloudProvider=azure \
  --set-string global.auth.iamIdentity=<client-id> \
  --set-string global.auth.audience=api://086bc555-6989-4362-ba30-fded273e432b/.default \
  --set-string workloads.serviceAccount.name=anyscale-operator \
  --namespace anyscale-operator \
  --create-namespace \
  -i
```

For custom GPU types (other than T4), copy `sample-custom_values.yaml` to `custom_values.yaml`, edit it, and add `-f custom_values.yaml` to the helm command.

## Teardown

To destroy all resources:

```shell
# Remove helm releases first
helm uninstall anyscale-operator -n anyscale-operator
helm uninstall nvdp -n nvidia-device-plugin
helm uninstall ingress-nginx -n ingress-nginx

# Then destroy terraform resources
terraform destroy
```

## Troubleshooting

If the user hits issues, check:
- `kubectl get nodes` - Verify nodes are ready
- `kubectl get pods -A` - Check for failing pods
- `az aks show -g <rg> -n <cluster>` - Verify cluster state
- Ensure the Azure subscription has quota for the requested VM sizes
