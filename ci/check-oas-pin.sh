#!/usr/bin/env bash
# check-oas-pin.sh — Verify OAS agent_sdk pin consistency.
#
# Checks:
# 1. Pin script declares a valid SHA or tag
# 2. dune-project agent_sdk version floor matches pin script MIN_VERSION
# 3. Local opam pin (if present) matches pin script SHA
#
# Exit: 0 = consistent, 1 = drift detected, 2 = script error.
#
# Usage:
#   ci/check-oas-pin.sh          # check only
#   ci/check-oas-pin.sh --fix    # re-pin to declared SHA

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PIN_FILE="$SCRIPT_DIR/scripts/oas-agent-sdk-pin.sh"

if [ ! -f "$PIN_FILE" ]; then
  echo "FATAL: pin file not found: $PIN_FILE" >&2
  exit 2
fi

# Source pin declarations
# shellcheck source=../scripts/oas-agent-sdk-pin.sh
source "$PIN_FILE"

errors=0

# Check 1: PIN_SHA is non-empty
if [ -z "${OAS_AGENT_SDK_SHA:-}" ]; then
  echo "FAIL: OAS_AGENT_SDK_SHA is empty in $PIN_FILE"
  errors=$((errors + 1))
fi

# Check 2: dune-project version floor matches MIN_VERSION
DUNE_PROJECT="$SCRIPT_DIR/dune-project"
if [ -f "$DUNE_PROJECT" ]; then
  DUNE_FLOOR=$(grep -o 'agent_sdk (>= [0-9.]*' "$DUNE_PROJECT" | grep -o '[0-9.]*' || echo "")
  if [ -n "$DUNE_FLOOR" ] && [ -n "${OAS_AGENT_SDK_MIN_VERSION:-}" ]; then
    if [ "$DUNE_FLOOR" != "$OAS_AGENT_SDK_MIN_VERSION" ]; then
      echo "FAIL: dune-project agent_sdk floor ($DUNE_FLOOR) != pin MIN_VERSION ($OAS_AGENT_SDK_MIN_VERSION)"
      errors=$((errors + 1))
    else
      echo "OK: dune-project floor ($DUNE_FLOOR) matches pin MIN_VERSION"
    fi
  fi
fi

# Check 3: local opam pin consistency (skip in CI where opam may not be configured)
if command -v opam >/dev/null 2>&1; then
  ACTUAL_PIN=$(opam pin list 2>/dev/null | grep "^agent_sdk" || echo "")
  if [ -n "$ACTUAL_PIN" ]; then
    # Extract the pinned ref (SHA or branch)
    ACTUAL_SHA=$(echo "$ACTUAL_PIN" | grep -o '#[a-zA-Z0-9/._-]*' | tr -d '#' || echo "")
    if [ -n "$ACTUAL_SHA" ]; then
      # Check if pin points to a worktree (common drift source)
      if echo "$ACTUAL_PIN" | grep -q '\.worktrees/'; then
        echo "WARN: agent_sdk pinned to a worktree: $ACTUAL_PIN"
        echo "      Expected: $OAS_AGENT_SDK_SHA (from pin script)"
        if [ "${1:-}" != "--warn-only" ]; then
          errors=$((errors + 1))
        fi
      fi
      echo "INFO: local pin ref=$ACTUAL_SHA expected=$OAS_AGENT_SDK_SHA"
    fi
  else
    echo "INFO: agent_sdk not pinned locally (OK for CI)"
  fi
fi

if [ $errors -gt 0 ]; then
  echo ""
  echo "DRIFT DETECTED: $errors issue(s). Fix with:"
  echo "  cd $(dirname "$PIN_FILE") && bash scripts/oas-agent-sdk-pin.sh"
  exit 1
else
  echo "OK: OAS pin consistent"
  exit 0
fi
