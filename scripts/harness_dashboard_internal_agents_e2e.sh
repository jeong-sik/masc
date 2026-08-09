#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="${ROOT_DIR}/dashboard"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-5192}"
FIXTURE_URL="http://${HOST}:${PORT}/dashboard/dev-fixtures/internal-agents-monitor-fixture.html"
SERVER_LOG="${TMPDIR:-/tmp}/masc-dashboard-internal-agents-vite-${PORT}.log"
ARTIFACT_DIR="${INTERNAL_AGENTS_ARTIFACT_DIR:-${TMPDIR:-/tmp}}"

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
MASC_DASHBOARD_PROXY_TARGET="${MASC_DASHBOARD_PROXY_TARGET:-http://127.0.0.1:8935}" \
pnpm --dir "${DASHBOARD_DIR}" exec vite --host "${HOST}" --port "${PORT}" --strictPort \
  >"${SERVER_LOG}" 2>&1 &
server_pid="$!"

for _ in {1..80}; do
  if curl -fsS "${FIXTURE_URL}" >/dev/null 2>&1; then break; fi
  if ! kill -0 "${server_pid}" 2>/dev/null; then
    sed -n '1,200p' "${SERVER_LOG}" >&2
    exit 1
  fi
  sleep 0.25
done

curl -fsS "${FIXTURE_URL}" >/dev/null
INTERNAL_AGENTS_FIXTURE_URL="${FIXTURE_URL}" \
INTERNAL_AGENTS_ARTIFACT_DIR="${ARTIFACT_DIR}" \
  pnpm --dir "${DASHBOARD_DIR}" exec node e2e/internal-agents-monitor.mjs

printf 'internal agents Playwright E2E passed\n'
