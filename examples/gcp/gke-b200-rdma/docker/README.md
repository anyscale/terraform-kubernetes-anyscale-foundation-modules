# GCP RDMA UCCL-EP Docker Middle Layer

This directory builds a CUDA container layer for GKE A4/B200 workloads that
need NCCL, UCCL, UCCL-EP, and runtime validation tools for GCP RDMA.

It is a self-contained Docker build context shipped with the
`examples/gcp/gke-b200-rdma` Terraform example. From the repository root,
change into this directory before running the build commands below:

```bash
cd examples/gcp/gke-b200-rdma/docker
```

The host and Kubernetes layer must already provide:

```text
NVIDIA GPUs exposed to the container
RDMA NICs exposed through GKE multi-networking
/usr/local/gib mounted from /home/kubernetes/bin/gib
/usr/local/nvidia mounted from /home/kubernetes/bin/nvidia
/dev/gdrdrv mounted from the host after the loader DaemonSet runs
```

The image does not create RDMA devices, load kernel modules, or install the
Google gIB host plugin. It only provides userspace libraries, environment
defaults, and validation entrypoints.

## Build

Build with a configurable base image:

```bash
BASE_IMAGE=nvcr.io/nvidia/pytorch:25.04-py3 \
IMAGE=gcp-b200-rdma-uccl:dev \
bash scripts/build_image.sh
```

Or build the concrete image directly:

```bash
docker build \
  -f Dockerfile.nvcr-pytorch-25.04-gcp-rdma-uccl \
  -t gcp-b200-rdma-uccl:dev \
  .
```

The build context must be this directory because the Dockerfiles copy `env/`
and `scripts/` into the image.

Default build arguments:

```text
BASE_IMAGE=nvcr.io/nvidia/pytorch:25.04-py3
UCCL_REF=v0.1.1
UCCL_FORCE_DMABUF=1
TORCH_CUDA_ARCH_LIST=10.0
```

The Dockerfiles default `UCCL_FORCE_DMABUF=1`. During the UCCL checkout step,
they patch `ep/include/common.hpp` with a guarded `#define USE_DMABUF` before
building UCCL-EP. This is required on GCP A4 RoCE because UCCL v0.1.1 does not
make runtime `USE_DMABUF=1` a compile-time define by itself.

## Cloud Build

The Cloud Build wrapper builds the same image into Artifact Registry:

```bash
PROJECT=YOUR_GCP_PROJECT_ID \
REGION=us-central1 \
REPOSITORY=gcp-rdma-images \
IMAGE_NAME=gcp-rdma-uccl \
TAG=dev \
bash scripts/cloud_build_image.sh
```

It enables `cloudbuild.googleapis.com` and `artifactregistry.googleapis.com`,
creates the Artifact Registry Docker repository when needed, and submits this
directory as the build context.

## Runtime Environment

The main environment file is:

```bash
source /opt/gcp-middle/env/gcp_rdma_uccl_env.sh
```

It sets CUDA, gIB, NCCL, and UCCL defaults used by the validation scripts:

```text
GIB_HOME=/usr/local/gib
NVIDIA_HOST_HOME=/usr/local/nvidia
GLOO_SOCKET_IFNAME=eth0
UCCL_SOCKET_IFNAME=eth0
USE_DMABUF=1
UCCL_FORCE_DMABUF=1
PER_EXPERT_BATCHING=1
```

## Validation

Inside a GKE A4/B200 worker pod:

```bash
/opt/gcp-middle/scripts/validate_gcp_rdma_devices.sh
PYTHON=python /opt/gcp-middle/scripts/validate_uccl_imports.sh
```

For UCCL-EP, run matching commands on each worker pod. Example for two nodes:

```bash
PYTHON=python \
NNODES=2 NPROC_PER_NODE=8 NODE_RANK=0 MASTER_ADDR=<worker-0-pod-ip> \
  /opt/gcp-middle/scripts/validate_uccl_ep.sh ll

PYTHON=python \
NNODES=2 NPROC_PER_NODE=8 NODE_RANK=0 MASTER_ADDR=<worker-0-pod-ip> \
  /opt/gcp-middle/scripts/validate_uccl_ep.sh ht
```

Run the same commands on the second worker with `NODE_RANK=1`.

## Notes

This image was designed for GKE A4/B200 RDMA environments where GCP gIB,
GPUDirect RDMA, and multi-networking are configured at the cluster layer. The
container intentionally keeps those host responsibilities outside the image.
