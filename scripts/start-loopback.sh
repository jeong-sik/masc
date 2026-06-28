#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Local loopback is the safe single-user path. Ignore inherited
# MASC_KEEPER_BOOTSTRAP_ENABLED by default so a global shell profile cannot
# accidentally autoboot a whole keeper set on 8935.
keeper_bootstrap_enabled=false
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-keeper-bootstrap)
      keeper_bootstrap_enabled=true
      shift
      ;;
    --no-keeper-bootstrap)
      keeper_bootstrap_enabled=false
      shift
      ;;
    --)
      shift
      args+=("$@")
      break
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

export MASC_KEEPER_BOOTSTRAP_ENABLED="$keeper_bootstrap_enabled"

exec "$REPO_ROOT/start-masc.sh" --http --host 127.0.0.1 --port 8935 "${args[@]}"
