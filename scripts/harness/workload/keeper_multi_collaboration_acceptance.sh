#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/keeper_multi_collaboration_acceptance.py"
MODE="${KEEPER_COLLAB_ACCEPTANCE_MODE:-run}"

args=(
  "--mcp-url" "${MCP_URL:-http://127.0.0.1:8935/mcp}"
  "--timeout" "${KEEPER_COLLAB_TIMEOUT_SEC:-150}"
)

if [[ -n "${KEEPER_COLLAB_HEALTH_URL:-}" ]]; then
  args+=("--health-url" "$KEEPER_COLLAB_HEALTH_URL")
fi
if [[ -n "${MCP_TOKEN_FILE:-}" ]]; then
  args+=("--token-file" "$MCP_TOKEN_FILE")
fi
if [[ -n "${KEEPER_COLLAB_EXPECTED_BASE_PATH:-}" ]]; then
  args+=("--expected-base-path" "$KEEPER_COLLAB_EXPECTED_BASE_PATH")
fi
if [[ -n "${KEEPER_COLLAB_EXPECTED_SOURCE_SHA:-}" ]]; then
  args+=("--expected-source-sha" "$KEEPER_COLLAB_EXPECTED_SOURCE_SHA")
fi
if [[ -n "${KEEPER_COLLAB_RUNTIME_ID:-}" ]]; then
  args+=("--runtime-id" "$KEEPER_COLLAB_RUNTIME_ID")
fi
if [[ -n "${KEEPER_COLLAB_SANDBOX_PROFILE:-}" ]]; then
  args+=("--sandbox-profile" "$KEEPER_COLLAB_SANDBOX_PROFILE")
fi
if [[ -n "${KEEPER_COLLAB_RUN_ID:-}" ]]; then
  args+=("--run-id" "$KEEPER_COLLAB_RUN_ID")
fi

case "$MODE" in
  validate)
    exec python3 "$RUNNER" --validate-catalog
    ;;
  verify)
    if [[ -z "${KEEPER_COLLAB_OUTPUT_DIR:-}" ]]; then
      echo "KEEPER_COLLAB_OUTPUT_DIR is required for bundle verification" >&2
      exit 64
    fi
    if [[ -z "${KEEPER_COLLAB_EXPECTED_BASE_PATH:-}" ]]; then
      echo "KEEPER_COLLAB_EXPECTED_BASE_PATH is required for bundle verification" >&2
      exit 64
    fi
    if [[ -z "${KEEPER_COLLAB_EXPECTED_SOURCE_SHA:-}" ]]; then
      echo "KEEPER_COLLAB_EXPECTED_SOURCE_SHA is required for bundle verification" >&2
      exit 64
    fi
    verify_args=(--verify --output-dir "$KEEPER_COLLAB_OUTPUT_DIR")
    if [[ -n "${KEEPER_COLLAB_EXPECTED_BASE_PATH:-}" ]]; then
      verify_args+=(--expected-base-path "$KEEPER_COLLAB_EXPECTED_BASE_PATH")
    fi
    if [[ -n "${KEEPER_COLLAB_EXPECTED_SOURCE_SHA:-}" ]]; then
      verify_args+=(--expected-source-sha "$KEEPER_COLLAB_EXPECTED_SOURCE_SHA")
    fi
    exec python3 "$RUNNER" "${verify_args[@]}"
    ;;
  preflight)
    exec python3 "$RUNNER" --preflight "${args[@]}"
    ;;
  run)
    if [[ "${KEEPER_COLLAB_ALLOW_MUTATION:-0}" != "1" ]]; then
      echo "KEEPER_COLLAB_ALLOW_MUTATION=1 is required for the real-world run" >&2
      exit 64
    fi
    if [[ -z "${KEEPER_COLLAB_EXPECTED_BASE_PATH:-}" ]]; then
      echo "KEEPER_COLLAB_EXPECTED_BASE_PATH is required for the real-world run" >&2
      exit 64
    fi
    if [[ -z "${KEEPER_COLLAB_EXPECTED_SOURCE_SHA:-}" ]]; then
      echo "KEEPER_COLLAB_EXPECTED_SOURCE_SHA is required for the real-world run" >&2
      exit 64
    fi
    if [[ -z "${KEEPER_COLLAB_OUTPUT_DIR:-}" ]]; then
      echo "KEEPER_COLLAB_OUTPUT_DIR is required for the real-world run" >&2
      exit 64
    fi
    exec python3 "$RUNNER" --run --allow-mutation \
      --output-dir "$KEEPER_COLLAB_OUTPUT_DIR" "${args[@]}"
    ;;
  *)
    echo "unknown KEEPER_COLLAB_ACCEPTANCE_MODE: $MODE (validate|verify|preflight|run)" >&2
    exit 64
    ;;
esac
