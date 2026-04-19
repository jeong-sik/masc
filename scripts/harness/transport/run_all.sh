#!/usr/bin/env bash
# Run all transport E2E harness scripts.
#
# Usage:
#   ./scripts/harness/transport/run_all.sh
#
# Behavior:
#   - Self-bootstraps an isolated local server when none is running
#   - grpcurl required for gRPC checks
#   - Python 3 builtin socket fallback used for WebSocket frame tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0
EXIT_CODE=0

run_harness() {
  local script="$1"
  local name
  name=$(basename "$script" .sh)
  echo ""
  echo "================================================================"
  echo "  Running: ${name}"
  echo "================================================================"
  if bash "$script"; then
    TOTAL_PASS=$((TOTAL_PASS + 1))
  else
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    EXIT_CODE=1
  fi
}

echo "MASC Transport E2E Harness Suite"
echo "================================"

run_harness "${SCRIPT_DIR}/verify_sse.sh"
run_harness "${SCRIPT_DIR}/verify_grpc_subscribe.sh"
run_harness "${SCRIPT_DIR}/verify_h2c_autodetect.sh"
run_harness "${SCRIPT_DIR}/verify_ws.sh"
run_harness "${SCRIPT_DIR}/verify_webrtc_signaling.sh"
run_harness "${SCRIPT_DIR}/verify_truth.sh"
run_harness "${SCRIPT_DIR}/verify_playbook_consistency.sh"

echo ""
echo "================================================================"
echo "  OVERALL: ${TOTAL_PASS} harnesses passed, ${TOTAL_FAIL} failed"
echo "================================================================"
exit $EXIT_CODE
