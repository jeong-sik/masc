#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/harness/lib/dashboard_dev_server.sh
source "${ROOT_DIR}/scripts/harness/lib/dashboard_dev_server.sh"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5189}"
PROXY_TARGET="${MASC_DASHBOARD_PROXY_TARGET:-http://127.0.0.1:8935}"
FIXTURE_URL="http://${HOST}:${PORT}/dashboard/dev-fixtures/keeper-chat-queued-stream-fixture.html"
SERVER_LOG="${TMPDIR:-/tmp}/masc-dashboard-queued-stream-vite-${PORT}.log"
ARTIFACT_DIR="${KEEPER_QUEUED_STREAM_ARTIFACT_DIR:-${TMPDIR:-/tmp}}"

mkdir -p "${ARTIFACT_DIR}"

trap harness_dashboard_dev_server_stop_on_exit EXIT

pnpm --dir "${DASHBOARD_DIR}" exec playwright --version >/dev/null
MASC_DASHBOARD_PROXY_TARGET="${PROXY_TARGET}" \
  harness_dashboard_dev_server_start "${DASHBOARD_DIR}" "${HOST}" "${PORT}" "${FIXTURE_URL}" "${SERVER_LOG}"
KEEPER_QUEUED_STREAM_FIXTURE_URL="${FIXTURE_URL}" \
KEEPER_QUEUED_STREAM_ARTIFACT_DIR="${ARTIFACT_DIR}" \
  pnpm --dir "${DASHBOARD_DIR}" exec node e2e/keeper-queued-stream.mjs

printf 'keeper queued stream Playwright E2E passed\n'
