#!/usr/bin/env bash
# TLA+ model checking for MASC keeper state machine specs.
# Downloads TLC if needed, runs all specs with their existing .cfg files.
#
# Usage:
#   scripts/tla-check.sh           # Run all specs

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
    -coverage 1 \
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
    -coverage 1 \
    "$spec_dir/$tla_file"
  echo ""
}

# Run a buggy spec that MUST violate an invariant or property.
# TLC exit codes: 12 = safety violation, 13 = liveness violation.
# If TLC exits 0 (no violation), the spec is too weak and the test fails.
run_tlc_buggy() {
  local spec_dir="$1"
  local tla_file="$2"
  local cfg_file="${3:-${tla_file%.tla}-buggy.cfg}"
  local label="${4:-buggy}"

  if [ ! -f "$spec_dir/$cfg_file" ]; then
    echo "SKIP $tla_file $label (no $cfg_file file)"
    return 0
  fi

  echo "=== Checking $spec_dir/$tla_file ($label, expect violation) ==="
  local rc=0
  "$JAVA" -XX:+UseParallelGC -Xmx4g \
    -cp "$TLC_JAR" tlc2.TLC \
    -config "$spec_dir/$cfg_file" \
    -workers auto \
    -deadlock \
    -coverage 1 \
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

# ── Every spec directory ───────────────────────────────────────
# A spec runs with every cfg named after it, and only those:
#   <Spec>.cfg               guards that hold. Expects no violation.
#   <Spec>-<name>.cfg        another set of guards that hold. Expects none.
#   <Spec>-<name>-buggy.cfg  a planted way to be wrong. Expects a violation.
#   <Spec>-buggy.cfg         the same, for the spec's first such way.
# A cfg runs because it is in the directory. A list written by hand leaves
# out every cfg added after it was written (masc #53969). A cfg that names no
# spec in its directory stops the check, since nothing would run it.
run_spec_dir() {
  local dir="$1"
  local cfg_path cfg spec tla_path tla_name base label

  for cfg_path in "$dir"/*.cfg; do
    [ -e "$cfg_path" ] || continue
    cfg="$(basename "$cfg_path")"
    spec="${cfg%.cfg}"
    spec="${spec%%-*}"
    if [ ! -f "$dir/$spec.tla" ] || [ -L "$dir/$spec.tla" ]; then
      echo "FAIL: $cfg_path names no spec in $dir that this script runs."
      return 1
    fi
  done

  for tla_path in "$dir"/*.tla; do
    [ -e "$tla_path" ] || continue
    # A link's target directory runs that spec.
    [ -L "$tla_path" ] && continue
    tla_name="$(basename "$tla_path")"
    base="${tla_name%.tla}"
    run_tlc "$dir" "$tla_name"
    for cfg_path in "$dir/$base"-*.cfg; do
      [ -e "$cfg_path" ] || continue
      cfg="$(basename "$cfg_path")"
      label="${cfg%.cfg}"
      label="${label#"$base"-}"
      case "$cfg" in
        *-buggy.cfg) run_tlc_buggy "$dir" "$tla_name" "$cfg" "$label" ;;
        *) run_tlc_cfg "$dir" "$tla_name" "$cfg" "$label" ;;
      esac
    done
  done
}

for spec_dir in "$REPO_ROOT"/specs/*/; do
  run_spec_dir "${spec_dir%/}"
done

echo "All TLA+ checks passed."
