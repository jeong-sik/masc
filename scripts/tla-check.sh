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
KEEP_TLC_ARTIFACTS="${KEEP_TLC_ARTIFACTS:-0}"

cleanup_tlc_artifacts() {
  if [ "$KEEP_TLC_ARTIFACTS" = "1" ]; then
    echo "KEEP_TLC_ARTIFACTS=1 -> preserving TLC artefacts"
    return 0
  fi

  "$REPO_ROOT/scripts/cleanup-tlc-artifacts.sh" || true
}

trap 'rc=$?; trap - EXIT; cleanup_tlc_artifacts; exit "$rc"' EXIT

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

run_tlc_cfg() {
  local spec_dir="$1"
  local tla_file="$2"
  local cfg_file="$3"
  local label="${4:-$cfg_file}"

  if [ ! -f "$spec_dir/$cfg_file" ]; then
    echo "SKIP $tla_file $label (no $cfg_file file)"
    return 0
  fi

  echo "=== Checking $spec_dir/$tla_file ($label) ==="
  "$JAVA" -XX:+UseParallelGC -Xmx4g \
    -cp "$TLC_JAR" tlc2.TLC \
    -config "$spec_dir/$cfg_file" \
    -workers auto \
    -deadlock \
    "$spec_dir/$tla_file"
  echo ""
}

# Run a buggy spec that MUST violate an invariant or property.
# TLC exit codes: 12 = safety violation, 13 = liveness violation.
# If TLC exits 0 (no violation), the spec is too weak and the test fails.
run_tlc_buggy() {
  local spec_dir="$1"
  local tla_file="$2"
  local cfg_file="${tla_file%.tla}-buggy.cfg"

  if [ ! -f "$spec_dir/$cfg_file" ]; then
    echo "SKIP $tla_file buggy (no -buggy.cfg file)"
    return 0
  fi

  echo "=== Checking $spec_dir/$tla_file (buggy, expect violation) ==="
  local rc=0
  "$JAVA" -XX:+UseParallelGC -Xmx4g \
    -cp "$TLC_JAR" tlc2.TLC \
    -config "$spec_dir/$cfg_file" \
    -workers auto \
    -deadlock \
    "$spec_dir/$tla_file" || rc=$?

  if [ "$rc" -eq 12 ] || [ "$rc" -eq 13 ]; then
    echo "OK: buggy model correctly violated (exit $rc)."
    echo ""
    return 0
  elif [ "$rc" -eq 0 ]; then
    echo "FAIL: buggy model passed without violation. Invariant/property too weak."
    echo ""
    return 1
  else
    echo "FAIL: unexpected TLC exit code $rc."
    echo ""
    return 1
  fi
}

ensure_trace_data() {
  local trace_data="$REPO_ROOT/specs/keeper-state-machine/TraceData.tla"
  local trace_source="${MASC_TLA_TRACE_JSONL:-$REPO_ROOT/specs/keeper-state-machine/synthetic.tla-trace.jsonl}"

  if [ -f "$trace_data" ]; then
    return 0
  fi

  if [ ! -f "$trace_source" ]; then
    echo "SKIP KeeperTraceSpec.tla (no trace source: $trace_source)"
    return 1
  fi

  echo "Generating TraceData.tla from $(basename "$trace_source")..."
  dune exec --root "$REPO_ROOT" ./bin/trace_to_tla.exe -- "$trace_source" "$trace_data"
}

