#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5187}"
PROXY_TARGET="${MASC_DASHBOARD_PROXY_TARGET:-http://127.0.0.1:8935}"
FIXTURE_URL="http://${HOST}:${PORT}/dashboard/dev-fixtures/keeper-chat-tool-output-failure-contract-fixture.html"
SERVER_LOG="${TMPDIR:-/tmp}/masc-dashboard-tool-output-failure-contract-vite-${PORT}.log"
DESKTOP_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-tool-output-failure-contract-fixture-desktop.png"
MOBILE_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-tool-output-failure-contract-fixture-mobile.png"
HYDRATION_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-tool-output-failure-contract-hydration-failed.png"
COVERAGE_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-tool-output-failure-contract-coverage-gap.png"

HYDRATION_SIGNATURE='tool:tc-hydration-failed|chat:assistant-hydration-failed'
COVERAGE_SIGNATURE='tool:tc-coverage-gap|chat:assistant-coverage-gap'
STATUS_SELECTOR='[data-tool-output-failure-contract-fixture-status="ok"][data-tool-output-failure-hydration-failed-count="1"][data-tool-output-failure-coverage-gap-count="1"]'
HYDRATION_TRACE_SELECTOR="[data-tool-output-failure-scenario=\"hydration-failed\"] [data-chat-work-trace][data-chat-turn-order-signature=\"${HYDRATION_SIGNATURE}\"][data-chat-tool-output-hydration-source=\"tool_calls_endpoint\"][data-chat-tool-output-hydration-status=\"failed\"][data-chat-tool-output-hydration-failure=\"tool_calls_endpoint_502\"]"
HYDRATION_TOOL_SELECTOR='[data-tool-output-failure-scenario="hydration-failed"] [data-chat-trace-step="tool"][data-chat-turn-order-index="0"][data-chat-turn-order-kind="tool"][data-chat-trace-tool-call-id="tc-hydration-failed"][data-chat-trace-entry-id="tool-tc-hydration-failed"][data-chat-trace-link-state="joined"][data-chat-trace-output-state="hydration-failed"][data-chat-trace-output-coverage="hydration-failed"]'
COVERAGE_TRACE_SELECTOR="[data-tool-output-failure-scenario=\"coverage-gap\"] [data-chat-work-trace][data-chat-turn-order-signature=\"${COVERAGE_SIGNATURE}\"][data-chat-tool-output-hydration-source=\"tool_calls_endpoint\"][data-chat-tool-output-hydration-status=\"hydrated\"][data-chat-tool-output-covered-through=\"1783264270000\"]"
COVERAGE_TOOL_SELECTOR='[data-tool-output-failure-scenario="coverage-gap"] [data-chat-trace-step="tool"][data-chat-turn-order-index="0"][data-chat-turn-order-kind="tool"][data-chat-trace-tool-call-id="tc-coverage-gap"][data-chat-trace-entry-id="tool-tc-coverage-gap"][data-chat-trace-link-state="joined"][data-chat-trace-output-state="coverage-gap"][data-chat-trace-output-coverage="coverage-gap"]'

server_pid=""
cleanup() {
  if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" 2>/dev/null; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

pnpm --dir "${DASHBOARD_DIR}" exec playwright --version >/dev/null

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

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${STATUS_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${DESKTOP_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${HYDRATION_TRACE_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${HYDRATION_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${HYDRATION_TOOL_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${HYDRATION_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${COVERAGE_TRACE_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${COVERAGE_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${COVERAGE_TOOL_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${COVERAGE_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 390,844 \
  --timeout 30000 \
  --wait-for-selector "${STATUS_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${MOBILE_SCREENSHOT}"

printf 'keeper chat tool output failure contract DOM smoke passed\n'
printf 'fixture_url=%s\n' "${FIXTURE_URL}"
printf 'desktop_screenshot=%s\n' "${DESKTOP_SCREENSHOT}"
printf 'mobile_screenshot=%s\n' "${MOBILE_SCREENSHOT}"
printf 'hydration_failed_screenshot=%s\n' "${HYDRATION_SCREENSHOT}"
printf 'coverage_gap_screenshot=%s\n' "${COVERAGE_SCREENSHOT}"
