#!/usr/bin/env python3
"""Collect workspace artifact and storage-log diagnostics for support review.

Run through ``./scripts/anyscale-aks.sh diagnose workspace-artifacts`` so the
repo virtualenv is used when available.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


ROOT_DIR = Path(__file__).resolve().parents[2]
TERRAFORM_DIR = ROOT_DIR / "infra" / "terraform"
DEFAULT_ANYSCALE_HOST = "https://console.azure.anyscale.com"


def run_command(command: List[str], *, cwd: Optional[Path] = None) -> str:
    completed = subprocess.run(
        command,
        cwd=str(cwd) if cwd else None,
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def terraform_output(name: str) -> str:
    return run_command(["terraform", "output", "-raw", name], cwd=TERRAFORM_DIR)


def ensure_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(
            f"Missing required environment variable {name}. Load .env first, for example: set -a && source .env && set +a"
        )
    return value


def load_anyscale_client():
    try:
        from anyscale._private.anyscale_client.anyscale_client import AnyscaleClient
    except ImportError as exc:
        raise SystemExit(
            "Failed to import the Anyscale SDK. Run this script with the repo virtualenv, for example: .venv/bin/python scripts/utility/diagnose-workspace-artifacts.py ..."
        ) from exc

    return AnyscaleClient


def resolve_workspace(client: Any, workspace_id: Optional[str], workspace_name: Optional[str], cloud_name: Optional[str]) -> Any:
    workspace = client.get_workspace(id=workspace_id, name=workspace_name, cloud=cloud_name)
    if workspace is None:
        target = workspace_id or workspace_name or "<unknown>"
        raise SystemExit(f"Workspace '{target}' was not found.")
    return workspace


def unwrap_proxied_artifacts_response(response_tuple: Tuple[Any, int, Any]) -> Tuple[Dict[str, Any], int, Dict[str, str]]:
    payload, status_code, headers = response_tuple
    artifact_payload = getattr(payload, "result", payload)
    if hasattr(artifact_payload, "to_dict"):
        artifact_dict = artifact_payload.to_dict()
    elif isinstance(artifact_payload, dict):
        artifact_dict = artifact_payload
    else:
        artifact_dict = {"value": str(artifact_payload)}

    normalized_headers = {str(key): str(value) for key, value in dict(headers).items()}
    return artifact_dict, status_code, normalized_headers


def capture_api_exception(exc: Exception) -> Dict[str, Any]:
    return {
        "type": exc.__class__.__name__,
        "status_code": getattr(exc, "status", None),
        "reason": getattr(exc, "reason", None),
        "headers": {
            str(key): str(value)
            for key, value in dict(getattr(exc, "headers", {}) or {}).items()
        },
        "body": getattr(exc, "body", None),
        "message": str(exc),
    }


def fetch_proxied_artifacts(client: Any, workspace_id: str) -> Dict[str, Any]:
    try:
        raw_artifacts = client._internal_api_client.get_workspace_proxied_dataplane_artifacts_api_v2_experimental_workspaces_workspace_id_proxied_dataplane_artifacts_get_with_http_info(  # noqa: SLF001
            workspace_id
        )
        artifact_dict, artifact_status_code, artifact_headers = unwrap_proxied_artifacts_response(
            raw_artifacts
        )
        return {
            "status_code": artifact_status_code,
            "headers": artifact_headers,
            "payload": artifact_dict,
            "summary": summarize_artifacts(artifact_dict),
            "error": None,
        }
    except Exception as exc:
        return {
            "status_code": getattr(exc, "status", None),
            "headers": {
                str(key): str(value)
                for key, value in dict(getattr(exc, "headers", {}) or {}).items()
            },
            "payload": None,
            "summary": summarize_artifacts({}),
            "error": capture_api_exception(exc),
        }


def az_log_analytics_query(workspace_customer_id: str, query: str) -> Dict[str, Any]:
    command = [
        "az",
        "monitor",
        "log-analytics",
        "query",
        "--workspace",
        workspace_customer_id,
        "--analytics-query",
        query,
        "--output",
        "json",
        "--only-show-errors",
    ]
    attempts: List[Dict[str, Any]] = []

    for attempt in range(1, 4):
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
        )
        attempts.append(
            {
                "attempt": attempt,
                "returncode": completed.returncode,
                "stdout": completed.stdout.strip(),
                "stderr": completed.stderr.strip(),
            }
        )
        if completed.returncode == 0:
            payload_text = completed.stdout.strip()
            payload = json.loads(payload_text) if payload_text else []
            return {
                "payload": payload,
                "error": None,
                "attempts": attempts,
            }

    return {
        "payload": None,
        "error": {
            "message": "Azure Log Analytics query failed after retries.",
            "attempts": attempts,
        },
        "attempts": attempts,
    }


def tables_to_rows(payload: Any) -> List[Dict[str, Any]]:
    if isinstance(payload, list):
        return [row for row in payload if isinstance(row, dict)]

    if not isinstance(payload, dict):
        return []

    tables = payload.get("tables") or []
    rows: List[Dict[str, Any]] = []
    for table in tables:
        columns = [column["name"] for column in table.get("columns", [])]
        for row in table.get("rows", []):
            rows.append({column: row[index] for index, column in enumerate(columns)})
    return rows


def quote_kql(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "\\'")


def build_summary_query(storage_account_name: str, workspace_id: str, lookback: str) -> str:
    workspace_segment = f"/workspace_tracking_dependencies/{workspace_id}/"
    return (
        "StorageBlobLogs "
        f"| where TimeGenerated > ago({lookback}) "
        f"| where AccountName == '{quote_kql(storage_account_name)}' "
        f"| where Uri contains '{quote_kql(workspace_segment)}' "
        "| summarize Count=count(), Latest=max(TimeGenerated), StatusCodes=make_set(StatusCode), CallerIps=make_set(CallerIpAddress, 20) by AuthenticationType, OperationName "
        "| order by Count desc, AuthenticationType asc"
    )


def build_detail_query(storage_account_name: str, workspace_id: str, lookback: str) -> str:
    workspace_segment = f"/workspace_tracking_dependencies/{workspace_id}/"
    return (
        "StorageBlobLogs "
        f"| where TimeGenerated > ago({lookback}) "
        f"| where AccountName == '{quote_kql(storage_account_name)}' "
        f"| where Uri contains '{quote_kql(workspace_segment)}' "
        "| project TimeGenerated, AuthenticationType, StatusCode, StatusText, OperationName, Uri, CallerIpAddress, UserAgentHeader, ClientRequestId, ServerLatencyMs, DurationMs "
        "| order by TimeGenerated desc"
    )


def lines_from_text(value: Optional[str]) -> List[str]:
    if not value:
        return []
    return [line for line in value.splitlines() if line.strip()]


def summarize_artifacts(artifact_dict: Dict[str, Any]) -> Dict[str, Any]:
    requirements_lines = lines_from_text(artifact_dict.get("requirements"))
    env_vars = artifact_dict.get("environment_variables") or []
    return {
        "requirements_line_count": len(requirements_lines),
        "requirements_preview": requirements_lines[:20],
        "environment_variable_count": len(env_vars),
        "environment_variables_preview": env_vars[:20],
        "skip_packages_tracking": artifact_dict.get("skip_packages_tracking"),
        "latest_snapshot_uri": artifact_dict.get("latest_snapshot_uri"),
        "dockerfile_present": bool(artifact_dict.get("dockerfile")),
        "dockerfile_draft_present": bool(artifact_dict.get("dockerfile_draft")),
    }


def correlation_summary(detail_rows: Iterable[Dict[str, Any]]) -> Dict[str, Any]:
    total_rows = 0
    auth_type_counts: Dict[str, int] = {}
    status_counts: Dict[str, int] = {}
    unique_uris = set()
    unique_ips = set()

    for row in detail_rows:
        total_rows += 1
        auth_type = str(row.get("AuthenticationType") or "")
        status_code = str(row.get("StatusCode") or "")
        uri = str(row.get("Uri") or "")
        caller_ip = str(row.get("CallerIpAddress") or "")
        auth_type_counts[auth_type] = auth_type_counts.get(auth_type, 0) + 1
        status_counts[status_code] = status_counts.get(status_code, 0) + 1
        if uri:
            unique_uris.add(uri)
        if caller_ip:
            unique_ips.add(caller_ip)

    return {
        "row_count": total_rows,
        "authentication_type_counts": auth_type_counts,
        "status_code_counts": status_counts,
        "unique_uri_count": len(unique_uris),
        "unique_uris_preview": sorted(unique_uris)[:10],
        "caller_ip_count": len(unique_ips),
        "caller_ips": sorted(unique_ips)[:20],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fetch AnyScale proxied workspace artifacts and correlate them with recent StorageBlobLogs rows."
    )
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--workspace-id", help="Experimental workspace ID, for example expwrk_...")
    target.add_argument("--workspace-name", help="Experimental workspace name")
    parser.add_argument(
        "--cloud-name",
        default=os.environ.get("ANYSCALE_CLOUD_NAME"),
        help="Anyscale cloud name. Defaults to ANYSCALE_CLOUD_NAME from the environment.",
    )
    parser.add_argument(
        "--lookback",
        default="2h",
        help="KQL lookback window used with ago(...), for example 30m or 2h.",
    )
    parser.add_argument(
        "--storage-account-name",
        default=None,
        help="Override the Terraform-derived storage account name.",
    )
    parser.add_argument(
        "--log-analytics-workspace-customer-id",
        default=None,
        help="Override the Terraform-derived Log Analytics workspace customer ID.",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Optional path to write the JSON report to.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    anyscale_host = os.environ.get("ANYSCALE_HOST", "").strip()
    if not anyscale_host or anyscale_host == "https://console.anyscale.com":
        os.environ["ANYSCALE_HOST"] = DEFAULT_ANYSCALE_HOST
    ensure_env("ANYSCALE_HOST")

    storage_account_name = args.storage_account_name or terraform_output("storage_account_name")
    workspace_customer_id = (
        args.log_analytics_workspace_customer_id
        or terraform_output("log_analytics_workspace_customer_id")
    )

    AnyscaleClient = load_anyscale_client()
    client = AnyscaleClient()
    workspace = resolve_workspace(
        client,
        workspace_id=args.workspace_id,
        workspace_name=args.workspace_name,
        cloud_name=args.cloud_name,
    )

    proxied_artifacts = fetch_proxied_artifacts(client, getattr(workspace, "id"))

    summary_query = build_summary_query(storage_account_name, getattr(workspace, "id"), args.lookback)
    detail_query = build_detail_query(storage_account_name, getattr(workspace, "id"), args.lookback)
    summary_result = az_log_analytics_query(workspace_customer_id, summary_query)
    detail_result = az_log_analytics_query(workspace_customer_id, detail_query)
    summary_rows = tables_to_rows(summary_result.get("payload"))
    detail_rows = tables_to_rows(detail_result.get("payload"))

    report = {
        "inputs": {
            "workspace_id": getattr(workspace, "id", None),
            "workspace_name": getattr(workspace, "name", None),
            "lookback": args.lookback,
            "cloud_name": args.cloud_name,
            "anyscale_host": os.environ.get("ANYSCALE_HOST"),
            "storage_account_name": storage_account_name,
            "log_analytics_workspace_customer_id": workspace_customer_id,
        },
        "workspace": {
            "id": getattr(workspace, "id", None),
            "name": getattr(workspace, "name", None),
            "cluster_id": getattr(workspace, "cluster_id", None),
            "project_id": getattr(workspace, "project_id", None),
            "state": getattr(workspace, "state", None),
        },
        "proxied_dataplane_artifacts": {
            **proxied_artifacts,
        },
        "storage_blob_logs": {
            "summary_query": summary_query,
            "detail_query": detail_query,
            "summary_error": summary_result.get("error"),
            "detail_error": detail_result.get("error"),
            "summary_attempts": summary_result.get("attempts"),
            "detail_attempts": detail_result.get("attempts"),
            "summary_rows": summary_rows,
            "detail_rows": detail_rows,
            "correlation": correlation_summary(detail_rows),
        },
    }

    output = json.dumps(report, indent=2, sort_keys=True)
    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(output + "\n", encoding="utf-8")

    print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())