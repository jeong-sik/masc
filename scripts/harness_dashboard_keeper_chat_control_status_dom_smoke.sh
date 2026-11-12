#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/harness/lib/dashboard_dev_server.sh
source "${ROOT_DIR}/scripts/harness/lib/dashboard_dev_server.sh"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5188}"
PROXY_TARGET="${MASC_DASHBOARD_PROXY_TARGET:-http://127.0.0.1:8935}"
FIXTURE_URL="http://${HOST}:${PORT}/dashboard/dev-fixtures/keeper-chat-control-status-fixture.html"
SERVER_LOG="${TMPDIR:-/tmp}/masc-dashboard-control-status-vite-${PORT}.log"
DESKTOP_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-control-status-desktop.png"
MOBILE_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-control-status-mobile.png"
BROWSER_SCRIPT="${ROOT_DIR}/scripts/harness_dashboard_keeper_chat_control_status_dom_smoke.py"

trap harness_dashboard_dev_server_stop_on_exit EXIT

MASC_DASHBOARD_PROXY_TARGET="${PROXY_TARGET}" \
  harness_dashboard_dev_server_start "${DASHBOARD_DIR}" "${HOST}" "${PORT}" "${FIXTURE_URL}" "${SERVER_LOG}"

FIXTURE_URL="${FIXTURE_URL}" \
DESKTOP_SCREENSHOT="${DESKTOP_SCREENSHOT}" \
MOBILE_SCREENSHOT="${MOBILE_SCREENSHOT}" \
python3 "${BROWSER_SCRIPT}"

printf 'keeper chat control-status DOM smoke passed\n'
printf 'fixture_url=%s\n' "${FIXTURE_URL}"
printf 'desktop_screenshot=%s\n' "${DESKTOP_SCREENSHOT}"
printf 'mobile_screenshot=%s\n' "${MOBILE_SCREENSHOT}"
