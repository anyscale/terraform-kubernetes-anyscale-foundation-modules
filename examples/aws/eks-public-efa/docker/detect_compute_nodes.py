#!/usr/bin/env python3
"""Print IP addresses and hostnames for Ray compute nodes.

By default this excludes the Ray head node and reports only worker/compute
nodes. Use --include-head if you also want the head node in the output.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import socket
import sys
from typing import Any


# Some workspace environments install a runtime-env hook that packages workspace
# files for Ray jobs. This probe does not need those files, and disabling the
# hook avoids large uploads from large workspaces.
os.environ.pop("RAY_RUNTIME_ENV_HOOK", None)
os.environ.setdefault("RAY_ACCEL_ENV_VAR_OVERRIDE_ON_ZERO", "0")

import ray  # noqa: E402
from ray.util.scheduling_strategies import NodeAffinitySchedulingStrategy  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Detect IP addresses and hostnames for Ray compute nodes."
    )
    parser.add_argument(
        "--address",
        default="auto",
        help="Ray cluster address. Defaults to auto.",
    )
    parser.add_argument(
        "--include-head",
        action="store_true",
        help="Include the Ray head node in the output.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable JSON instead of a table.",
    )
    parser.add_argument(
        "--details",
        action="store_true",
        help="Include node group, instance type, and availability zone in table output.",
    )
    return parser.parse_args()


@ray.remote(num_cpus=0)
def probe_hostname() -> dict[str, Any]:
    hostname = socket.gethostname()
    env_keys = (
        "ANYSCALE_INSTANCE_ID",
        "ANYSCALE_NODE_IP",
        "ANYSCALE_NODE_GROUP_ID",
        "ANYSCALE_NODE_AZ",
        "RAY_CLOUD_INSTANCE_ID",
        "RAY_CLOUD_INSTANCE_TYPE_NAME",
        "RAY_NODE_TYPE_NAME",
    )

    host_ips: list[str] = []
    try:
        host_ips = socket.gethostbyname_ex(hostname)[2]
    except socket.gaierror:
        pass

    return {
        "hostname": hostname,
        "fqdn": socket.getfqdn(),
        "host_ips": host_ips,
        "env": {key: os.environ.get(key) for key in env_keys if os.environ.get(key)},
    }


def is_head_node(node: dict[str, Any]) -> bool:
    resources = node.get("Resources", {})
    labels = node.get("Labels", {})
    return bool(
        resources.get("node:__internal_head__")
        or labels.get("ray.io/node-group") == "head"
        or labels.get("ray.io/node-type") == "head"
    )


def node_ip(node: dict[str, Any]) -> str:
    return (
        node.get("NodeManagerAddress")
        or node.get("node_ip")
        or node.get("NodeManagerHostname")
        or ""
    )


def collect_nodes(include_head: bool) -> list[dict[str, Any]]:
    records = []
    for node in ray.nodes():
        if not node.get("Alive"):
            continue
        if not include_head and is_head_node(node):
            continue

        node_id = node["NodeID"]
        ray_ip = node_ip(node)
        labels = node.get("Labels", {})

        ref = probe_hostname.options(
            scheduling_strategy=NodeAffinitySchedulingStrategy(
                node_id=node_id,
                soft=False,
            )
        ).remote()
        probe = ray.get(ref)
        env = probe.get("env", {})

        records.append(
            {
                "hostname": probe.get("hostname") or env.get("ANYSCALE_INSTANCE_ID") or "",
                "ip": env.get("ANYSCALE_NODE_IP") or ray_ip,
                "ray_node_id": node_id,
                "node_group": labels.get("ray.io/node-group")
                or env.get("ANYSCALE_NODE_GROUP_ID")
                or "",
                "instance_type": labels.get("anyscale.com/instance-type")
                or env.get("RAY_CLOUD_INSTANCE_TYPE_NAME")
                or "",
                "availability_zone": labels.get("ray.io/availability-zone")
                or env.get("ANYSCALE_NODE_AZ")
                or "",
                "is_head": is_head_node(node),
            }
        )

    return sorted(records, key=lambda item: (item["is_head"], item["ip"], item["hostname"]))


def print_table(records: list[dict[str, Any]], details: bool) -> None:
    columns = [
        ("HOSTNAME", "hostname"),
        ("IP", "ip"),
    ]
    if details:
        columns.extend(
            [
                ("NODE_GROUP", "node_group"),
                ("INSTANCE_TYPE", "instance_type"),
                ("AZ", "availability_zone"),
            ]
        )
    widths = {
        header: max(len(header), *(len(str(record[key])) for record in records))
        for header, key in columns
    }

    print("  ".join(header.ljust(widths[header]) for header, _ in columns))
    for record in records:
        print(
            "  ".join(
                str(record[key]).ljust(widths[header]) for header, key in columns
            )
        )


def main() -> int:
    args = parse_args()

    ray.init(
        address=args.address,
        namespace="detect-compute-nodes",
        runtime_env={},
        logging_level=logging.ERROR,
        log_to_driver=False,
    )
    records = collect_nodes(include_head=args.include_head)

    if args.json:
        print(json.dumps(records, indent=2, sort_keys=True))
    elif records:
        print_table(records, details=args.details)
    else:
        print("No alive compute nodes found.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
