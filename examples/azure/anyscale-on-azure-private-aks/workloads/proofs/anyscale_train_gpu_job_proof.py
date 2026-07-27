#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path

os.environ.setdefault("RAY_TRAIN_V2_ENABLED", "0")
os.environ.setdefault("RAY_OVERRIDE_JOB_RUNTIME_ENV", "1")

import ray
from ray import train
from ray.train import ScalingConfig
from ray.train.data_parallel_trainer import DataParallelTrainer

from build_train_serve_common import (
    DEFAULT_LEARNING_RATE,
    DEFAULT_TRAIN_EPOCHS,
    GPU_TRAIN_JOB_SUCCESS_MARKER,
    GPU_TRAIN_MODEL_PREFIX,
    compact_json,
    cuda_visible_devices,
    dataset_manifest,
    load_json_env,
    model_metrics,
    model_payload,
    require_gpu_assignment,
    synthetic_rows,
    train_perceptron,
    use_gpu_requested,
)


def init_ray() -> None:
    runtime_env = {"working_dir": str(Path(__file__).resolve().parent)}
    try:
        ray.init(address="auto", ignore_reinit_error=True, log_to_driver=True, runtime_env=runtime_env)
    except Exception:
        ray.init(ignore_reinit_error=True, log_to_driver=True, runtime_env=runtime_env)


def train_loop_per_worker(config: dict[str, str | int | float | bool]) -> None:
    rows = list(train.get_dataset_shard("train").iter_rows())
    manifest = dataset_manifest(rows)
    expected_manifest = json.loads(str(config["manifest_json"]))

    if manifest != expected_manifest:
        raise RuntimeError(f"expected manifest {expected_manifest}, got {manifest}")

    require_gpu_assignment(bool(config["use_gpu"]))

    weights = train_perceptron(
        rows,
        epochs=int(config["epochs"]),
        learning_rate=float(config["learning_rate"]),
    )
    metrics = model_metrics(weights, rows)
    train.report({
        "accuracy": metrics["accuracy"],
        "cuda_visible_devices": cuda_visible_devices(),
        "model_json": compact_json(weights),
    })


def main() -> None:
    init_ray()

    expected_manifest = load_json_env("CPU_BUILD_MANIFEST_JSON")
    expected_manifest_json = compact_json(expected_manifest)
    rows = synthetic_rows()
    if dataset_manifest(rows) != expected_manifest:
        raise SystemExit("local synthetic dataset does not match the build-manifest payload")

    use_gpu = use_gpu_requested()
    cluster_resources = ray.cluster_resources()
    gpu_capacity = float(cluster_resources.get("GPU", 0))
    if use_gpu and gpu_capacity < 1:
        raise SystemExit(f"expected at least one Ray GPU resource, got {gpu_capacity}")

    trainer = DataParallelTrainer(
        train_loop_per_worker=train_loop_per_worker,
        train_loop_config={
            "epochs": DEFAULT_TRAIN_EPOCHS,
            "learning_rate": DEFAULT_LEARNING_RATE,
            "manifest_json": expected_manifest_json,
            "use_gpu": use_gpu,
        },
        scaling_config=ScalingConfig(num_workers=1, use_gpu=use_gpu),
        datasets={"train": ray.data.from_items(rows)},
    )
    result = trainer.fit()

    weights = json.loads(str(result.metrics["model_json"]))
    metrics = model_metrics(weights, rows)
    if float(metrics["accuracy"]) < 0.99:
        raise SystemExit(f"expected training accuracy >= 0.99, got {metrics['accuracy']}")

    payload = model_payload(weights, expected_manifest, metrics)
    report = {
        "cuda_visible_devices": result.metrics.get("cuda_visible_devices", ""),
        "gpu_capacity": gpu_capacity,
        "marker": GPU_TRAIN_JOB_SUCCESS_MARKER,
        "metrics": metrics,
    }

    print(json.dumps(report, sort_keys=True))
    print(f"{GPU_TRAIN_MODEL_PREFIX}{compact_json(payload)}")
    print(GPU_TRAIN_JOB_SUCCESS_MARKER)
    ray.shutdown()


if __name__ == "__main__":
    main()