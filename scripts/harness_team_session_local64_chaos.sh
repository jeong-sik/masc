#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOAD_SCRIPT_OVERRIDE="$SCRIPT_DIR/harness/workload/team_session_local64_chaos.sh"
export WORKLOAD_SCRIPT_OVERRIDE
MASC_LLAMA_RUNTIME_COOLDOWN_SEC="${MASC_LLAMA_RUNTIME_COOLDOWN_SEC:-180}"
export MASC_LLAMA_RUNTIME_COOLDOWN_SEC
exec "$SCRIPT_DIR/harness_team_session_local64_smoke.sh" "$@"
