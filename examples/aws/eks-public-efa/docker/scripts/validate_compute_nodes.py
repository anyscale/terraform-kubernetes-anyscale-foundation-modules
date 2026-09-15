#!/usr/bin/env python3
"""Run EFA/UCCL validation on Ray compute nodes through SSH."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import selectors
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
DETECT_SCRIPT = SCRIPT_DIR / "detect_compute_nodes.py"
if not DETECT_SCRIPT.exists():
    DETECT_SCRIPT = SCRIPT_DIR.parent / "detect_compute_nodes.py"
DEFAULT_LOG_ROOT = Path("/home/ray/default/efa_validation_logs")
DEFAULT_ACTION_TIMEOUTS = {
    "devices": 180,
    "imports": 180,
    "local": 300,
    "all-reduce": 600,
    "nccl": 600,
    "uccl-ll": 900,
    "uccl-ht": 900,
}
LOCAL_ACTIONS = {"all-reduce", "nccl"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="SSH to Ray compute nodes and run EFA/UCCL validation."
    )
    parser.add_argument(
        "action",
        nargs="?",
        default="all",
        choices=(
            "all",
            "quick",
            "local",
            "devices",
            "imports",
            "all-reduce",
            "nccl",
            "uccl-ll",
            "uccl-ht",
        ),
        help=(
            "Validation to run. all runs EFA device detection, Ray all-reduce, "
            "and UCCL-EP LL/HT. quick runs only EFA device detection."
        ),
    )
    parser.add_argument(
        "--address",
        default="auto",
        help="Ray cluster address passed to detect_compute_nodes.py.",
    )
    parser.add_argument(
        "--include-head",
        action="store_true",
        help="Include the Ray head node. Usually leave this off.",
    )
    parser.add_argument(
        "--target",
        choices=("hostname", "ip"),
        default=os.environ.get("SSH_TARGET", "ip"),
        help="Use hostnames or IPs as SSH targets. Defaults to SSH_TARGET or ip.",
    )
    parser.add_argument(
        "--ssh-port",
        default=os.environ.get("SSH_PORT", "2222"),
        help="Optional SSH port. Defaults to SSH_PORT or 2222.",
    )
    parser.add_argument(
        "--connect-timeout",
        default=os.environ.get("SSH_CONNECT_TIMEOUT", "15"),
        help="SSH connection timeout in seconds.",
    )
    parser.add_argument(
        "--log-dir",
        default=os.environ.get("EFA_VALIDATION_LOG_DIR", ""),
        help="Directory on the head node for per-node logs.",
    )
    parser.add_argument(
        "--nnodes",
        type=int,
        default=int(os.environ.get("NNODES", "0")),
        help="Number of nodes for distributed checks. Defaults to all compute nodes.",
    )
    parser.add_argument(
        "--nproc-per-node",
        type=int,
        default=int(os.environ.get("NPROC_PER_NODE", "8")),
        help="Processes per node for distributed checks.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned SSH commands without running them.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=int(os.environ.get("EFA_VALIDATION_TIMEOUT", "-1")),
        help=(
            "Per-step timeout in seconds. Defaults are action-specific. "
            "Use 0 to disable timeouts."
        ),
    )
    return parser.parse_args()


def run(cmd: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)


def detect_nodes(address: str, include_head: bool) -> list[dict[str, Any]]:
    cmd = [sys.executable, str(DETECT_SCRIPT), "--address", address, "--json"]
    if include_head:
        cmd.append("--include-head")
    result = run(cmd)
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise SystemExit(result.returncode)
    return json.loads(result.stdout)


def ssh_base_args(args: argparse.Namespace) -> list[str]:
    ssh_args = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        f"ConnectTimeout={args.connect_timeout}",
    ]
    if args.ssh_port:
        ssh_args.extend(["-p", str(args.ssh_port)])
    if os.environ.get("SSH_OPTS"):
        ssh_args.extend(shlex.split(os.environ["SSH_OPTS"]))
    return ssh_args


def target_for(node: dict[str, Any], mode: str) -> str:
    value = node.get(mode) or node.get("hostname") or node.get("ip")
    if not value:
        raise ValueError(f"Node has no usable SSH target: {node}")
    return str(value)


def remote_env(extra: dict[str, str] | None = None) -> str:
    values: dict[str, str] = {}
    for key in ("EXPECTED_GPUS", "EXPECTED_EFA_DEVICES"):
        if key in os.environ:
            values[key] = os.environ[key]
    if extra:
        values.update(extra)
    passthrough = (
        "ALL_REDUCE_WARMUPS",
        "ALL_REDUCE_TRIALS",
        "ALL_REDUCE_LOWER_POWER",
        "ALL_REDUCE_UPPER_POWER",
        "ALL_REDUCE_PAYLOAD_SIZE_GIB",
        "ALL_REDUCE_PROFILE_STABILITY",
        "EFA_MIDDLE_PRELOAD_NCCL",
        "NCCL_DEBUG",
        "NCCL_DEBUG_SUBSYS",
        "NCCL_NET_PLUGIN",
        "NCCL_SOCKET_IFNAME",
        "NCCL_VALIDATION_DEBUG",
        "NCCL_VALIDATION_DEBUG_SUBSYS",
        "REQUIRE_NCCL_OFI",
        "RAY_ADDRESS",
        "WORLD_SIZE",
    )
    for key in passthrough:
        if key in os.environ:
            values[key] = os.environ[key]
    return " ".join(f"{key}={shlex.quote(value)}" for key, value in values.items())


def action_timeout(args: argparse.Namespace, action: str) -> int:
    if args.timeout >= 0:
        return args.timeout
    env_key = f"EFA_VALIDATION_{action.upper().replace('-', '_')}_TIMEOUT"
    if env_key in os.environ:
        return int(os.environ[env_key])
    return DEFAULT_ACTION_TIMEOUTS.get(action, 300)


def remote_command(action: str, extra_env: dict[str, str] | None = None) -> str:
    script_map = {
        "devices": "/opt/efa-middle/scripts/validate_efa_devices.sh",
        "imports": "/opt/efa-middle/scripts/validate_uccl_imports.sh",
        "local": "/opt/efa-middle/scripts/validate_middle_layer_local.sh",
        "all-reduce": "/opt/efa-middle/scripts/validate_nccl_all_reduce.sh",
        "nccl": "/opt/efa-middle/scripts/validate_nccl_all_reduce.sh",
        "uccl-ll": "/opt/efa-middle/scripts/validate_uccl_ep.sh ll",
        "uccl-ht": "/opt/efa-middle/scripts/validate_uccl_ep.sh ht",
    }
    script = script_map[action]
    check_path = script.split()[0]
    return (
        "set -euo pipefail; "
        "export PATH=/home/ray/anaconda3/bin:/opt/efa-middle/scripts:/opt/amazon/efa/bin:/usr/local/cuda/bin:$PATH; "
        f"if [ ! -x {shlex.quote(check_path)} ]; then "
        f"echo \"Missing {check_path}. Did this worker use the EFA/UCCL image?\" >&2; "
        "exit 127; "
        "fi; "
        f"{remote_env(extra_env)} {script}"
    )


def run_streaming(cmd: list[str], log_path: Path, timeout_seconds: int) -> int:
    deadline = time.monotonic() + timeout_seconds if timeout_seconds > 0 else None
    with log_path.open("w", buffering=1) as log:
        log.write("$ " + " ".join(shlex.quote(part) for part in cmd) + "\n\n")
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        if process.stdout is None:
            return process.wait()

        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        timed_out = False

        while True:
            if deadline is not None and time.monotonic() >= deadline:
                timed_out = True
                log.write(f"\nTimed out after {timeout_seconds}s. Terminating SSH command.\n")
                process.terminate()
                break

            wait_for = 1.0
            if deadline is not None:
                wait_for = max(0.0, min(wait_for, deadline - time.monotonic()))

            for key, _ in selector.select(wait_for):
                line = key.fileobj.readline()
                if line:
                    log.write(line)

            if process.poll() is not None:
                break

        for line in process.stdout:
            log.write(line)

        if timed_out:
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                log.write("SSH command did not exit after SIGTERM; killing it.\n")
                process.kill()
                process.wait()
            return 124

        return process.wait()


def run_ssh_action(
    args: argparse.Namespace,
    node: dict[str, Any],
    action: str,
    log_dir: Path,
    rank: int | None = None,
    nnodes: int | None = None,
    master_addr: str | None = None,
) -> dict[str, Any]:
    target = target_for(node, args.target)
    extra_env: dict[str, str] = {}
    if rank is not None and nnodes is not None and master_addr is not None:
        extra_env.update(
            {
                "NNODES": str(nnodes),
                "NODE_RANK": str(rank),
                "MASTER_ADDR": master_addr,
                "NPROC_PER_NODE": str(args.nproc_per_node),
            }
        )

    remote = remote_command(action, extra_env)
    timeout_seconds = action_timeout(args, action)
    remote_shell = f"bash -lc {shlex.quote(remote)}"
    if timeout_seconds > 0:
        remote_shell = f"timeout -s INT -k 30 {timeout_seconds}s {remote_shell}"
    cmd = ssh_base_args(args) + [target, remote_shell]
    safe_name = node.get("hostname") or node.get("ip") or target
    rank_label = rank if rank is not None else "node"
    log_path = log_dir / f"{action}_{rank_label}_{safe_name}.log"

    if args.dry_run:
        return {
            "node": node,
            "action": action,
            "target": target,
            "returncode": 0,
            "log_path": str(log_path),
            "dry_run": " ".join(shlex.quote(part) for part in cmd),
        }

    started = time.time()
    local_timeout = timeout_seconds + 60 if timeout_seconds > 0 else 0
    returncode = run_streaming(cmd, log_path, local_timeout)
    elapsed = time.time() - started
    return {
        "node": node,
        "action": action,
        "target": target,
        "returncode": returncode,
        "log_path": str(log_path),
        "elapsed": elapsed,
    }


def run_local_action(
    args: argparse.Namespace,
    nodes: list[dict[str, Any]],
    action: str,
    log_dir: Path,
) -> dict[str, Any]:
    nnodes = args.nnodes or len(nodes)
    if nnodes < 1:
        raise SystemExit("Ray all-reduce validation requires at least one node.")
    if nnodes > len(nodes):
        raise SystemExit(
            f"Requested {nnodes} nodes but only detected {len(nodes)}."
        )

    extra_env = {
        "NNODES": str(nnodes),
        "NPROC_PER_NODE": str(args.nproc_per_node),
        "WORLD_SIZE": str(nnodes * args.nproc_per_node),
    }
    remote = remote_command(action, extra_env)
    timeout_seconds = action_timeout(args, action)
    cmd = ["bash", "-lc", remote]
    if timeout_seconds > 0:
        cmd = ["timeout", "-s", "INT", "-k", "30", f"{timeout_seconds}s"] + cmd

    log_path = log_dir / f"{action}_ray_head.log"
    if args.dry_run:
        return {
            "node": {"hostname": "ray-head"},
            "action": action,
            "target": "ray-head",
            "returncode": 0,
            "log_path": str(log_path),
            "dry_run": " ".join(shlex.quote(part) for part in cmd),
        }

    started = time.time()
    local_timeout = timeout_seconds + 60 if timeout_seconds > 0 else 0
    returncode = run_streaming(cmd, log_path, local_timeout)
    elapsed = time.time() - started
    return {
        "node": {"hostname": "ray-head"},
        "action": action,
        "target": "ray-head",
        "returncode": returncode,
        "log_path": str(log_path),
        "elapsed": elapsed,
    }


def run_parallel(
    args: argparse.Namespace,
    nodes: list[dict[str, Any]],
    action: str,
    log_dir: Path,
    distributed: bool = False,
) -> list[dict[str, Any]]:
    if distributed:
        nnodes = args.nnodes or len(nodes)
        if nnodes < 1:
            raise SystemExit("Distributed validation requires at least one node.")
        if nnodes > len(nodes):
            raise SystemExit(
                f"Requested {nnodes} distributed nodes but only detected {len(nodes)}."
            )
        selected = nodes[:nnodes]
        master_addr = str(selected[0].get("ip") or selected[0].get("hostname"))
        jobs = [
            (node, rank, nnodes, master_addr)
            for rank, node in enumerate(selected)
        ]
    else:
        jobs = [(node, None, None, None) for node in nodes]

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(jobs))) as pool:
        futures = [
            pool.submit(run_ssh_action, args, node, action, log_dir, rank, nnodes, master_addr)
            for node, rank, nnodes, master_addr in jobs
        ]
        return [future.result() for future in concurrent.futures.as_completed(futures)]


def print_nodes(nodes: list[dict[str, Any]]) -> None:
    print("Compute nodes:")
    print("HOSTNAME                         IP              INSTANCE_TYPE              AZ")
    for node in nodes:
        hostname = str(node.get("hostname", ""))
        ip = str(node.get("ip", ""))
        instance_type = str(node.get("instance_type", ""))
        availability_zone = str(node.get("availability_zone", ""))
        print(
            f"{hostname[:32].ljust(32)} "
            f"{ip.ljust(15)} "
            f"{instance_type.ljust(26)} "
            f"{availability_zone}"
        )
    print()


def print_summary(results: list[dict[str, Any]]) -> int:
    print("Validation summary:")
    print("ACTION    STATUS  TARGET                          LOG")
    failures = 0
    for item in sorted(results, key=lambda value: (value["action"], value["target"])):
        action = item["action"]
        target = item["target"]
        log_path = item["log_path"]
        dry_run = item.get("dry_run")
        returncode = item["returncode"]
        status = "PASS" if returncode == 0 else f"FAIL({returncode})"
        if returncode != 0:
            failures += 1
        print(
            f"{action.ljust(9)} {status.ljust(7)} "
            f"{target[:31].ljust(31)} {log_path}"
        )
        if dry_run:
            print(f"  {dry_run}")
    print()
    if failures:
        print(f"{failures} validation step(s) failed.")
    else:
        print("All requested validation steps passed.")
    return 1 if failures else 0


def main() -> int:
    args = parse_args()
    nodes = detect_nodes(args.address, args.include_head)
    if not nodes:
        print("No alive compute nodes found.", file=sys.stderr)
        return 1

    log_dir = Path(args.log_dir) if args.log_dir else DEFAULT_LOG_ROOT / time.strftime("%Y%m%d-%H%M%S")
    log_dir.mkdir(parents=True, exist_ok=True)

    print_nodes(nodes)
    print(f"Writing per-node logs to: {log_dir}")
    print()

    if args.action == "all":
        actions = ["devices", "all-reduce", "uccl-ll", "uccl-ht"]
    elif args.action == "quick":
        actions = ["devices"]
    else:
        actions = [args.action]

    results: list[dict[str, Any]] = []
    for action in actions:
        if action in LOCAL_ACTIONS:
            print(f"Running {action} from the Ray head...")
            print(f"  Live logs: tail -f {log_dir}/{action}_ray_head.log", flush=True)
            results.append(run_local_action(args, nodes, action, log_dir))
            continue

        distributed = action in {"uccl-ll", "uccl-ht"}
        print(f"Running {action}...")
        print(f"  Live logs: tail -f {log_dir}/{action}_*.log", flush=True)
        results.extend(run_parallel(args, nodes, action, log_dir, distributed=distributed))

    return print_summary(results)


if __name__ == "__main__":
    raise SystemExit(main())
