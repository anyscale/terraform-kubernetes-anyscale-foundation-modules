#!/usr/bin/env python3
import json

import ray

ROW_COUNT = 16
EXPECTED_SQUARE_SUM = 1240
SUCCESS_MARKER = "CPU_RAY_PROOF_OK"


@ray.remote(num_cpus=1)
def square_record(item: int) -> dict[str, int]:
    return {"item": item, "square": item * item}


def main() -> None:
    ray.init(address="auto", ignore_reinit_error=True)
    rows = list(range(ROW_COUNT))
    records = ray.get([square_record.remote(item) for item in rows])
    square_sum = sum(record["square"] for record in records)

    if len(records) != ROW_COUNT:
        raise SystemExit(f"expected {ROW_COUNT} records, got {len(records)}")
    if square_sum != EXPECTED_SQUARE_SUM:
        raise SystemExit(f"expected square sum {EXPECTED_SQUARE_SUM}, got {square_sum}")

    print(json.dumps({
        "marker": SUCCESS_MARKER,
        "row_count": len(records),
        "square_sum": square_sum,
    }, sort_keys=True))
    print(SUCCESS_MARKER)
    ray.shutdown()


if __name__ == "__main__":
    main()
