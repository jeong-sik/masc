#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5188}"
PROXY_TARGET="${MASC_DASHBOARD_PROXY_TARGET:-http://127.0.0.1:8935}"
FIXTURE_URL="http://${HOST}:${PORT}/dashboard/dev-fixtures/keeper-chat-control-status-fixture.html"
SERVER_LOG="${TMPDIR:-/tmp}/masc-dashboard-control-status-vite-${PORT}.log"
DESKTOP_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-control-status-desktop.png"
MOBILE_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-control-status-mobile.png"
BROWSER_SCRIPT="${ROOT_DIR}/scripts/harness_dashboard_keeper_chat_control_status_dom_smoke.py"

server_pid=""
cleanup() {
  if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" 2>/dev/null; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

MASC_DASHBOARD_PROXY_TARGET="${PROXY_TARGET}" \
  pnpm --dir "${DASHBOARD_DIR}" exec vite --host "${HOST}" --port "${PORT}" --strictPort \
  >"${SERVER_LOG}" 2>&1 &
server_pid="$!"

for _ in {1..80}; do
  if curl -fsS "${FIXTURE_URL}" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "${server_pid}" 2>/dev/null; then
    cat "${SERVER_LOG}" >&2
    exit 1
  fi
  sleep 0.25
done

curl -fsS "${FIXTURE_URL}" >/dev/null

FIXTURE_URL="${FIXTURE_URL}" \
DESKTOP_SCREENSHOT="${DESKTOP_SCREENSHOT}" \
MOBILE_SCREENSHOT="${MOBILE_SCREENSHOT}" \
python3 "${BROWSER_SCRIPT}"

printf 'keeper chat control-status DOM smoke passed\n'
printf 'fixture_url=%s\n' "${FIXTURE_URL}"
printf 'desktop_screenshot=%s\n' "${DESKTOP_SCREENSHOT}"
printf 'mobile_screenshot=%s\n' "${MOBILE_SCREENSHOT}"
