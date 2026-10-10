# GKE A4/B200 GPUDirect RDMA Example

This example instantiates the `modules/gcp-gke-b200-rdma` module with a
two-node A4/B200 worker pool and the default eight RDMA rails per worker.

The values in `terraform.tfvars.example` are placeholders. Copy them into a
real `terraform.tfvars` file or pass equivalent values through your CI system
before applying.

If your B200 capacity is reserved, set `worker_reservation_affinity` in
`terraform.tfvars`. If you want GKE to scale the worker pool dynamically, set
`worker_autoscaling` and keep `worker_node_count` as the fixed-size fallback.

## Prerequisites

```text
Google Cloud project with quota for A4/B200 workers in the target zone
Existing host/control-plane VPC and subnetwork for the GKE cluster
Terraform credentials with Compute Engine and GKE permissions
GKE zone with a matching ZONE-vpc-roce network profile
```

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars for your project, region, zone, and host VPC.

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

After apply:

```bash
terraform output get_credentials_command
kubectl get nodes -l rdma=true -o wide
```

## Build the RDMA/UCCL Runtime Image

The self-contained `docker/` build context installs UCCL/UCCL-EP and the
runtime validation tools for the GKE RDMA environment. Build locally and push
to an Artifact Registry repository accessible to the worker nodes:

```bash
cd docker

export IMAGE_URI=<region>-docker.pkg.dev/<project>/<repository>/gcp-b200-rdma-uccl:1
docker build \
  -f Dockerfile.nvcr-pytorch-25.04-gcp-rdma-uccl \
  -t "$IMAGE_URI" \
  .
docker push "$IMAGE_URI"
```

Alternatively, `scripts/cloud_build_image.sh` builds and publishes the same
context with Cloud Build. See [`docker/README.md`](docker/README.md) for the
required GKE host integration, Cloud Build parameters, and validation commands.

The Terraform layer creates the GKE cluster, gVNIC/RDMA networks, and node
pools. You still need to install the Kubernetes RDMA/multi-network add-ons and
run workload-level validation before relying on the cluster for production
collectives.
