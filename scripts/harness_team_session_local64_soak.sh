#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOAD_SCRIPT_OVERRIDE="$SCRIPT_DIR/harness/workload/team_session_local64_soak.sh"
export WORKLOAD_SCRIPT_OVERRIDE
exec "$SCRIPT_DIR/harness_team_session_local64_smoke.sh" "$@"
