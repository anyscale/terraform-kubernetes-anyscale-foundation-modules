#!/usr/bin/env python3
import json
import os
from typing import Any

import ray

ROW_COUNT = 8
EXPECTED_CUBE_SUM = 784
SUCCESS_MARKER = "GPU_RAY_PROOF_OK"


@ray.remote(num_gpus=1)
def cube_record(item: int) -> dict[str, Any]:
    cuda_visible_devices = os.environ.get("CUDA_VISIBLE_DEVICES", "")
    if cuda_visible_devices in ("", "none"):
        raise RuntimeError("CUDA_VISIBLE_DEVICES was not assigned to the GPU Ray task")
    return {
        "item": item,
        "cube": item * item * item,
        "cuda_visible_devices_present": True,
    }


def main() -> None:
    ray.init(address="auto", ignore_reinit_error=True)
    gpu_capacity = ray.cluster_resources().get("GPU", 0)
    if gpu_capacity < 1:
        raise SystemExit(f"expected at least one Ray GPU resource, got {gpu_capacity}")

    rows = list(range(ROW_COUNT))
    records = ray.get([cube_record.remote(item) for item in rows])
    cube_sum = sum(record["cube"] for record in records)

    if len(records) != ROW_COUNT:
        raise SystemExit(f"expected {ROW_COUNT} records, got {len(records)}")
    if cube_sum != EXPECTED_CUBE_SUM:
        raise SystemExit(f"expected cube sum {EXPECTED_CUBE_SUM}, got {cube_sum}")
    if not all(record["cuda_visible_devices_present"] for record in records):
        raise SystemExit("not every GPU task observed CUDA_VISIBLE_DEVICES")

    print(json.dumps({
        "marker": SUCCESS_MARKER,
        "gpu_capacity": gpu_capacity,
        "row_count": len(records),
        "cube_sum": cube_sum,
    }, sort_keys=True))
    print(SUCCESS_MARKER)
    ray.shutdown()


if __name__ == "__main__":
    main()
