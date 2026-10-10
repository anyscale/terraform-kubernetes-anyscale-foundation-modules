# GCP GKE A4/B200 GPUDirect RDMA Module

This module creates the GCP infrastructure required before Kubernetes can
expose GPUDirect RDMA devices to Pods running on GKE A4/B200 workers.

It is intentionally scoped to the GKE and node infrastructure layer. It expects
an existing host/control-plane VPC and subnetwork, then creates the extra
gVNIC/RDMA networks, the GKE cluster, an optional CPU head pool, and one
A4/B200 worker pool.

## What It Creates

```text
google_compute_network for the extra Titanium gVNIC
google_compute_subnetwork for the extra Titanium gVNIC
google_compute_network with a ZONE-vpc-roce network profile for RDMA
RDMA subnetworks for the requested RDMA rails
google_container_cluster with multi-networking and Dataplane V2
optional CPU head google_container_node_pool
A4/B200 google_container_node_pool with one gVNIC and RDMA additional node networks
```

The default worker layout is for `a4-highgpu-8g`:

```text
eth0: default GKE host network
eth1: extra Titanium gVNIC network
eth2..eth9: RDMA device networks backed by mlx5_0..mlx5_7
8 NVIDIA B200 GPUs
```

The module defaults to a fixed-size Spot worker pool, `COS_CONTAINERD`,
automatic GPU driver installation, disabled node auto-repair/auto-upgrade, and
`disable-legacy-endpoints` node metadata. These defaults match
high-performance RDMA validation flows, but all major sizing, label, service
account, reservation, autoscaling, and node-management choices are configurable.

## Example

```hcl
module "b200_rdma_gke" {
  source = "./modules/gcp-gke-b200-rdma"

  project_id      = "my-gcp-project"
  region          = "us-central1"
  zone            = "us-central1-b"
  cluster_name    = "b200-rdma-gke-us-central1"
  host_network    = "gke-host-vpc"
  host_subnetwork = "gke-host-subnet"

  gvnic_network_name          = "b200-rdma-gvnic-us-central1"
  gvnic_subnetwork_name       = "b200-rdma-gvnic-us-central1-subnet"
  rdma_network_name           = "b200-rdma-us-central1-b"
  rdma_subnetwork_name_prefix = "b200-rdma-us-central1-b-subnet"

  worker_node_count = 2
  workload_name     = "b200-rdma"

  resource_labels = {
    environment = "dev"
    workload    = "b200-rdma"
  }
}
```

When the RDMA network profile does not follow the default
`projects/PROJECT/global/networkProfiles/ZONE-vpc-roce` naming, set
`rdma_network_profile` explicitly.

To consume a specific zonal Compute Engine reservation for the A4/B200 workers:

```hcl
worker_reservation_affinity = {
  type   = "SPECIFIC_RESERVATION"
  key    = "compute.googleapis.com/reservation-name"
  values = ["my-b200-reservation"]
}
```

To use GKE autoscaling instead of a fixed worker node count:

```hcl
worker_autoscaling = {
  enabled         = true
  min_node_count  = 0
  max_node_count  = 2
  location_policy = "ANY"
}
```

## Follow-On Kubernetes Layer

After this module is applied, install the Kubernetes layer required by your GKE
RDMA stack. At minimum this usually includes:

```text
Google GPUDirect RDMA or gIB host installer components
GKE multi-network objects that map the gVNIC and RDMA subnetworks into Pods
Any workload-specific GPU/RDMA validation Jobs or Ray/Anyscale workloads
```

With the add-ons installed, A4/B200 worker pods should see:

```text
nvidia.com/gpu: 8
eth2..eth9 RDMA interfaces
mlx5_0..mlx5_7 verbs devices
/usr/local/gib from the GKE gIB installer
/dev/gdrdrv after the loader DaemonSet runs
```

## Validation

Run in a Terraform-capable environment:

```bash
terraform fmt -recursive
terraform init
terraform validate
terraform plan
```

After apply:

```bash
terraform output get_credentials_command
kubectl get nodes -l rdma=true -o wide
kubectl describe node <node-name> | egrep 'nvidia.com/gpu|cloud.google.com/gke-accelerator'
```

Then validate the runtime image or workload layer with your chosen NCCL, UCCL,
or Ray-based collectives tests.

## Boundary

This module validates the GCP RDMA infrastructure path used by NCCL/gIB and
UCCL/DeepEP with DMA-BUF. It does not build container images, configure
Anyscale resources, or claim native GPU-initiated IBGDA/GDAKI support.
