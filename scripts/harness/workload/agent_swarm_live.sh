#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

RUN_ID="${RUN_ID:-keeper-fleet-readiness-$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="${RUN_DIR:-$REPO_ROOT/logs/keeper_fleet_readiness/$RUN_ID}"
BASE_PATH="${BASE_PATH:-${MASC_BASE_PATH:-$HOME/me}}"
EXPECTED_KEEPERS="${EXPECTED_KEEPERS:-18}"
KEEPER_NAMES="${KEEPER_NAMES:-}"
MAX_TRACES_PER_KEEPER="${MAX_TRACES_PER_KEEPER:-20}"
MAX_TURNS_PER_KEEPER="${MAX_TURNS_PER_KEEPER:-3}"
MIN_TERMINAL_TURNS_PER_KEEPER="${MIN_TERMINAL_TURNS_PER_KEEPER:-3}"
MIN_SUCCESS_TURNS_PER_KEEPER="${MIN_SUCCESS_TURNS_PER_KEEPER:-3}"
MIN_PROVIDER_TURNS_PER_KEEPER="${MIN_PROVIDER_TURNS_PER_KEEPER:-3}"
MIN_SUCCESS_PROVIDER_TURNS_PER_KEEPER="${MIN_SUCCESS_PROVIDER_TURNS_PER_KEEPER:-3}"
MIN_TERMINAL_TURNS="${MIN_TERMINAL_TURNS:-}"
MIN_SUCCESS_TURNS="${MIN_SUCCESS_TURNS:-}"
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-0}"

usage() {
  cat <<'EOF'
Usage: scripts/harness_agent_swarm_live.sh [options]

Keeper fleet production-readiness gate against persisted runtime truth.

This entrypoint scans the persisted keeper runtime evidence:
runtime manifests, receipts, checkpoints, provider attempt closure, memory
injection, and tool-call logs. It is read-only and does not start keepers.

Options:
  --base-path PATH                    MASC base path containing .masc.
  --expected-keepers N                Minimum keepers with manifest evidence.
  --keeper-names CSV                  Restrict the scan to explicit keepers.
  --max-traces-per-keeper N           Recent manifest traces to scan per keeper.
  --max-turns-per-keeper N            Latest terminal turns to evaluate per keeper.
  --min-terminal-turns-per-keeper N   Required terminal turns per keeper.
  --min-success-turns-per-keeper N    Required successful turns per keeper.
  --min-provider-turns-per-keeper N   Required provider-dispatched turns per keeper.
  --min-success-provider-turns-per-keeper N
                                      Required successful provider turns per keeper.
  --run-id ID                         Stable artifact run id.
  --run-dir PATH                      Artifact directory.
  --preflight-only                    Print the resolved gate plan and exit.
  -h, --help                          Show this help.

Environment variables with the same uppercase names are also supported.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-path)
      BASE_PATH="$2"
      shift 2
      ;;
    --expected-keepers)
      EXPECTED_KEEPERS="$2"
      shift 2
      ;;
    --keeper-names)
      KEEPER_NAMES="$2"
      shift 2
      ;;
    --max-traces-per-keeper)
      MAX_TRACES_PER_KEEPER="$2"
      shift 2
      ;;
    --max-turns-per-keeper)
      MAX_TURNS_PER_KEEPER="$2"
      shift 2
      ;;
    --min-terminal-turns-per-keeper)
      MIN_TERMINAL_TURNS_PER_KEEPER="$2"
      shift 2
      ;;
    --min-success-turns-per-keeper)
      MIN_SUCCESS_TURNS_PER_KEEPER="$2"
      shift 2
      ;;
    --min-provider-turns-per-keeper)
      MIN_PROVIDER_TURNS_PER_KEEPER="$2"
      shift 2
      ;;
    --min-success-provider-turns-per-keeper)
      MIN_SUCCESS_PROVIDER_TURNS_PER_KEEPER="$2"
      shift 2
      ;;
    --run-id)
      RUN_ID="$2"
      if [[ "${RUN_DIR:-}" == "$REPO_ROOT/logs/keeper_fleet_readiness/"* ]]; then
        RUN_DIR="$REPO_ROOT/logs/keeper_fleet_readiness/$RUN_ID"
      fi
      shift 2
      ;;
    --run-dir)
      RUN_DIR="$2"
      shift 2
      ;;
    --preflight-only)
      PREFLIGHT_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

require_uint() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$name must be a non-negative integer, got: $value" >&2
    exit 64
  fi
}

require_uint EXPECTED_KEEPERS "$EXPECTED_KEEPERS"
require_uint MAX_TRACES_PER_KEEPER "$MAX_TRACES_PER_KEEPER"
require_uint MAX_TURNS_PER_KEEPER "$MAX_TURNS_PER_KEEPER"
require_uint MIN_TERMINAL_TURNS_PER_KEEPER "$MIN_TERMINAL_TURNS_PER_KEEPER"
require_uint MIN_SUCCESS_TURNS_PER_KEEPER "$MIN_SUCCESS_TURNS_PER_KEEPER"
require_uint MIN_PROVIDER_TURNS_PER_KEEPER "$MIN_PROVIDER_TURNS_PER_KEEPER"
require_uint MIN_SUCCESS_PROVIDER_TURNS_PER_KEEPER "$MIN_SUCCESS_PROVIDER_TURNS_PER_KEEPER"

if [[ -z "$MIN_TERMINAL_TURNS" ]]; then
  MIN_TERMINAL_TURNS=$((EXPECTED_KEEPERS * MIN_TERMINAL_TURNS_PER_KEEPER))
