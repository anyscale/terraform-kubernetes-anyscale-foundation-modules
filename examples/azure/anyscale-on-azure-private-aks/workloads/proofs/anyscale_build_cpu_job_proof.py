#!/usr/bin/env python3
from __future__ import annotations

import json

import ray

from build_train_serve_common import (
    CPU_BUILD_JOB_SUCCESS_MARKER,
    CPU_BUILD_MANIFEST_PREFIX,
    compact_json,
    dataset_manifest,
    synthetic_rows,
)


def init_ray() -> None:
    try:
        ray.init(address="auto", ignore_reinit_error=True, log_to_driver=True)
    except Exception:
        ray.init(ignore_reinit_error=True, log_to_driver=True)


@ray.remote(num_cpus=1)
def annotate_row(row: dict[str, float | int]) -> dict[str, float | int]:
    return {
        **row,
        "feature_bucket": int(round((float(row["x1"]) * 10) + (float(row["x2"]) * 10))),
    }


def main() -> None:
    init_ray()

    rows = synthetic_rows()
    cluster_resources = ray.cluster_resources()
    gpu_capacity = float(cluster_resources.get("GPU", 0))
    if gpu_capacity != 0:
        raise SystemExit(f"expected the CPU build proof to run without GPU capacity, got {gpu_capacity}")

    annotated_rows = ray.get([annotate_row.remote(row) for row in rows])
    dataset = ray.data.from_items(annotated_rows)
    materialized_rows = dataset.take_all()
    manifest = dataset_manifest(materialized_rows)

    if dataset.count() != len(rows):
        raise SystemExit("ray.data materialization changed the proof row count")

    result = {
        "cpu_capacity": cluster_resources.get("CPU", 0),
        "dataset_manifest": manifest,
        "marker": CPU_BUILD_JOB_SUCCESS_MARKER,
        "row_count": len(materialized_rows),
    }

    print(json.dumps(result, sort_keys=True))
    print(f"{CPU_BUILD_MANIFEST_PREFIX}{compact_json(manifest)}")
    print(CPU_BUILD_JOB_SUCCESS_MARKER)
    ray.shutdown()


if __name__ == "__main__":
    main()