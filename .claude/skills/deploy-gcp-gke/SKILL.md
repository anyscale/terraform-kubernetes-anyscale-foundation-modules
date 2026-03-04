---
name: deploy-gcp-gke
description: Guide for deploying the Anyscale GCP GKE new cluster example from examples/gcp/gke-new_cluster/. Use when the user asks about deploying, setting up, or configuring GKE for Anyscale.
argument-hint: [step]
allowed-tools: Read, Bash, Grep, Glob
---

# Deploy GCP GKE for Anyscale

Walk the user through deploying the GCP GKE example at `examples/gcp/gke-new_cluster/`.

If `$ARGUMENTS` specifies a step (e.g., "terraform", "nginx", "register", "operator"), skip to that step. Otherwise, guide from the beginning.

## Known Issues

- Autopilot GKE clusters are not supported.
- Node auto-provisioning for GKE failing with GPU nodes: https://github.com/GoogleCloudPlatform/container-engine-accelerators/issues/407

## Prerequisites

Ensure the user has:
- [Google Cloud Project](https://cloud.google.com/resource-manager/docs/creating-managing-projects)
- [Google Cloud SDK/CLI](https://cloud.google.com/sdk/docs/install) (authenticated via `gcloud auth login`)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/docs/intro/install/)
- [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli/)
- Terraform >= 1.0

## Step 1: Configure Terraform Variables

The user needs a `terraform.tfvars` file in `examples/gcp/gke-new_cluster/`. Required variables:

```hcl
google_project_id = ""  # Your GCP project ID
google_region     = ""  # e.g. "us-central1"
```

Key optional variables:
- `gke_cluster_name` - Name of the GKE cluster (default: "anyscale-gke", must be under 23 chars, cannot start with a number)
- `gpu_instance_configs` - Map of GPU configs. Each needs `instance` (with `disk_type`, `gpu_driver_version`, `accelerator_count`, `accelerator_type`, `machine_type`) and `node_labels`. Default includes T4. Set to `{}` for CPU-only.
- `enable_filestore` - Enable Google Filestore for shared storage (default: false)
- `ingress_cidr_ranges` - CIDR blocks for ingress access (default: ["0.0.0.0/0"])
- `anyscale_k8s_namespace` - Kubernetes namespace for operator (default: "anyscale-operator")

See `gpu_instances.tfvars.example` for additional GPU type configs.

Read `examples/gcp/gke-new_cluster/variables.tf` for the full list.

## Step 2: Apply Terraform

Run from `examples/gcp/gke-new_cluster/`:

```shell
terraform init
terraform plan
terraform apply
```

Save the outputs - they contain commands for the remaining steps. Key outputs:
- `anyscale_registration_command` - Command to register the Anyscale cloud
- `helm_upgrade_command` - Command to install the Anyscale operator

## Step 3: Get GKE Credentials

Authenticate to the GKE cluster:

```shell
gcloud container clusters get-credentials <cluster-name> --region <region> --project <project-id>
```

## Step 4: Install Nginx Ingress Controller

Choose public or private facing:

For **public**:
```shell
helm repo add nginx https://kubernetes.github.io/ingress-nginx
helm upgrade ingress-nginx nginx/ingress-nginx \
  --version 4.12.1 \
  --namespace ingress-nginx \
  --values sample-values_nginx_gke_public.yaml \
  --create-namespace \
  --install
```

For **private**:
```shell
helm repo add nginx https://kubernetes.github.io/ingress-nginx
helm upgrade ingress-nginx nginx/ingress-nginx \
  --version 4.12.1 \
  --namespace ingress-nginx \
  --values sample-values_nginx_gke_private.yaml \
  --create-namespace \
  --install
```

Sample values files are at `examples/gcp/gke-new_cluster/sample-values_nginx_gke_public.yaml` and `sample-values_nginx_gke_private.yaml`.

Note: Nvidia device plugin is enabled by default in GKE when using GPU nodes, so no separate installation is needed. Cluster autoscaler is also enabled by default in GKE.

## Step 5: Register the Anyscale Cloud

Ensure `anyscale login` is done, then use the registration command from terraform output:

```shell
anyscale cloud register \
  --name <cloud_name> \
  --provider gcp \
  --region <gke_region> \
  --compute-stack k8s \
  --kubernetes-zones <gke_zones> \
  --anyscale-operator-iam-identity <service_account_email> \
  --cloud-storage-bucket-name <storage_bucket> \
  --project-id <project_id> \
  --vpc-name <vpc_name> \
  --file-storage-id <filestore_name> \
  --filestore-location <filestore_zone>
```

The `--file-storage-id` and `--filestore-location` flags are only included when `enable_filestore = true`.

Note the cloud deployment ID from the output - it's needed for the next step.

## Step 6: Install the Anyscale Operator

```shell
helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update
```

Then use the helm command from terraform output, replacing `<cloud-deployment-id>` with the ID from the cloud register step:

```shell
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --set-string global.cloudDeploymentId=<cloud-deployment-id> \
  --set-string global.cloudProvider=gcp \
  --set-string global.gcp.region=<gke_region> \
  --set-string global.auth.iamIdentity=<service_account_email> \
  --set-string workloads.serviceAccount.name=anyscale-operator \
  --namespace anyscale-operator \
  --create-namespace \
  --install
```

(Optional) For L4 GPU instances (`g2-standard-16`) to work, modify the Anyscale Operator `instance-types` ConfigMap to add:
```yaml
8CPU-32GB-1xL4:
  resources:
    CPU: 8
    GPU: 1
    accelerator_type:L4: 1
    memory: 32Gi
```

## Teardown

To destroy all resources:

```shell
# Remove helm releases first
helm uninstall anyscale-operator -n anyscale-operator
helm uninstall ingress-nginx -n ingress-nginx

# Then destroy terraform resources
terraform destroy
```

## Troubleshooting

If the user hits issues, check:
- `kubectl get nodes` - Verify nodes are ready
- `kubectl get pods -A` - Check for failing pods
- `gcloud container clusters describe <cluster> --region <region>` - Verify cluster state
- Ensure the GCP project has quota for the requested machine types and GPUs
