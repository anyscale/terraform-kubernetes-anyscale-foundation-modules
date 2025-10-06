# Anyscale Nebius MK8s Example - Hybrid Architecture with Autoscaling

This example creates the resources to run Anyscale on Nebius Managed Kubernetes (MK8s) with a hybrid networking architecture optimized for cost and scalability through autoscaling.

## Architecture Overview

This deployment uses a **hybrid architecture** with one dedicated system node and autoscaling workload nodes:

```
├─ Control Plane: Public endpoint (Managed by Nebius)
├─ System Node (1x): Public IP - Always on
│  ├─ Instance: cpu-e2-8vcpu-32gb
│  ├─ Hosts: kube-system, anyscale-operator, ingress-nginx
│  └─ Provides: NAT gateway via Cilium for private nodes
├─ Workload Nodes (6 types): Private IPs only
│  ├─ Autoscaling: 0-10 nodes per type (configurable)
│  ├─ CPU: cpu-e2-8vcpu-32gb, cpu-e2-16vcpu-64gb, cpu-e2-32vcpu-128gb
│  └─ GPU: gpu-h100-sxm, gpu-h200-sxm, gpu-l40s-a
└─ NFS Server: Private IP (optional)
```

**Benefits:**
- **Cost-efficient**: Workload nodes scale to zero when idle
- **Public IP optimization**: Uses only 2 of 3 quota (system + load balancer)
- **Automatic egress**: Private nodes route through system node via Cilium
- **Production-ready**: Dedicated system node ensures cluster stability

## Prerequisites

### Required Tools

