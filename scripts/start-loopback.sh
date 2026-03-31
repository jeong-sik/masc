#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

exec "$REPO_ROOT/start-masc-mcp.sh" --http --host 127.0.0.1 --port 8935 "$@"
