#!/usr/bin/env bash
# Common helpers for transport E2E harness scripts.
# Source this from each verify_*.sh script.

set -euo pipefail

MASC_HTTP_PORT="${MASC_HTTP_PORT:-8935}"
MASC_GRPC_PORT="${MASC_GRPC_PORT:-8936}"
MASC_WS_PORT="${MASC_WS_PORT:-8937}"
MASC_BASE_URL="http://127.0.0.1:${MASC_HTTP_PORT}"
MASC_GRPC_ADDR="127.0.0.1:${MASC_GRPC_PORT}"
MASC_WS_URL="ws://127.0.0.1:${MASC_WS_PORT}"

PASS=0
FAIL=0
SKIP=0

pass() {
  PASS=$((PASS + 1))
  printf '  \033[32mPASS\033[0m %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m %s: %s\n' "$1" "${2:-}"
}

skip() {
  SKIP=$((SKIP + 1))
  printf '  \033[33mSKIP\033[0m %s: %s\n' "$1" "${2:-}"
}

summary() {
  echo ""
  printf '=== %s: %d passed, %d failed, %d skipped ===\n' \
    "${HARNESS_NAME:-transport}" "$PASS" "$FAIL" "$SKIP"
  [ "$FAIL" -eq 0 ]
}

# Check if MASC server is running on the expected port.
require_server() {
  if ! curl -sf "${MASC_BASE_URL}/health" >/dev/null 2>&1; then
    echo "ERROR: MASC server not running on ${MASC_BASE_URL}"
    echo "Start it with: ./start-masc-mcp.sh --http --port ${MASC_HTTP_PORT}"
    exit 2
  fi
}

# Check if a CLI tool is available.
require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "WARN: $tool not found, some tests will be skipped"
    return 1
  fi
  return 0
}