fi
if [[ -z "$MIN_SUCCESS_TURNS" ]]; then
  MIN_SUCCESS_TURNS=$((EXPECTED_KEEPERS * MIN_SUCCESS_TURNS_PER_KEEPER))
fi
require_uint MIN_TERMINAL_TURNS "$MIN_TERMINAL_TURNS"
require_uint MIN_SUCCESS_TURNS "$MIN_SUCCESS_TURNS"

command -v jq >/dev/null 2>&1 || {
  echo "jq is required" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required" >&2
  exit 1
}

SUMMARY_JSON="$RUN_DIR/summary.json"
SUMMARY_MD="$RUN_DIR/summary.md"
GATE_STDOUT="$RUN_DIR/gate-output.json"

gate_args=(
  "$REPO_ROOT/scripts/keeper-production-readiness-gate.py"
  --base-path "$BASE_PATH"
  --expected-keepers "$EXPECTED_KEEPERS"
  --max-traces-per-keeper "$MAX_TRACES_PER_KEEPER"
  --max-turns-per-keeper "$MAX_TURNS_PER_KEEPER"
  --min-terminal-turns "$MIN_TERMINAL_TURNS"
  --min-success-turns "$MIN_SUCCESS_TURNS"
  --min-terminal-turns-per-keeper "$MIN_TERMINAL_TURNS_PER_KEEPER"
  --min-success-turns-per-keeper "$MIN_SUCCESS_TURNS_PER_KEEPER"
  --min-provider-turns-per-keeper "$MIN_PROVIDER_TURNS_PER_KEEPER"
  --min-success-provider-turns-per-keeper "$MIN_SUCCESS_PROVIDER_TURNS_PER_KEEPER"
  --output "$SUMMARY_JSON"
  --json
)

if [[ -n "$KEEPER_NAMES" ]]; then
  IFS=',' read -r -a keeper_name_parts <<<"$KEEPER_NAMES"
  for raw_keeper in "${keeper_name_parts[@]}"; do
    keeper="$(printf '%s' "$raw_keeper" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [[ -n "$keeper" ]]; then
      gate_args+=(--keeper "$keeper")
    fi
  done
fi

if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
  jq -nc \
    --arg run_id "$RUN_ID" \
    --arg run_dir "$RUN_DIR" \
    --arg base_path "$BASE_PATH" \
    --argjson expected_keepers "$EXPECTED_KEEPERS" \
    --argjson max_turns_per_keeper "$MAX_TURNS_PER_KEEPER" \
    --argjson min_terminal_turns "$MIN_TERMINAL_TURNS" \
    --argjson min_success_turns "$MIN_SUCCESS_TURNS" \
    --argjson min_terminal_turns_per_keeper "$MIN_TERMINAL_TURNS_PER_KEEPER" \
    --argjson min_success_provider_turns_per_keeper "$MIN_SUCCESS_PROVIDER_TURNS_PER_KEEPER" \
    '{status:"planned",run_id:$run_id,run_dir:$run_dir,base_path:$base_path,
      expected_keepers:$expected_keepers,
      max_turns_per_keeper:$max_turns_per_keeper,
      min_terminal_turns:$min_terminal_turns,
      min_success_turns:$min_success_turns,
      min_terminal_turns_per_keeper:$min_terminal_turns_per_keeper,
      min_success_provider_turns_per_keeper:$min_success_provider_turns_per_keeper}'
  exit 0
fi

mkdir -p "$RUN_DIR"

set +e
python3 "${gate_args[@]}" >"$GATE_STDOUT"
gate_exit=$?
set -e

status="$(jq -r '.status // "UNKNOWN"' "$SUMMARY_JSON" 2>/dev/null || printf 'UNKNOWN')"
keeper_count="$(jq -r '(.keepers // []) | length' "$SUMMARY_JSON" 2>/dev/null || printf '0')"
terminal_turns="$(jq -r '.metrics.terminal_turns // 0' "$SUMMARY_JSON" 2>/dev/null || printf '0')"
success_provider_turns="$(jq -r '.metrics.success_provider_turns // 0' "$SUMMARY_JSON" 2>/dev/null || printf '0')"

cat >"$SUMMARY_MD" <<EOF
# Keeper Fleet Readiness

- Run ID: \`$RUN_ID\`
- Status: **$status**
- Base path: \`$BASE_PATH\`
- Expected keepers: \`$EXPECTED_KEEPERS\`
- Observed keepers: \`$keeper_count\`
- Terminal turns: \`$terminal_turns\`
- Successful provider turns: \`$success_provider_turns\`

## Artifacts

- Summary JSON: \`$SUMMARY_JSON\`
- Gate stdout: \`$GATE_STDOUT\`

## Contract

This gate inspects read-only keeper runtime evidence. A passing run proves that
persisted keeper runtime manifests have complete receipt, checkpoint,
provider-closure,
memory-injection, and tool-log chains for the configured 18+ keeper fleet.
EOF

jq -nc \
  --arg run_id "$RUN_ID" \
  --arg status "$status" \
  --arg run_dir "$RUN_DIR" \
  --arg summary_json "$SUMMARY_JSON" \
  --arg summary_md "$SUMMARY_MD" \
  --argjson expected_keepers "$EXPECTED_KEEPERS" \
  --argjson observed_keepers "$keeper_count" \
  --argjson terminal_turns "$terminal_turns" \
  --argjson success_provider_turns "$success_provider_turns" \
  '{run_id:$run_id,status:$status,pass:($status == "PASS"),run_dir:$run_dir,
    summary_json:$summary_json,summary_md:$summary_md,
    expected_keepers:$expected_keepers,observed_keepers:$observed_keepers,
    terminal_turns:$terminal_turns,success_provider_turns:$success_provider_turns}'

exit "$gate_exit"
