#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOAD_SCRIPT_OVERRIDE="$SCRIPT_DIR/harness/workload/team_session_local64_context_chaos.sh"
export WORKLOAD_SCRIPT_OVERRIDE
export MASC_LOCAL_WORKER_MAX_TOKENS="${MASC_LOCAL_WORKER_MAX_TOKENS:-256}"
exec "$SCRIPT_DIR/harness_team_session_local64_smoke.sh" "$@"
