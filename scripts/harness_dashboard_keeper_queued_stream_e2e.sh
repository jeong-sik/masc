#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5189}"
PROXY_TARGET="${MASC_DASHBOARD_PROXY_TARGET:-http://127.0.0.1:8935}"
FIXTURE_URL="http://${HOST}:${PORT}/dashboard/dev-fixtures/keeper-chat-queued-stream-fixture.html"
SERVER_LOG="${TMPDIR:-/tmp}/masc-dashboard-queued-stream-vite-${PORT}.log"
ARTIFACT_DIR="${KEEPER_QUEUED_STREAM_ARTIFACT_DIR:-${TMPDIR:-/tmp}}"

mkdir -p "${ARTIFACT_DIR}"

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
KEEPER_QUEUED_STREAM_FIXTURE_URL="${FIXTURE_URL}" \
KEEPER_QUEUED_STREAM_ARTIFACT_DIR="${ARTIFACT_DIR}" \
  pnpm --dir "${DASHBOARD_DIR}" exec node e2e/keeper-queued-stream.mjs

printf 'keeper queued stream Playwright E2E passed\n'
