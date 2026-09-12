"""Smoke-test workload for an Anyscale-on-AKS-Automatic cloud.

Proves three things end to end, in order of how likely they are to be the
thing that is broken:

  1. The Anyscale operator scheduled a Ray head pod at all. On AKS Automatic
     that means deployment safeguards did NOT reject it — the single most
     common first-deploy failure (see the exclusion patch in aks.tf).
  2. Karpenter provisioned worker capacity on demand, a Ray worker joined the
     cluster on it, AND a task actually ran there. There are no
     pre-provisioned node pools in this stack; every worker node is created in
     response to pending Ray work. The script exits non-zero if no worker
     joins within WORKER_WAIT_SECONDS.
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


# Upper bound on how long to wait for a Ray worker to JOIN, not for a node to
# become Ready. Those are very different numbers, and conflating them is what
# broke the previous version of this script. On a real deploy:
#
#   Karpenter node Nominated -> NodeReady ................ ~46s
#   + anyscaled image pull (406 MB) ...................... ~35s
#   + workload-identity init containers .................. seconds
#   + Ray runtime image pull (anyscale/ray, multi-GB) .... minutes
#
# The previous version held CPU slots for a fixed 25s per task, sized against
# the 46s node number. All twelve tasks drained on the 2-CPU head in 150s while
# the first worker was still pulling images, so every task reported the head's
# hostname. No fixed sleep can be sized correctly across regions, image caches
# and node SKUs, so this version keeps demand up and WAITS for the worker.
WORKER_WAIT_SECONDS = 15 * 60
POLL_SECONDS = 15


@ray.remote(num_cpus=1)
def hold_slot(seconds: float) -> None:
    """Occupies one CPU so the autoscaler sees unmet demand and scales out."""
    time.sleep(seconds)


@ray.remote(num_cpus=0)
def whoami() -> dict:
    """Reports where it ran. Pinned to a specific node by the caller."""
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


def alive_worker_nodes(head_ip: str) -> list:
    return [n for n in ray.nodes() if n.get("Alive") and n.get("NodeManagerAddress") != head_ip]


def main() -> None:
    ray.init()

    # The driver runs on the head, so this is the head's address.
    head_ip = ray.util.get_node_ip_address()
    head_hostname = socket.gethostname()
    head_cpus = int(ray.cluster_resources().get("CPU", 1) or 1)

    print("=== cluster ===", flush=True)
    print(f"ray version:  {ray.__version__}", flush=True)
    print(f"head pod:     {head_hostname} ({head_ip})", flush=True)
    print(f"cluster CPUs: {ray.cluster_resources().get('CPU')}", flush=True)
    print(f"cluster GPUs: {ray.cluster_resources().get('GPU', 0)}", flush=True)

    print("\n=== workers (forces Karpenter to provision) ===", flush=True)
    worker = None
    existing = alive_worker_nodes(head_ip)
    if existing:
        # A warm cluster proves less, so say so rather than passing quietly.
        print(f"NOTE: {len(existing)} worker node(s) already alive — this run does not "
              "prove on-demand provisioning, only that work lands on a worker.", flush=True)
        worker = existing[0]
    else:
        # Demand that outlives any plausible worker boot. These tasks are
        # cancelled as soon as a worker joins; the long hold only matters if
        # it never does.
        pressure = [hold_slot.remote(WORKER_WAIT_SECONDS) for _ in range(head_cpus * 4)]
        print(f"queued {len(pressure)} slot-holding tasks against {head_cpus} head CPU(s); "
              f"waiting up to {WORKER_WAIT_SECONDS // 60} min for a worker to join", flush=True)

        t0 = time.time()
        while time.time() - t0 < WORKER_WAIT_SECONDS:
            joined = alive_worker_nodes(head_ip)
            if joined:
                worker = joined[0]
                print(f"worker joined after {time.time() - t0:.0f}s: "
                      f"{worker['NodeManagerAddress']}", flush=True)
                break
            print(f"  [{time.time() - t0:4.0f}s] no worker yet "
                  f"(nodes alive: {sum(1 for n in ray.nodes() if n.get('Alive'))})", flush=True)
            time.sleep(POLL_SECONDS)

        for ref in pressure:
            ray.cancel(ref, force=True)

    if worker is None:
        print(f"\nFAILED: no Ray worker joined within {WORKER_WAIT_SECONDS // 60} min.\n"
              "  Check: kubectl get nodes -w\n"
              "         kubectl get events -A | grep -iE 'nodeclaim|FailedScheduling'\n"
              "         kubectl get po -n anyscale-operator   # workers stuck in Init?",
              file=sys.stderr, flush=True)
        raise SystemExit(1)

    # Pin a task to that exact node via Ray's built-in per-node resource. This
    # is the difference between "a node exists" and "work runs on it".
    worker_ip = worker["NodeManagerAddress"]
    result = ray.get(whoami.options(resources={f"node:{worker_ip}": 0.001}).remote())
    print(f"task on worker: {result}", flush=True)

    if result["node_ip"] != worker_ip or result["hostname"] == head_hostname:
        print(f"\nFAILED: pinned task reported {result}, expected node {worker_ip}",
              file=sys.stderr, flush=True)
        raise SystemExit(1)
    print(f"scale-out CONFIRMED — task ran on worker {result['hostname']} "
          f"({worker_ip}), not the head", flush=True)

    # Opt in with RUN_GPU_CHECK=1 once a gpu_nodepool_configs entry exists.
    # Without one this task would stay Pending forever, so it is not the
    # default.
    print("\n=== gpu ===", flush=True)
    if os.environ.get("RUN_GPU_CHECK") == "1":
        print(ray.get(gpu_check.remote()), flush=True)
    else:
        print("skipped — set RUN_GPU_CHECK=1 and configure gpu_nodepool_configs to test GPUs", flush=True)

    print("\nOK", flush=True)


if __name__ == "__main__":
    main()
