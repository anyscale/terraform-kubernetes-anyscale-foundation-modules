#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

SUCCESS_MARKER = "CUSTOM_IMAGE_SBOM_PROOF_OK"
DEFAULT_REQUIREMENT = "onnxruntime==1.22.0"


def find_sbom(path: Path) -> Path:
    if path.is_file():
        return path
    candidates = sorted(path.rglob("*.json"))
    if not candidates:
        raise SystemExit(f"No SBOM JSON found under {path}.")
    return candidates[0]


def parse_requirement(requirement: str) -> tuple[str, str]:
    if "==" in requirement:
        name, version = requirement.split("==", 1)
    else:
        name, version = requirement, ""
    return name.strip().lower(), version.strip()


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: custom_image_sbom_proof.py <sbom-path>")

    sbom_path = find_sbom(Path(sys.argv[1]))
    requirement = os.environ.get(
        "ANYSCALE_CUSTOM_IMAGE_REQUIREMENT", DEFAULT_REQUIREMENT
    )
    want_name, want_version = parse_requirement(requirement)

    document = json.loads(sbom_path.read_text())
    packages = document.get("packages", [])
    matches = [
        package
        for package in packages
        if str(package.get("name", "")).strip().lower() == want_name
        and (
            not want_version
            or str(package.get("versionInfo", "")).strip() == want_version
        )
    ]
    if not matches:
        raise SystemExit(
            f"SBOM {sbom_path} does not contain {want_name}=={want_version}."
        )

    payload = {
        "marker": SUCCESS_MARKER,
        "requirement": requirement,
        "sbom_document": document.get("name", ""),
        "spdx_version": document.get("spdxVersion", ""),
    }
    print(json.dumps(payload, sort_keys=True))
    print(SUCCESS_MARKER)


if __name__ == "__main__":
    main()
