# AWS EFA UCCL-EP Docker Middle Layer

This directory builds a CUDA container layer for AWS EFA workloads that need
NCCL, UCCL, UCCL-EP, and basic runtime validation tools.

It is a self-contained Docker build context shipped with the
`examples/aws/eks-public-efa` Terraform example. From the repository root,
change into this directory before running the build commands below:

```bash
cd examples/aws/eks-public-efa/docker
```

The image installs:

```text
AWS EFA userspace and libfabric EFA provider
aws-ofi-nccl for NCCL over EFA
UCCL and UCCL-EP
DeepEP compatibility wrapper backed by UCCL-EP
Runtime environment setup
EFA, NCCL, and UCCL validation scripts
```

Validation scripts and benchmark assets are baked into `/opt/efa-middle`, but
they are not run during image build or container startup.

## Requirements

The host or Kubernetes pod must provide the hardware and kernel-side devices:

```text
EFA-capable GPU instance, such as p5.48xlarge
NVIDIA GPUs exposed to the container
/dev/infiniband mounted into the container
EFA/RDMA devices exposed by the AWS EFA Kubernetes device plugin or host runtime
Network placement compatible with EFA, such as a single AZ and placement group
```

The container provides userspace libraries and validation entrypoints only. It
does not create EFA devices or load host kernel modules.

## Build

Build with a configurable base image:

```bash
BASE_IMAGE=anyscale/ray:2.55.1-slim-py312-cu128 \
IMAGE=aws-efa-uccl-middle:dev \
DOCKER=docker \
bash scripts/build_image.sh
```

Or build the concrete Anyscale Ray image directly:

```bash
docker build \
  -f Dockerfile.anyscale-ray-2.55.1-cu128-efa-uccl \
  -t anyscale-ray-2.55.1-cu128-torch2.8-efa-uccl:dev \
  .
```

The build context must be this directory because the Dockerfiles copy `env/`,
`scripts/`, and `detect_compute_nodes.py` into the image. The Ray all-reduce
benchmark is downloaded from a pinned gist URL during the image build.

Default build arguments:

```text
EFA_INSTALLER_VERSION=1.43.2
AWS_OFI_NCCL_VERSION=1.19.2
UCCL_REF=v0.1.1
TORCH_VERSION=2.8.0
TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128
```

## Runtime Environment

The main environment file is:

```bash
source /opt/efa-middle/env/aws_efa_uccl_env.sh
```

It sets the EFA/libfabric, NCCL, CUDA, and bootstrap-interface defaults used by
the validation scripts:

```text
FI_PROVIDER=efa
FI_EFA_USE_DEVICE_RDMA=1
NCCL_NET_PLUGIN=libnccl-net.so
NCCL_SOCKET_IFNAME=eth0
GLOO_SOCKET_IFNAME=eth0
UCCL_SOCKET_IFNAME=eth0
```

`eth0` is used for TCP bootstrap and metadata traffic. EFA payload transport is
selected separately through libfabric and the NCCL OFI plugin.

## Local Container Smoke Test

For a manually started container, mount GPUs and EFA devices:

```bash
docker run --rm -it \
  --gpus all \
  --network host \
  --ipc host \
  --ulimit memlock=-1:-1 \
  --device /dev/infiniband \
  aws-efa-uccl-middle:dev \
  bash
```

Inside the container:

```bash
/opt/efa-middle/scripts/validate_middle_layer_local.sh
```

This checks local GPU visibility, EFA/RDMA devices, libfabric EFA provider
availability, and Python imports. It does not run multi-node collectives.

## Workspace Validation

After a Ray workspace or cluster starts, run validation from the Ray head:

```bash
/opt/efa-middle/scripts/validate_compute_nodes.py all \
  --nnodes 2 \
  --nproc-per-node 8
```

The `all` action runs:

```text
EFA/GPU device detection on each compute node
Ray-based NCCL all-reduce across the requested compute nodes
UCCL-EP low-latency benchmark across the requested compute nodes
UCCL-EP high-throughput benchmark across the requested compute nodes
```

The script discovers Ray compute nodes and then uses SSH for per-node checks.
Defaults are `SSH_TARGET=ip` and `SSH_PORT=2222`; override with environment
variables or command flags when needed.

Useful examples:

```bash
# Device detection only
/opt/efa-middle/scripts/validate_compute_nodes.py devices

# Ray NCCL all-reduce only
/opt/efa-middle/scripts/validate_compute_nodes.py all-reduce --nnodes 2

# UCCL-EP modes only
/opt/efa-middle/scripts/validate_compute_nodes.py uccl-ll --nnodes 2
/opt/efa-middle/scripts/validate_compute_nodes.py uccl-ht --nnodes 2
```

`EXPECTED_EFA_DEVICES` is intentionally not baked into the image. Set it only
when you want to enforce a specific instance shape:

```bash
EXPECTED_EFA_DEVICES=32 \
/opt/efa-middle/scripts/validate_compute_nodes.py devices
```

## Kubernetes Example

`examples/k8s-efa-uccl-validation-job.yaml` contains a minimal EKS validation
job shape. Replace `REPLACE_WITH_AWS_EFA_UCCL_IMAGE` with the image you built.

The example requests one full `p5.48xlarge` worker pod:

```yaml
resources:
  limits:
    nvidia.com/gpu: "8"
    vpc.amazonaws.com/efa: "32"
```

Adjust those resource limits for other EFA-capable instance types.

## Files

```text
Dockerfile.aws-efa-uccl.fragment
  Generic Dockerfile fragment that accepts BASE_IMAGE.

Dockerfile.anyscale-ray-2.55.1-cu128-efa-uccl
  Concrete image recipe based on anyscale/ray:2.55.1-slim-py312-cu128.

env/aws_efa_uccl_env.sh
  Runtime environment defaults for EFA, NCCL, UCCL, and Ray validation.

detect_compute_nodes.py
  Helper for discovering Ray compute nodes.

scripts/build_image.sh
  Build helper for the generic Dockerfile fragment.

scripts/validate_compute_nodes.py
  Main post-start validation entrypoint for Ray workspaces.

scripts/validate_efa_devices.sh
  Local GPU, EFA/RDMA, libfabric, and topology checks.

scripts/validate_nccl_all_reduce.sh
  Ray-based NCCL all-reduce validation.

scripts/validate_uccl_ep.sh
  UCCL-EP low-latency and high-throughput validation.

scripts/validate_uccl_imports.sh
  Python import check for torch, uccl.ep, and deep_ep.
```