# Run all keeper state machine specs
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperStateMachine.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperTurnCycle.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperCascadeLifecycle.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-state-machine" "KeeperCascadeLifecycle.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperOASAdvanced.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperContextLifecycle.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-state-machine" "KeeperContextLifecycle.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperGenerationLineage.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-state-machine" "KeeperGenerationLineage.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperDecisionPipeline.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-state-machine" "KeeperDecisionPipeline.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperCompactionLifecycle.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-state-machine" "KeeperCompactionLifecycle.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperCompositeLifecycle.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-state-machine" "KeeperCompositeLifecycle.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperCircuitBreaker.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperCoreTriad.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-state-machine" "KeeperCoreTriad.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-state-machine" "KeeperCircuitBreaker.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "OperatorPauseBroadcast.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-state-machine" "OperatorPauseBroadcast.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperHeartbeat.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-state-machine" "KeeperHeartbeat.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperTaskAcquisition.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-state-machine" "KeeperTaskAcquisition.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperApprovalQueue.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-state-machine" "KeeperApprovalQueue.tla"
run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperLaunchPending.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-state-machine" "KeeperLaunchPending.tla"
run_tlc "$REPO_ROOT/specs/keeper-turn-fsm" "KeeperTurnFSM.tla"
run_tlc_buggy "$REPO_ROOT/specs/keeper-turn-fsm" "KeeperTurnFSM.tla"
run_tlc "$REPO_ROOT/specs/admission-queue" "AdmissionQueue.tla"
run_tlc_buggy "$REPO_ROOT/specs/admission-queue" "AdmissionQueue.tla"
run_tlc "$REPO_ROOT/specs/boundary" "KeeperContinueGate.tla"
run_tlc_buggy "$REPO_ROOT/specs/boundary" "KeeperContinueGate.tla"
run_tlc "$REPO_ROOT/specs/boundary" "ToolCallContract.tla"
run_tlc_buggy "$REPO_ROOT/specs/boundary" "ToolCallContract.tla"
run_tlc "$REPO_ROOT/specs/boundary" "KeeperTurnTerminal.tla"
run_tlc_buggy "$REPO_ROOT/specs/boundary" "KeeperTurnTerminal.tla"
run_tlc "$REPO_ROOT/specs/boundary" "KeeperEmptyToolUniverse.tla"
run_tlc_buggy "$REPO_ROOT/specs/boundary" "KeeperEmptyToolUniverse.tla"
run_tlc "$REPO_ROOT/specs/boundary" "KeeperContractViolated.tla"
run_tlc_buggy "$REPO_ROOT/specs/boundary" "KeeperContractViolated.tla"
run_tlc "$REPO_ROOT/specs/boundary" "KeeperStaleKilled.tla"
run_tlc_buggy "$REPO_ROOT/specs/boundary" "KeeperStaleKilled.tla"
run_tlc "$REPO_ROOT/specs/auth" "AuthIdentityFSM.tla"
run_tlc_buggy "$REPO_ROOT/specs/auth" "AuthIdentityFSM.tla"
run_tlc "$REPO_ROOT/specs/state-product" "StateProduct.tla"
run_tlc_buggy "$REPO_ROOT/specs/state-product" "StateProduct.tla"
run_tlc "$REPO_ROOT/specs/state-product" "CoordinationProduct.tla"
run_tlc_buggy "$REPO_ROOT/specs/state-product" "CoordinationProduct.tla"
run_tlc "$REPO_ROOT/specs/task-lifecycle" "TaskLifecycle.tla"
run_tlc_buggy "$REPO_ROOT/specs/task-lifecycle" "TaskLifecycle.tla"

# Optional: run TraceSpec if --trace flag provided
if [ "${1:-}" = "--trace" ]; then
  TRACE_SPEC="$REPO_ROOT/specs/keeper-state-machine/KeeperTraceSpec.tla"
  TRACE_DATA="$REPO_ROOT/specs/keeper-state-machine/TraceData.tla"
  if [ -f "$TRACE_SPEC" ] && ensure_trace_data && [ -f "$TRACE_DATA" ]; then
    run_tlc "$REPO_ROOT/specs/keeper-state-machine" "KeeperTraceSpec.tla"
  else
    echo "SKIP KeeperTraceSpec.tla (TraceData.tla unavailable)"
  fi
fi

run_tlc "$REPO_ROOT/specs/masc-ecosystem" "MASCEcosystem.tla"

# ── bug-models ─────────────────────────────────────────────────
# Every .tla in specs/bug-models/ that has a matching .cfg and/or
# -buggy.cfg is run automatically. Symlinks are skipped (they point
# into specs/keeper-state-machine/ and are already run above).
# Specs with neither cfg are reported as SKIP by the helpers, which
# is the same behavior as the keeper-state-machine section.
#
# Discovered 2026-04-11: this directory had been untracked by the
# CI harness since inception. Local sweep (scripts/tla-check.sh +
# direct tlc) confirms all 14 bug-models with cfgs behave correctly
# (14 clean=PASS, 14 buggy=VIOLATED). Wiring them up strengthens
# CI without adding any new spec. Future bug-model additions are
# picked up automatically by the glob.
BUG_MODELS_DIR="$REPO_ROOT/specs/bug-models"
if [ -d "$BUG_MODELS_DIR" ]; then
  run_tlc_cfg "$BUG_MODELS_DIR" "CascadeLiveness.tla" \
    "CascadeLiveness-liveness.cfg" "liveness"

  for tla_path in "$BUG_MODELS_DIR"/*.tla; do
    [ -e "$tla_path" ] || continue              # no matches
    [ -L "$tla_path" ] && continue              # symlink → already run
    tla_name="$(basename "$tla_path")"
    base="${tla_name%.tla}"
    if [ -f "$BUG_MODELS_DIR/${base}.cfg" ]; then
      run_tlc "$BUG_MODELS_DIR" "$tla_name"
    fi
    if [ -f "$BUG_MODELS_DIR/${base}-buggy.cfg" ]; then
      run_tlc_buggy "$BUG_MODELS_DIR" "$tla_name"
    fi
  done
fi

echo "All TLA+ checks passed."
