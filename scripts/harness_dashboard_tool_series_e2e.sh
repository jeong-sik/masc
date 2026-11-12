#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/harness/lib/dashboard_dev_server.sh
source "${ROOT_DIR}/scripts/harness/lib/dashboard_dev_server.sh"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5194}"
# The test answers the dev token and the series endpoint itself. Every other request must not
# reach a live server, so the proxy points at a port nothing listens on.
PROXY_TARGET="${MASC_DASHBOARD_PROXY_TARGET:-http://127.0.0.1:9}"
APP_URL="http://${HOST}:${PORT}/dashboard/"
SERVER_LOG="${TMPDIR:-/tmp}/masc-dashboard-tool-series-vite-${PORT}.log"
ARTIFACT_DIR="${TOOL_SERIES_ARTIFACT_DIR:-${TMPDIR:-/tmp}}"

mkdir -p "${ARTIFACT_DIR}"

trap harness_dashboard_dev_server_stop_on_exit EXIT

pnpm --dir "${DASHBOARD_DIR}" exec playwright --version >/dev/null
MASC_DASHBOARD_PROXY_TARGET="${PROXY_TARGET}" \
  harness_dashboard_dev_server_start "${DASHBOARD_DIR}" "${HOST}" "${PORT}" "${APP_URL}" "${SERVER_LOG}"
TOOL_SERIES_APP_URL="${APP_URL}" \
TOOL_SERIES_ARTIFACT_DIR="${ARTIFACT_DIR}" \
  pnpm --dir "${DASHBOARD_DIR}" exec node e2e/tool-series.mjs

printf 'tool series panel Playwright E2E passed\n'
