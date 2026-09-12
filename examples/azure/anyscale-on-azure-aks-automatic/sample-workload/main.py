"""Smoke-test workload for an Anyscale-on-AKS-Automatic cloud.

Proves three things end to end, in order of how likely they are to be the
thing that is broken:

  1. The Anyscale operator scheduled a Ray head pod at all. On AKS Automatic
     that means deployment safeguards did NOT reject it — the single most
     common first-deploy failure (see the exclusion patch in aks.tf).
  2. Karpenter provisioned worker capacity on demand, AND that work actually
     landed on it. There are no pre-provisioned node pools in this stack;
     every worker node is created in response to a pending Ray task. The
     fan-out below holds CPU slots long enough that the head cannot drain the
     queue on its own, then checks the reported hostnames and exits non-zero
     if nothing ran off-head.
  3. Optionally, that a GPU node came up with working AKS-managed NVIDIA
     drivers — the replacement for the GPU operator chart in the
     `anyscale-on-azure` sibling.

Run it with `anyscale job submit -f job.yaml --wait`, or from a workspace
terminal with `python main.py`.
"""

import os
import platform
import socket
import sys
import time

import ray


# How long each task holds its CPU slot. This is the whole trick: the head pod
# has only a couple of CPUs, so a queue of slot-holding tasks cannot drain on
# the head alone, and Ray's autoscaler asks Karpenter for a node. A real deploy
# went Nominated -> NodeReady in 46s, and the fan-out below keeps the head busy
# for several times that.
TASK_HOLD_SECONDS = 25

# Tasks submitted per CPU the head reports. Sized so the head must work through
# several serial waves while Karpenter provisions in parallel.
TASKS_PER_HEAD_CPU = 6


@ray.remote
def whoami() -> dict:
    """Holds one CPU slot for TASK_HOLD_SECONDS, then reports where it ran.

    The sleep is load-bearing, not padding. Without it the head chews through
    the whole queue before a worker node finishes joining, and every result
    comes back with the head's own hostname — which looks like the fan-out
    worked while proving nothing about scale-out.
    """
    time.sleep(TASK_HOLD_SECONDS)
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

    head_hostname = socket.gethostname()
    head_cpus = int(ray.cluster_resources().get("CPU", 1) or 1)

    print("=== cluster ===")
    print(f"ray version:  {ray.__version__}")
    print(f"head pod:     {head_hostname}")
    print(f"cluster CPUs: {ray.cluster_resources().get('CPU')}")
    print(f"cluster GPUs: {ray.cluster_resources().get('GPU', 0)}")

    # More slot-holding tasks than the head can retire in the time Karpenter
    # needs to bring a node up. The queue is what triggers the scale-out; the
    # hostname check below is what proves it happened.
    task_count = head_cpus * TASKS_PER_HEAD_CPU
    print(f"\n=== workers ({task_count} tasks x {TASK_HOLD_SECONDS}s, forces Karpenter to provision) ===")
    results = ray.get([whoami.remote() for _ in range(task_count)])
    for result in results:
        print(result)

    hostnames = {r["hostname"] for r in results}
    worker_hostnames = hostnames - {head_hostname}
    print(f"\ndistinct hosts that ran tasks: {len(hostnames)}")
    if worker_hostnames:
        print(f"scale-out CONFIRMED — ran on {len(worker_hostnames)} node(s) beyond the head:")
        for name in sorted(worker_hostnames):
            print(f"  {name}")
    else:
        print(
            "scale-out NOT observed — every task ran on the head pod.\n"
            "  Karpenter may still have provisioned a node too late to take work.\n"
            "  Check: kubectl get nodes -w  /  kubectl get events -A | grep -i nodeclaim",
            file=sys.stderr,
        )

    # Opt in with RUN_GPU_CHECK=1 once a gpu_nodepool_configs entry exists.
    # Without one this task would stay Pending forever, so it is not the
    # default.
    if os.environ.get("RUN_GPU_CHECK") == "1":
        print("\n=== gpu ===")
        print(ray.get(gpu_check.remote()))
    else:
        print("\n=== gpu ===")
        print("skipped — set RUN_GPU_CHECK=1 and configure gpu_nodepool_configs to test GPUs")

    if not worker_hostnames:
        print("\nFAILED: no worker node ran any task", file=sys.stderr)
        raise SystemExit(1)

    print("\nOK")


if __name__ == "__main__":
    main()
