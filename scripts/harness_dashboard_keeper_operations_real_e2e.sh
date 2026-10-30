#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
source "${ROOT_DIR}/scripts/harness/lib/server_bootstrap.sh"

BASE_PATH="$(harness_mktemp_dir masc-keeper-operation-real-e2e)"
BASE_PATH="$(cd "${BASE_PATH}" && pwd -P)"
PORT="$(harness_pick_free_port)"
KEEPER_NAME="keeper-operation-real-e2e"
ADMIN_AGENT="keeper-operation-real-e2e-admin"
SERVER_EXE="$(harness_find_server_exe "${ROOT_DIR}" "${MASC_REAL_SERVER_EXE:-}")"
SERVER_LOG="${BASE_PATH}/server.log"
ARTIFACT_DIR="${MASC_REAL_KEEPER_ARTIFACT_DIR:-${TMPDIR:-/tmp}/masc-keeper-real-backend-e2e}"
SERVER_PID=""
PASSED=0

cleanup() {
  local status=$?
  if [[ "${PASSED}" != "1" ]]; then
    harness_print_log_tail "${SERVER_LOG}" 160
  fi
  harness_stop_server "${SERVER_PID}"
  case "${BASE_PATH}" in
    */masc-keeper-operation-real-e2e.*) rm -rf -- "${BASE_PATH}" ;;
    *) echo "refusing to remove unexpected harness path: ${BASE_PATH}" >&2 ;;
  esac
  exit "${status}"
}
trap cleanup EXIT

harness_seed_server_config "${ROOT_DIR}" "${BASE_PATH}"
cp \
  "${ROOT_DIR}/scripts/fixtures/keeper-operation-real-e2e/keeper.toml" \
  "${BASE_PATH}/.masc/config/keepers/${KEEPER_NAME}.toml"
mkdir -p "${BASE_PATH}/.masc/keepers"
cp \
  "${ROOT_DIR}/scripts/fixtures/keeper-operation-real-e2e/meta.json" \
  "${BASE_PATH}/.masc/keepers/${KEEPER_NAME}.json"

"${SERVER_EXE}" login \
  --base-path "${BASE_PATH}" \
  --host 127.0.0.1 \
  --port "${PORT}" \
  --agent "${ADMIN_AGENT}" \
  --role admin \
  --client-env MASC_KEEPER_OPERATION_E2E_TOKEN \
  --no-expiry \
  --json >/dev/null

ADMIN_TOKEN_FILE="${BASE_PATH}/.masc/auth/${ADMIN_AGENT}.token"
test -r "${ADMIN_TOKEN_FILE}"

unset DISCORD_BOT_TOKEN SLACK_APP_TOKEN SLACK_BOT_TOKEN
export MASC_HARNESS_KEEPER_AUTONOMOUS_ENABLED=1
SERVER_PID="$(harness_start_server \
  "${SERVER_EXE}" \
  "${PORT}" \
  "${BASE_PATH}" \
  "${SERVER_LOG}")"

if ! harness_wait_for_health "${PORT}" 60; then
  echo "isolated Keeper operation backend did not become healthy" >&2
  exit 1
fi

deadline=$(( $(date +%s) + 60 ))
keeper_ready=0
while [[ "$(date +%s)" -lt "${deadline}" ]]; do
  if curl -fsS "http://127.0.0.1:${PORT}/health?full=1" \
    | jq -e --arg keeper "${KEEPER_NAME}" \
      '.keeper_fleet_safety.running_keeper_names | index($keeper) != null' \
      >/dev/null; then
    keeper_ready=1
    break
  fi
  sleep 1
done

if [[ "${keeper_ready}" != "1" ]]; then
  echo "isolated Keeper did not install its runtime resources" >&2
  exit 1
fi

ADMIN_TOKEN="$(<"${ADMIN_TOKEN_FILE}")"
curl -fsS -X POST \
  "http://127.0.0.1:${PORT}/api/v1/keepers/${KEEPER_NAME}/directive" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "X-MASC-Agent: ${ADMIN_AGENT}" \
  -H "Content-Type: application/json" \
  --data '{"action":"pause"}' \
  >/dev/null
unset ADMIN_TOKEN

mkdir -p "${ARTIFACT_DIR}"
MASC_REAL_DASHBOARD_URL="http://127.0.0.1:${PORT}/dashboard" \
MASC_REAL_DASHBOARD_ADMIN_TOKEN_FILE="${ADMIN_TOKEN_FILE}" \
MASC_REAL_DASHBOARD_ADMIN_AGENT="${ADMIN_AGENT}" \
MASC_REAL_KEEPER_NAME="${KEEPER_NAME}" \
MASC_REAL_EXPECTED_BASE_PATH="${BASE_PATH}" \
MASC_REAL_KEEPER_ARTIFACT_DIR="${ARTIFACT_DIR}" \
  pnpm --dir "${DASHBOARD_DIR}" exec node e2e/keeper-operations-real-backend.mjs

PASSED=1
printf 'Keeper isolated real-backend Playwright E2E passed\n'
