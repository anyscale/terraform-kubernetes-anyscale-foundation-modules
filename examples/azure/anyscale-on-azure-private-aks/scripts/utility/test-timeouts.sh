#!/usr/bin/env bash
# Self-test the shared timeout wrapper without touching cloud resources.
# The public route is: ./scripts/anyscale-aks.sh self-test timeouts.
# A logged timeout error is expected during the positive timeout checks.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

LOG_INFO_PREFIX="timeout-test"
# shellcheck source=./lib/log.sh
source "${ROOT_DIR}/scripts/lib/log.sh"
# shellcheck source=./lib/timeout.sh
source "${ROOT_DIR}/scripts/lib/timeout.sh"

TIMEOUT_SELF_TEST_SECONDS="${TIMEOUT_SELF_TEST_SECONDS:-2}"
TIMEOUT_SELF_TEST_GRACE_SECONDS="${TIMEOUT_SELF_TEST_GRACE_SECONDS:-1}"
TIMEOUT_SELF_TEST_LONG_SLEEP_SECONDS="${TIMEOUT_SELF_TEST_LONG_SLEEP_SECONDS:-30}"

PASS_COUNT=0
FAIL_COUNT=0

record_pass() {
  ((PASS_COUNT+=1))
  printf '[PASS] %s\n' "$1"
}

record_fail() {
  ((FAIL_COUNT+=1))
  printf "${RED}[FAIL]${NC} %s\n" "$1"
  printf '       %s\n' "$2"
}

assert_exit_code() {
  local label="$1"
  local expected_status="$2"
  shift 2

  local actual_status=0
  if "$@"; then
    actual_status=0
  else
    actual_status=$?
  fi

  if [[ "${actual_status}" -eq "${expected_status}" ]]; then
    record_pass "${label}"
    return 0
  fi

  record_fail "${label}" "expected exit ${expected_status}, got ${actual_status}"
  return 1
}

assert_timeout_window() {
  local label="$1"
  local timeout_seconds="$2"
  shift 2

  local actual_status=0 elapsed_seconds=0
  local max_elapsed_seconds=$((timeout_seconds + TIMEOUT_SELF_TEST_GRACE_SECONDS + 2))

  SECONDS=0
  if "$@"; then
    actual_status=0
  else
    actual_status=$?
  fi
  elapsed_seconds=$SECONDS

  if [[ "${actual_status}" -ne 124 ]]; then
    record_fail "${label}" "expected exit 124, got ${actual_status}"
    return 1
  fi

  if (( elapsed_seconds > max_elapsed_seconds )); then
    record_fail "${label}" "expected <= ${max_elapsed_seconds}s, observed ${elapsed_seconds}s"
    return 1
  fi

  record_pass "${label}"
  printf '       elapsed=%ss timeout=%ss grace=%ss\n' "${elapsed_seconds}" "${timeout_seconds}" "${TIMEOUT_SELF_TEST_GRACE_SECONDS}"
  return 0
}

timeout_pipeline_probe() {
  local logfile="${TMPDIR:-${ROOT_DIR}/.cache}/timeout-self-test-pipeline.log"
  local status=0

  mkdir -p "$(dirname "${logfile}")"

  if run_with_timeout "${TIMEOUT_SELF_TEST_SECONDS}" bash -c "sleep ${TIMEOUT_SELF_TEST_LONG_SLEEP_SECONDS}" 2>&1 | tee "${logfile}" >/dev/null; then
    status=0
  else
    status=$?
  fi

  return "${status}"
}

main() {
  export RUN_WITH_TIMEOUT_KILL_AFTER_SECONDS="${TIMEOUT_SELF_TEST_GRACE_SECONDS}"

  log "Running deterministic timeout self-test"
  printf '       timeout=%ss grace=%ss long-sleep=%ss\n' \
    "${TIMEOUT_SELF_TEST_SECONDS}" \
    "${TIMEOUT_SELF_TEST_GRACE_SECONDS}" \
    "${TIMEOUT_SELF_TEST_LONG_SLEEP_SECONDS}"

  assert_exit_code "fast command returns success" 0 \
    run_with_timeout 5 bash -c 'exit 0' || true

  assert_exit_code "non-zero exit is preserved" 23 \
    run_with_timeout 5 bash -c 'exit 23' || true

  assert_timeout_window "sleep command times out promptly" "${TIMEOUT_SELF_TEST_SECONDS}" \
    run_with_timeout "${TIMEOUT_SELF_TEST_SECONDS}" bash -c "sleep ${TIMEOUT_SELF_TEST_LONG_SLEEP_SECONDS}" || true

  assert_timeout_window "timeout survives tee pipeline" "${TIMEOUT_SELF_TEST_SECONDS}" \
    timeout_pipeline_probe || true

  printf '\npass=%s fail=%s\n' "${PASS_COUNT}" "${FAIL_COUNT}"
  [[ "${FAIL_COUNT}" -eq 0 ]]
}

main "$@"
