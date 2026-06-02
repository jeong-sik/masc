#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Local loopback is the safe single-user path; keepers can still be started
# explicitly, but do not autoboot a whole keeper set on 8935 unless requested.
export MASC_KEEPER_BOOTSTRAP_ENABLED="${MASC_KEEPER_BOOTSTRAP_ENABLED:-false}"

exec "$REPO_ROOT/start-masc-mcp.sh" --http --host 127.0.0.1 --port 8935 "$@"
