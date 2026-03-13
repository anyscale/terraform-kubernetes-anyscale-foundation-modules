---
name: deploy-aws-eks
description: Guide for deploying the Anyscale AWS EKS public example from examples/aws/eks-public/. Use when the user asks about deploying, setting up, or configuring EKS for Anyscale.
argument-hint: [step]
allowed-tools: Read, Bash, Grep, Glob
---

# Deploy AWS EKS for Anyscale

Walk the user through deploying the AWS EKS example at `examples/aws/eks-public/`.

If `$ARGUMENTS` specifies a step (e.g., "terraform", "autoscaler", "lbc", "nginx", "gpu", "register", "operator"), skip to that step. Otherwise, guide from the beginning.

## Prerequisites

Ensure the user has:
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (configured with credentials)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/docs/intro/install/)
- [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli/)
- Terraform >= 1.0

## Step 1: Configure Terraform Variables

The user needs a `terraform.tfvars` file in `examples/aws/eks-public/`. All variables have defaults, but key ones to review:

```hcl
aws_region       = "us-east-2"           # AWS region
eks_cluster_name = "anyscale-eks-public"  # Cluster name
```

Key optional variables:
- `eks_cluster_version` - Kubernetes version (default: "1.32")
- `gpu_instance_types` - Map of GPU configs. Each needs `product_name` and `instance_types` list. Default includes T4 (`g4dn.4xlarge`). Set to `{}` for CPU-only.
- `enable_efs` - Enable EFS for shared storage (default: false)
- `node_group_disk_size` - Disk size in GB (default: 500)

See `gpu_instances.tfvars.example` for additional GPU type configs.

Read `examples/aws/eks-public/variables.tf` for the full list.

## Step 2: Apply Terraform

Run from `examples/aws/eks-public/`:

```shell
terraform init
terraform plan
terraform apply
```

Save the outputs - they contain commands for the remaining steps. Key outputs:
- `anyscale_registration_command` - Command to register the Anyscale cloud
- `helm_upgrade_command` - Command to install the Anyscale operator
- `eks_cluster_name` - Cluster name for helm chart values
- `aws_region` - Region for helm chart values

## Step 3: Get EKS Credentials

```shell
aws eks update-kubeconfig --region <aws_region> --name <eks_cluster_name>
```

## Step 4: Install Cluster Autoscaler

```shell
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade cluster-autoscaler autoscaler/cluster-autoscaler \
  --version 9.46.0 \
  --namespace kube-system \
  --set awsRegion=<aws_region> \
  --set 'autoDiscovery.clusterName'=<eks_cluster_name> \
  --install
```

## Step 5: Install AWS Load Balancer Controller

```shell
helm repo add eks https://aws.github.io/eks-charts
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 1.13.2 \
  --namespace kube-system \
  --set clusterName=<eks_cluster_name> \
  --install
```

## Step 6: Install Nginx Ingress Controller

```shell
helm repo add nginx https://kubernetes.github.io/ingress-nginx
helm upgrade ingress-nginx nginx/ingress-nginx \
  --version 4.12.1 \
  --namespace ingress-nginx \
  --values sample-values_nginx.yaml \
  --create-namespace \
  --install
```

The sample values file is at `examples/aws/eks-public/sample-values_nginx.yaml`.

## Step 7 (Optional): Install Nvidia Device Plugin

Only needed if using GPU node pools. The sample values file is at `examples/aws/eks-public/sample-values_nvdp.yaml`.

```shell
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm upgrade nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --version 0.17.1 \
  --values sample-values_nvdp.yaml \
  --create-namespace \
  --install
```

## Step 8: Register the Anyscale Cloud

Ensure `anyscale login` is done, then use the registration command from terraform output:

```shell
anyscale cloud register --provider aws \
  --name <cloud_name> \
  --compute-stack k8s \
  --region <aws_region> \
  --s3-bucket-id <s3_bucket_id> \
  --efs-id <efs_id> \
  --kubernetes-zones <zones> \
  --anyscale-operator-iam-identity <node_group_role_arn>
```

The `--efs-id` flag is only included when `enable_efs = true`.

Note the cloud deployment ID from the output - it's needed for the next step.

## Step 9: Install the Anyscale Operator

```shell
helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update
```

Then use the helm command from terraform output, replacing `<cloud-deployment-id>` with the ID from the cloud register step:

```shell
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --set-string global.cloudDeploymentId=<cloud-deployment-id> \
  --set-string global.cloudProvider=aws \
  --set-string global.aws.region=<aws_region> \
  --set-string workloads.serviceAccount.name=anyscale-operator \
  --namespace anyscale-operator \
  --create-namespace \
  --install
```

## Teardown

To destroy all resources:

```shell
# Remove helm releases first
helm uninstall anyscale-operator -n anyscale-operator
helm uninstall nvdp -n nvidia-device-plugin
helm uninstall ingress-nginx -n ingress-nginx
helm uninstall aws-load-balancer-controller -n kube-system
helm uninstall cluster-autoscaler -n kube-system

# Then destroy terraform resources
terraform destroy
```

## Troubleshooting

If the user hits issues, check:
- `kubectl get nodes` - Verify nodes are ready
- `kubectl get pods -A` - Check for failing pods
- `aws eks describe-cluster --name <cluster> --region <region>` - Verify cluster state
- Ensure the AWS account has quota/limits for the requested instance types
