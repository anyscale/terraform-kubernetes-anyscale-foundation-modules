#!/usr/bin/env bash

workspace_anyscale_cli_upgrade_script() {
  printf '%s
' "python -m pip install --no-cache-dir -U 'anyscale>=0.26.103' && anyscale version"
}

should_retry_anyscale_job_submission() {
  local log_file="$1"
  local attempt="$2"
  local log_text

  [[ -f "${log_file}" ]] || return 1
  log_text="$(<"${log_file}")"

  if [[ "${attempt}" -gt 1 ]]; then
    return 1
  fi

  if grep -Eiq 'builds/get_or_create_build_from_image_uri|Internal Server Error|HTTP 500|API Exception \(500\)' <<<"${log_text}"; then
    return 0
  fi

  return 1
}