* [Nebius CLI](https://docs.nebius.ai/cli/) (`nebius`)
* [Terraform](https://www.terraform.io/downloads) (>= 1.5.0)
* [kubectl](https://kubernetes.io/docs/tasks/tools/)
* [Helm](https://helm.sh/docs/intro/install/)

### Nebius Account Requirements

* Active Nebius account with billing enabled
* Project with the following quotas:
  - Compute: 10+ vCPUs, 2+ GPUs (for workload nodes)
  - Public IPs: 3 total (1 for system node, 1 for load balancer, 1 for control plane)
  - VPC subnet with available IP addresses (/24 or larger recommended)

### Anyscale Account

* Active Anyscale account (sign up at https://console.anyscale.com)
* Anyscale CLI token (from Settings → API Keys)

## Getting Started

### Step 1: Configure Nebius CLI

Initialize and authenticate with Nebius:

```bash
# Install Nebius CLI (if not already installed)
curl -sSL https://storage.ai.nebius.cloud/nebius/install.sh | bash

# Initialize CLI and authenticate
nebius init

# Follow prompts to:
# - Select region (e.g., eu-north1)
# - Authenticate with OAuth
# - Select tenant and project
```

Verify authentication:

```bash
nebius iam get-access-token
```

### Step 2: Prepare Configuration

Copy the example configuration and fill in your details:

```bash
cp config.example.yaml config.yaml
```

Edit `config.yaml` with your values:

```yaml
nebius:
  tenant_id: "tenant-xxxxx"        # From: nebius iam get-access-token --format json | jq -r .tenant_id
  project_id: "project-xxxxx"      # From: nebius project list --format json | jq -r '.items[0].metadata.id'
  region: "eu-north1"
  vpc_subnet_id: "vpcsubnet-xxxxx" # From: nebius vpc subnet list --parent-id <project-id>

ssh:
  username: "ubuntu"
  public_key: "ssh-ed25519 AAAAC3..."  # From: cat ~/.ssh/id_ed25519.pub

anyscale:
  cloud_name: "my-nebius-production"
  cloud_deployment_id: "cldrsrc_xxxxx"  # Get in Step 4
  cli_token: "aph0_xxxxx"               # From Anyscale Console → Settings → API Keys

autoscaling:
  min_nodes: 0   # Scale to zero when idle (recommended)
  max_nodes: 10  # Maximum nodes per instance type
```

**Helper commands to get configuration values:**

```bash
# Tenant ID
nebius iam get-access-token --format json | jq -r .tenant_id

# Project ID
nebius project list --format json | jq -r '.items[0].metadata.id'

# Subnet ID (or create new subnet if none exist)
nebius vpc subnet list --parent-id <project-id> --format json | jq -r '.items[0].metadata.id'

# SSH public key
cat ~/.ssh/id_ed25519.pub
```

### Step 3: Deploy Infrastructure Layer

The infrastructure layer creates the NFS server and object storage bucket:

```bash
# Set up Nebius environment
source environment.sh

# Deploy infrastructure
cd prepare
terraform init
terraform plan
terraform apply
```

**Resources created:**
- NFS server (cpu-e2-2vcpu-8gb with 93GB disk) for persistent storage
- S3-compatible object storage bucket for Anyscale artifacts
- Service account and access keys for S3 access

**Note the outputs** - you'll need the bucket name for Anyscale registration.

### Step 4: Register Anyscale Cloud

Before deploying the Kubernetes cluster, register the cloud in Anyscale:

1. **Get Anyscale CLI Token:**
   - Visit https://console.anyscale.com
   - Go to: Settings → API Keys
   - Click "Create API Key"
   - Copy the token (starts with `aph0_`)

2. **Use the registration script:**

```bash
cd ..  # Return to root directory
./register.sh
```

The script will:
- Open Anyscale Console in your browser
- Guide you through cloud registration
- Prompt you to paste the Cloud Deployment ID

3. **Copy the Cloud Deployment ID** (starts with `cldrsrc_`) from the Anyscale Console

4. **Update config.yaml** with both values:

```yaml
anyscale:
  cloud_deployment_id: "cldrsrc_xxxxx"  # From registration
  cli_token: "aph0_xxxxx"               # From API keys
```

### Step 5: Deploy Kubernetes Cluster

Now deploy the MK8s cluster with the Anyscale operator:

```bash
cd deploy
terraform init
terraform plan
terraform apply
```

**Resources created:**
- Nebius MK8s cluster (Kubernetes 1.31)
- 1 system node group (fixed count: 1, public IP)
- 6 workload node groups (autoscaling 0-10, private IPs):
  - 3 CPU types: 8vCPU, 16vCPU, 32vCPU
  - 3 GPU types: H100, H200, L40S
- Anyscale operator (via Nebius Applications API)
- Ingress-nginx load balancer
- IAM service accounts and permissions

**Deployment time:** ~10-15 minutes

**Note the cluster ID** from the terraform output for the next step.

### Step 6: Configure kubectl Access

Get credentials for your cluster:

```bash
# Using cluster ID from terraform output
nebius mk8s cluster get-credentials <cluster-id> --parent-id <project-id>

# Verify connection
kubectl get nodes
```

**Expected output:**
```
NAME                                     STATUS   ROLES    AGE   VERSION
mk8snode-xxxxx-system                    Ready    <none>   5m    v1.31.x
```

You should see 1 system node. Workload nodes will appear when Anyscale creates workspaces.

### Step 7: Verify Deployment

Check that all components are running:

```bash
# Check system node labels
kubectl get nodes --show-labels | grep "anyscale.com/node-role=system"

# Check Anyscale operator
kubectl get pods -n anyscale-system

# Expected output:
# NAME                                          READY   STATUS    RESTARTS   AGE
# anyscale-operator-xxxxx                       2/2     Running   0          5m
# ingress-nginx-controller-xxxxx                1/1     Running   0          5m
```

Check node groups:

```bash
nebius mk8s node-group list --parent-id <cluster-id> --format json | jq -r '.items[].metadata.name'

# Expected: 7 node groups (1 system + 6 workload types)
```

### Step 8: Complete Anyscale Registration

Return to the Anyscale Console and complete the cloud registration:

1. Navigate to your cloud in Anyscale Console
2. The operator should auto-detect and show as connected
3. Cloud status should change to "Active"

### Step 9: Verify Cloud Health

Run the Anyscale cloud verification to check the deployment:

```bash
anyscale cloud verify --name <your-cloud-name>
```

When prompted:
- **Select context number**: Enter `2` (or the number for `nebius-mk8s-anyscale-cluster`)
- **Enter namespace**: Enter `anyscale-system`

**Expected output:**
```
Verification result:
Operator Pod Installed: PASSED
Operator Health: PASSED
Operator Identity: FAILED
File Storage: PASSED
Gateway Support: PASSED
NGINX Ingress: PASSED
```

**Note about Operator Identity failure:**

The "Operator Identity: FAILED" warning is expected for Nebius Kubernetes clouds. This check looks for `anyscale_operator_iam_identity` which is used on AWS/GCP for IAM role-based authentication but is not applicable to Nebius Managed Kubernetes with generic Kubernetes authentication. This failure does **not** prevent the cloud from functioning correctly.

All other checks should pass. If any other check fails, see the Troubleshooting section.

### Step 10: Create Test Workspace

Test the deployment by creating a workspace:

1. In Anyscale Console, create a new workspace
2. Select a compute config with "CPU-E2-16vcpu-64gb"
3. Click "Create"

Monitor node provisioning:

```bash
kubectl get nodes --watch

# You should see a new node appear after ~3-5 minutes:
# mk8snode-xxxxx-cpu-e2-16vcpu-64gb   Ready   <none>   2m   v1.31.x
```

Verify node labels:

```bash
kubectl get nodes --show-labels | grep "anyscale.com/instance-type"

# Should show: anyscale.com/instance-type=cpu-e2-16vcpu-64gb
```

## Architecture Details

### System Node Configuration

The system node is a dedicated, always-on node that:
- Hosts critical cluster services (kube-system, anyscale-operator, ingress-nginx)
- Has a public IP for cluster egress traffic
- Uses Cilium CNI to provide automatic NAT for private workload nodes
- Is excluded from Anyscale workload scheduling via node labels

### Workload Node Configuration

Workload nodes are:
- Private IP only (no direct internet access)
- Autoscaling (0-10 nodes per type by default)
- Labeled with `anyscale.com/instance-type` for precise pod placement
- Configured with taints to prevent system pods from scheduling

### Instance Types Available

**CPU Instances** (Intel Ice Lake):
- `CPU-E2-8vcpu-32gb`: 7 vCPU, 30 GiB memory
- `CPU-E2-16vcpu-64gb`: 15 vCPU, 62 GiB memory
- `CPU-E2-32vcpu-128gb`: 31 vCPU, 126 GiB memory

**GPU Instances**:
- `GPU-H100-1gpu-16vcpu-200gb`: 1x NVIDIA H100 SXM, 15 vCPU, 190 GiB memory
- `GPU-H200-1gpu-16vcpu-200gb`: 1x NVIDIA H200 SXM, 15 vCPU, 190 GiB memory
- `GPU-L40S-A-1gpu-16vcpu-64gb`: 1x NVIDIA L40S PCIe, 15 vCPU, 62 GiB memory

To customize instance types, edit `values/anyscale-operator.yaml`.

## Cost Optimization

### Idle State Cost

When no workloads are running (all workload nodes scaled to zero):
- System node (cpu-e2-8vcpu-32gb): ~$50/month
- NFS server (cpu-e2-2vcpu-8gb + 93GB disk): ~$15/month
- Object storage: ~$0.50/GB/month (usage-based)
- **Total idle cost: ~$65/month + storage**

### Active Workload Cost

Workload nodes are billed per-second when running:
- CPU nodes: $0.05-0.20/hour
- GPU H100/H200: $3-5/hour
- GPU L40S: $1-2/hour

With autoscaling to zero, you only pay for compute when Anyscale workspaces are active.

## Customization

### Adjusting Autoscaling Limits

To change autoscaling behavior, edit `config.yaml`:

```yaml
autoscaling:
  min_nodes: 1   # Keep 1 node warm for faster startup
  max_nodes: 20  # Allow more concurrent workloads
```

Then apply changes:

```bash
cd deploy
terraform apply
```

### Adding/Removing Instance Types

Edit `deploy/main.tf` to modify the `instance_types` local variable:

```hcl
locals {
  instance_types = {
    "cpu-e2-8vcpu-32gb" = {
      platform = "cpu-e2"
      preset   = "8vcpu-32gb"
    }
    # Add more types here
  }
}
```

Also update `values/anyscale-operator.yaml` to add the corresponding Anyscale instance type configuration.

### Disabling NFS

To deploy without NFS, edit `config.yaml`:

```yaml
nebius:
  nfs:
    enabled: false
```

Then re-run:

```bash
cd prepare
terraform apply
```

## Troubleshooting

### Nodes Not Provisioning

**Check autoscaler logs:**
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=cluster-autoscaler --tail=100
```

**Common causes:**
- Quota limits exceeded (check with `nebius quota get --parent-id <project-id>`)
- Node group misconfigured
- Insufficient hardware resources (temporary, will resolve when capacity available)

### Workspace Creation Fails

**Check operator logs:**
```bash
kubectl logs -n anyscale-system -l app.kubernetes.io/name=anyscale-operator --tail=100
```

**Check pod status:**
```bash
kubectl get pods --all-namespaces | grep -v Running
kubectl describe pod <pod-name> -n <namespace>
```

### Instance Type Mismatch

**Verify node labels match operator config:**
```bash
# Check node labels
kubectl get nodes --show-labels | grep anyscale.com/instance-type

# Check operator instance types
kubectl get configmap -n anyscale-system -o yaml | grep -A 10 "additionalInstanceTypes"
```

If there's a mismatch, the `values/anyscale-operator.yaml` file may need updating.

### Public IP Quota Exceeded

This deployment uses 2 public IPs (system node + load balancer). If you hit quota limits:

1. Check current usage: `nebius vpc address list --parent-id <project-id>`
2. Request quota increase via Nebius Console
3. Or deploy without public IPs on workload nodes (already the default in this example)

## Cleaning Up

To destroy all resources:

```bash
# Destroy cluster (this also removes the operator)
cd deploy
terraform destroy

# Destroy infrastructure
cd ../prepare
terraform destroy
```

**Warning:** This will delete all data including the NFS server and object storage bucket. Back up any important data first.

## Additional Resources

- [Nebius Documentation](https://docs.nebius.ai)
- [Nebius MK8s Guide](https://docs.nebius.ai/managed-kubernetes/)
- [Anyscale Documentation](https://docs.anyscale.com)
- [Anyscale on Kubernetes](https://docs.anyscale.com/platform/kubernetes/)

## Support

For issues specific to this example:
- Open an issue in this repository

For Nebius platform issues:
- Contact Nebius support via the Console

For Anyscale platform issues:
- Contact Anyscale support or visit https://docs.anyscale.com

---

**Note:** This example is provided as a starting point. You should review and modify the configuration to meet your organization's security and infrastructure requirements.
