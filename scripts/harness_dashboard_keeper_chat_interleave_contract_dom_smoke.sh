#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5186}"
PROXY_TARGET="${MASC_DASHBOARD_PROXY_TARGET:-http://127.0.0.1:8935}"
FIXTURE_URL="http://${HOST}:${PORT}/dashboard/dev-fixtures/keeper-chat-interleave-contract-fixture.html"
SERVER_LOG="${TMPDIR:-/tmp}/masc-dashboard-interleave-contract-vite-${PORT}.log"
DESKTOP_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-interleave-contract-fixture-desktop.png"
MOBILE_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-interleave-contract-fixture-mobile.png"
TRACE_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-interleave-contract-trace.png"
JOINED_TOOL_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-interleave-contract-joined-tool.png"
TRACE_ONLY_TOOL_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-interleave-contract-trace-only-tool.png"
CHAT_SCREENSHOT="${TMPDIR:-/tmp}/masc-chat-interleave-contract-chat.png"

ORDER_SIGNATURE='trace:think|tool:tc-context|trace:think|tool:tc-missing|chat:assistant-interleave'
STATUS_SELECTOR="[data-interleave-contract-fixture-status=\"ok\"][data-interleave-order-signature=\"${ORDER_SIGNATURE}\"][data-interleave-joined-tool-count=\"1\"][data-interleave-trace-only-tool-count=\"1\"]"
TRACE_SELECTOR="[data-chat-work-trace][data-chat-turn-order-signature=\"${ORDER_SIGNATURE}\"][data-chat-tool-output-hydration-status=\"hydrated\"][data-chat-tool-output-covered-through=\"1783261210000\"]"
JOINED_TOOL_SELECTOR='[data-chat-trace-step="tool"][data-chat-turn-order-index="1"][data-chat-turn-order-kind="tool"][data-chat-trace-tool-call-id="tc-context"][data-chat-trace-entry-id="tool-tc-context"][data-chat-trace-link-state="joined"][data-chat-trace-output-state="ok"][data-chat-trace-output-coverage="covered"]'
TRACE_ONLY_TOOL_SELECTOR='[data-chat-trace-step="tool"][data-chat-turn-order-index="3"][data-chat-turn-order-kind="tool"][data-chat-trace-tool-call-id="tc-missing"][data-chat-trace-link-state="trace-only"][data-chat-trace-output-state="pending"]'
CHAT_SELECTOR='[data-chat-trace-step="chat"][data-chat-turn-order-index="4"][data-chat-turn-order-kind="chat"][data-chat-trace-entry-id="assistant-interleave"]'

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
  --wait-for-selector "${TRACE_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${TRACE_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${JOINED_TOOL_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${JOINED_TOOL_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${TRACE_ONLY_TOOL_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${TRACE_ONLY_TOOL_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 1440,900 \
  --timeout 30000 \
  --wait-for-selector "${CHAT_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${CHAT_SCREENSHOT}"

pnpm --dir "${DASHBOARD_DIR}" exec playwright screenshot \
  --browser chromium \
  --viewport-size 390,844 \
  --timeout 30000 \
  --wait-for-selector "${STATUS_SELECTOR}" \
  "${FIXTURE_URL}" \
  "${MOBILE_SCREENSHOT}"

printf 'keeper chat interleave contract DOM smoke passed\n'
printf 'fixture_url=%s\n' "${FIXTURE_URL}"
printf 'desktop_screenshot=%s\n' "${DESKTOP_SCREENSHOT}"
printf 'mobile_screenshot=%s\n' "${MOBILE_SCREENSHOT}"
printf 'trace_screenshot=%s\n' "${TRACE_SCREENSHOT}"
printf 'joined_tool_screenshot=%s\n' "${JOINED_TOOL_SCREENSHOT}"
printf 'trace_only_tool_screenshot=%s\n' "${TRACE_ONLY_TOOL_SCREENSHOT}"
printf 'chat_screenshot=%s\n' "${CHAT_SCREENSHOT}"
