#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# trunk 0.21 expects boolean values for --no-color.
# Some environments export NO_COLOR as 1/0, which breaks trunk argument parsing.
if [[ "${NO_COLOR:-}" == "1" ]]; then
  export NO_COLOR=true
elif [[ "${NO_COLOR:-}" == "0" ]]; then
  export NO_COLOR=false
fi

cd "$REPO_ROOT/viewer"
exec trunk "$@"
