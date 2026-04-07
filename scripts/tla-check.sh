#!/usr/bin/env bash
# TLA+ model checking for MASC keeper state machine specs.
# Downloads TLC if needed, runs all specs with their existing .cfg files.
#
# Usage:
#   scripts/tla-check.sh           # Run all specs
#   scripts/tla-check.sh --trace   # Also run TraceSpec (requires prior trace generation)

set -euo pipefail

TLC_VERSION="1.8.0"
TLC_DIR="${TLC_DIR:-$HOME/.local/lib/tla}"
TLC_JAR="${TLC_DIR}/tla2tools-${TLC_VERSION}.jar"
TLC_URL="https://github.com/tlaplus/tlaplus/releases/download/v${TLC_VERSION}/tla2tools.jar"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Download TLC if not present
if [ ! -f "$TLC_JAR" ]; then
  mkdir -p "$TLC_DIR"
  echo "Downloading TLC ${TLC_VERSION}..."
  curl -fsSL "$TLC_URL" -o "$TLC_JAR"
  echo "TLC downloaded to $TLC_JAR"
fi

JAVA="${JAVA_HOME:+$JAVA_HOME/bin/java}"
JAVA="${JAVA:-java}"

if ! command -v "$JAVA" &>/dev/null; then
  echo "Error: Java not found. TLC requires Java 11+."
  exit 1
fi

run_tlc() {
  local spec_dir="$1"
  local tla_file="$2"
  local cfg_file="${tla_file%.tla}.cfg"

  if [ ! -f "$spec_dir/$cfg_file" ]; then
    echo "SKIP $tla_file (no .cfg file)"
    return 0
  fi

  echo "=== Checking $spec_dir/$tla_file ==="
  "$JAVA" -XX:+UseParallelGC -Xmx4g \
    -cp "$TLC_JAR" tlc2.TLC \
    -config "$spec_dir/$cfg_file" \
    -workers auto \
    -deadlock \
    "$spec_dir/$tla_file"
  echo ""
}

# Run all keeper state machine specs
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperStateMachine.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperOASBridge.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperOASAdvanced.tla"
run_tlc "$REPO_ROOT/specs/masc-ecosystem" "MASCEcosystem.tla"

# Optional: run TraceSpec if --trace flag provided
if [ "${1:-}" = "--trace" ]; then
  TRACE_SPEC="$REPO_ROOT/specs/keeper-state-machine/KeeperTraceSpec.tla"
  if [ -f "$TRACE_SPEC" ]; then
    run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperTraceSpec.tla"
  else
    echo "SKIP KeeperTraceSpec.tla (not yet created)"
  fi
fi

echo "All TLA+ checks passed."
