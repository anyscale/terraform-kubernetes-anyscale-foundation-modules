#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from typing import Any, Iterable

CPU_BUILD_JOB_SUCCESS_MARKER = "CPU_BUILD_JOB_PROOF_OK"
GPU_TRAIN_JOB_SUCCESS_MARKER = "GPU_TRAIN_JOB_PROOF_OK"
GPU_SERVE_SERVICE_SUCCESS_MARKER = "GPU_SERVE_SERVICE_PROOF_OK"

CPU_BUILD_MANIFEST_PREFIX = "CPU_BUILD_MANIFEST_JSON="
GPU_TRAIN_MODEL_PREFIX = "GPU_TRAIN_MODEL_JSON="

DEFAULT_ROW_COUNT = 96
DEFAULT_TRAIN_EPOCHS = 24
DEFAULT_LEARNING_RATE = 0.2


def compact_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def use_gpu_requested() -> bool:
    return os.environ.get("ANYSCALE_PROOF_USE_GPU", "1") != "0"


def cuda_visible_devices() -> str:
    return os.environ.get("CUDA_VISIBLE_DEVICES", "")


def gpu_assignment_present() -> bool:
    devices = cuda_visible_devices().strip().lower()
    return devices not in ("", "none")


def require_gpu_assignment(use_gpu: bool) -> None:
    if use_gpu and not gpu_assignment_present():
        raise SystemExit("expected CUDA_VISIBLE_DEVICES to be assigned for the GPU proof")


def synthetic_rows(row_count: int = DEFAULT_ROW_COUNT) -> list[dict[str, float | int]]:
    rows: list[dict[str, float | int]] = []
    for record_id in range(row_count):
        x1 = (((record_id * 7) % 19) - 9) / 3.0
        x2 = (((record_id * 5) % 17) - 8) / 2.5
        score = (1.75 * x1) - (0.65 * x2) + 0.3
        label = 1 if score >= 0 else 0
        rows.append({
            "record_id": record_id,
            "x1": round(x1, 6),
            "x2": round(x2, 6),
            "label": label,
        })
    return rows


def dataset_manifest(rows: Iterable[dict[str, float | int]]) -> dict[str, int]:
    row_count = 0
    label_sum = 0
    feature_checksum = 0
    for row in rows:
        row_count += 1
        label = int(row["label"])
        scaled_x1 = int(round(float(row["x1"]) * 1000))
        scaled_x2 = int(round(float(row["x2"]) * 1000))
        label_sum += label
        feature_checksum += (int(row["record_id"]) + 1) * (scaled_x1 + (3 * scaled_x2) + (17 * label))
    return {
        "feature_checksum": feature_checksum,
        "label_sum": label_sum,
        "row_count": row_count,
    }


def predict_score(weights: dict[str, float | int], x1: float, x2: float) -> float:
    return (
        (float(weights["weight_x1"]) * x1)
        + (float(weights["weight_x2"]) * x2)
        + float(weights["bias"])
    )


def predict_label(weights: dict[str, float | int], x1: float, x2: float) -> int:
    return 1 if predict_score(weights, x1, x2) >= 0 else 0


def train_perceptron(
    rows: list[dict[str, float | int]],
    epochs: int = DEFAULT_TRAIN_EPOCHS,
    learning_rate: float = DEFAULT_LEARNING_RATE,
) -> dict[str, float | int]:
    bias = 0.0
    weight_x1 = 0.0
    weight_x2 = 0.0
    epochs_completed = 0

    for epoch in range(epochs):
        epochs_completed = epoch + 1
        mistakes = 0
        for row in rows:
            x1 = float(row["x1"])
            x2 = float(row["x2"])
            label = int(row["label"])
            prediction = predict_label(
                {
                    "bias": bias,
                    "weight_x1": weight_x1,
                    "weight_x2": weight_x2,
                },
                x1,
                x2,
            )
            error = label - prediction
            if error != 0:
                mistakes += 1
                bias += learning_rate * error
                weight_x1 += learning_rate * error * x1
                weight_x2 += learning_rate * error * x2

        if mistakes == 0:
            break

    return {
        "bias": round(bias, 6),
        "epochs_completed": epochs_completed,
        "learning_rate": learning_rate,
        "weight_x1": round(weight_x1, 6),
        "weight_x2": round(weight_x2, 6),
    }


def model_metrics(weights: dict[str, float | int], rows: Iterable[dict[str, float | int]]) -> dict[str, float | int]:
    row_list = list(rows)
    correct = 0
    for row in row_list:
        prediction = predict_label(weights, float(row["x1"]), float(row["x2"]))
        if prediction == int(row["label"]):
            correct += 1

    accuracy = correct / len(row_list)
    return {
        "accuracy": round(accuracy, 6),
        "correct_predictions": correct,
        "row_count": len(row_list),
    }


def model_payload(
    weights: dict[str, float | int],
    manifest: dict[str, int],
    metrics: dict[str, float | int],
) -> dict[str, Any]:
    return {
        "dataset_manifest": manifest,
        "metrics": metrics,
        "probes": {
            "negative": {"expected_label": 0, "x1": -1.5, "x2": 0.25},
            "positive": {"expected_label": 1, "x1": 1.25, "x2": -0.25},
        },
        "weights": weights,
    }


def prediction_response(payload: dict[str, Any], x1: float, x2: float) -> dict[str, Any]:
    weights = payload["weights"]
    score = predict_score(weights, x1, x2)
    return {
        "label": predict_label(weights, x1, x2),
        "score": round(score, 6),
        "x1": x1,
        "x2": x2,
    }


def load_json_env(name: str) -> dict[str, Any]:
    raw_value = os.environ.get(name, "")
    if not raw_value:
        raise SystemExit(f"missing required environment variable {name}")
    return json.loads(raw_value)