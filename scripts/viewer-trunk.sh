#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VIEWER_DIR="$REPO_ROOT/viewer"
LOCK_DIR="$VIEWER_DIR/.trunk-lock"
TRUNK_ARGS=("$@")

# trunk 0.21 expects boolean values for --no-color.
# Some environments export NO_COLOR as 1/0, which breaks trunk argument parsing.
if [[ "${NO_COLOR:-}" == "1" ]]; then
  export NO_COLOR=true
elif [[ "${NO_COLOR:-}" == "0" ]]; then
  export NO_COLOR=false
fi

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid"
    return 0
  fi

  if [[ "${MASC_FORCE_UNLOCK:-}" == "1" ]]; then
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$LOCK_DIR/pid"
      return 0
    fi
  fi

  echo "viewer-trunk: another trunk command is already running for viewer." >&2
  echo "If this is stale, run: MASC_FORCE_UNLOCK=1 scripts/viewer-trunk.sh ${TRUNK_ARGS[*]}" >&2
  echo "Stop the existing command or wait for it to complete, then retry." >&2
  exit 1
}

release_lock() {
  rm -rf "$LOCK_DIR"
}

acquire_lock
trap release_lock EXIT INT TERM

# Mitigate intermittent trunk stage-dir creation races.
mkdir -p "$VIEWER_DIR/dist/.stage"
mkdir -p "$VIEWER_DIR/target/wasm-bindgen/release"

cd "$VIEWER_DIR"
trunk "$@"
