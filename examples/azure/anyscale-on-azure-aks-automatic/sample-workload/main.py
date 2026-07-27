"""Smoke-test workload for an Anyscale-on-AKS-Automatic cloud.

Proves three things end to end, in order of how likely they are to be the
thing that is broken:

  1. The Anyscale operator scheduled a Ray head pod at all. On AKS Automatic
     that means deployment safeguards did NOT reject it — the single most
     common first-deploy failure (see the exclusion patch in aks.tf).
  2. Karpenter provisioned worker capacity on demand. There are no
     pre-provisioned node pools in this stack; every worker node is created
     in response to a pending Ray task.
  3. Optionally, that a GPU node came up with working AKS-managed NVIDIA
     drivers — the replacement for the GPU operator chart in the
     `anyscale-on-azure-new-aks` sibling.

Run it with `anyscale job submit -f job.yaml --wait`, or from a workspace
terminal with `python main.py`.
"""

import os
import platform
import socket

import ray


@ray.remote
def whoami() -> dict:
    """Runs on a Ray worker — i.e. on a Karpenter-provisioned node."""
    return {
        "hostname": socket.gethostname(),
        "node_ip": ray.util.get_node_ip_address(),
        "python": platform.python_version(),
    }


@ray.remote(num_gpus=1)
def gpu_check() -> dict:
    """Runs only on a GPU node, and only if a GPU NodePool exists.

    Importing torch here rather than at module scope keeps the CPU-only path
    working on images without it.
    """
    import torch

    return {
        "hostname": socket.gethostname(),
        "cuda_available": torch.cuda.is_available(),
        "device_count": torch.cuda.device_count(),
        "device_name": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
    }


def main() -> None:
    ray.init()

    print("=== cluster ===")
    print(f"ray version:  {ray.__version__}")
    print(f"cluster CPUs: {ray.cluster_resources().get('CPU')}")
    print(f"cluster GPUs: {ray.cluster_resources().get('GPU', 0)}")

    # Enough tasks that Ray must scale out past the head node, which is what
    # forces Karpenter to provision.
    print("\n=== workers (forces Karpenter to provision) ===")
    for result in ray.get([whoami.remote() for _ in range(8)]):
        print(result)

    # Opt in with RUN_GPU_CHECK=1 once a gpu_nodepool_configs entry exists.
    # Without one this task would stay Pending forever, so it is not the
    # default.
    if os.environ.get("RUN_GPU_CHECK") == "1":
        print("\n=== gpu ===")
        print(ray.get(gpu_check.remote()))
    else:
        print("\n=== gpu ===")
        print("skipped — set RUN_GPU_CHECK=1 and configure gpu_nodepool_configs to test GPUs")

    print("\nOK")


if __name__ == "__main__":
    main()
