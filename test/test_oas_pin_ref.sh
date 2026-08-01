#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/oas-pin-ref.sh
source "${SCRIPT_DIR}/scripts/oas-pin-ref.sh"

expect_value() {
  local description="$1" expected="$2" configured_ref="$3" actual
  actual="$(oas_pin_remote_ref "${configured_ref}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "FAIL: ${description}: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
}

expect_reject() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: ${description}: expected rejection" >&2
    exit 1
  fi
}

expect_value "main shorthand" "refs/heads/main" "main"
expect_value "full main ref" "refs/heads/main" "refs/heads/main"
expect_value "review ref" "refs/pull/2910/head" "refs/pull/2910/head"
expect_reject "malformed review ref" oas_pin_remote_ref "refs/pull/0/head"
expect_reject "unknown namespace" oas_pin_remote_ref "refs/tags/v1"

oas_pin_require_track_policy "refs/heads/main" 0
oas_pin_require_track_policy "refs/pull/2910/head" 1
expect_reject \
  "review ref without explicit Draft allowance" \
  oas_pin_require_track_policy "refs/pull/2910/head" 0
expect_reject \
  "feature branch is not a dependency publication ref" \
  oas_pin_require_track_policy "refs/heads/feature" 1

echo "[oas-pin-ref test] PASS"
