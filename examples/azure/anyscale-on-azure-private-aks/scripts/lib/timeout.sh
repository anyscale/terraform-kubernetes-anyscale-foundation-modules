#!/usr/bin/env bash
# Shared timeout wrapper for long-running local commands.
# Prefer run_with_timeout instead of hand-written wait loops in callers.
# This file is pure Bash so it works without Perl, GNU timeout, or gtimeout.

format_timeout_command_display() {
  local result_var="$1"
  shift

  local display=""
  printf -v display '%q ' "$@"
  printf -v "${result_var}" '%s' "${display% }"
}

run_with_timeout_bash_watchdog() {
  local timeout_seconds="$1"
  shift

  local grace_seconds="${RUN_WITH_TIMEOUT_KILL_AFTER_SECONDS:-5}"
  local -a command=("$@")
  local command_pid watchdog_pid exit_code

  "${command[@]}" &
  command_pid=$!

  (
    sleep "${timeout_seconds}" &
    sleep_pid="$!"
    trap 'kill "${sleep_pid}" 2>/dev/null || true; exit 0' TERM INT
    wait "${sleep_pid}" 2>/dev/null || exit 0
    if kill -0 "${command_pid}" 2>/dev/null; then
      kill -TERM "${command_pid}" 2>/dev/null || true
      sleep "${grace_seconds}"
      kill -KILL "${command_pid}" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!

  set +e
  wait "${command_pid}" 2>/dev/null
  exit_code=$?
  set -e
  kill "${watchdog_pid}" 2>/dev/null || true
  wait "${watchdog_pid}" 2>/dev/null || true

  # Normalize SIGTERM/SIGKILL exits from the watchdog path to the conventional
  # timeout exit code so callers can treat every timeout implementation the same.
  if [[ "${exit_code}" -eq 143 || "${exit_code}" -eq 137 ]]; then
    return 124
  fi

  return "${exit_code}"
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  local exit_code=0 command_display

  if [[ "$#" -eq 0 ]]; then
    printf '[error] run_with_timeout requires a command\n' >&2
    return 2
  fi

  if [[ -z "${timeout_seconds}" || "${timeout_seconds}" == "0" ]]; then
    "$@"
    return $?
  fi

  run_with_timeout_bash_watchdog "${timeout_seconds}" "$@"
  exit_code=$?

  if [[ "${exit_code}" -eq 124 ]]; then
    format_timeout_command_display command_display "$@"
    printf '[error] Timed out after %ss: %s\n' "${timeout_seconds}" "${command_display}" >&2
  fi

  return "${exit_code}"
}
