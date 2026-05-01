#!/usr/bin/env bash
# check-variants.sh — cross-language variant sync checker.
# Meta-issue: #9518 (VAR bug class prevention)
#
# Compares OCaml variant sets against TypeScript union types and TLA+ domain
# literals to detect drift early. Run as: make check-variants
#
# RULES
#   FAIL  — variant present in one representation but absent in another.
#   WARN  — heuristic mismatch (TLA+ literal casing vs OCaml constructor).
#   PASS  — all checked pairs are in sync.
#
# Extending this script:
#   1. Add a new check_pair call at the bottom.
#   2. Use extract_ocaml_all_list / extract_ts_union_type / extract_tla_domain
#      helpers to pull variant sets from each language.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: check-variants.sh requires ripgrep (rg). Install with: apt-get install ripgrep" >&2
  exit 2
fi

exit_code=0

# ── Extraction helpers ─────────────────────────────────────────────────────────

# Extract values from an OCaml `let all_X = [ ... ]` list literal.
# Captures the PascalCase/underscore constructor names.
# Usage: extract_ocaml_all_list <file> <list_name>
extract_ocaml_all_list() {
  local file="$1"
  local list_name="$2"
  # Capture everything between the opening [ and the closing ] of "let <name> ="
  # then pull out individual constructor names (word chars starting with upper
  # or lower, separated by ;/whitespace).
  awk "/^let ${list_name}[[:space:]]*=/{found=1} found{print} found && /\]/{exit}" "$file" \
    | rg '\b([A-Z][a-zA-Z_0-9]*)\b' -o -r '$1' \
    | sort -u
}

# Extract constructor names from an OCaml type definition.
# Usage: extract_ocaml_type <file> <type_name>
extract_ocaml_type() {
  local file="$1"
  local type_name="$2"
  awk "/^type ${type_name}[[:space:]]*=/{found=1; next} found && /^\s*\|/{print} found && /^[a-z]/{exit}" "$file" \
    | rg '^\s*\|\s+([A-Z][a-zA-Z_0-9]*)' -o -r '$1' \
    | sort -u
}

# Extract a TypeScript union type (string literals) from a .ts file.
# Usage: extract_ts_union_type <file> <type_name>
extract_ts_union_type() {
  local file="$1"
  local type_name="$2"
  # Match lines that are part of the union, extracting quoted strings.
  awk "/^export type ${type_name}[[:space:]]*=/{found=1} found{print} found && /^[[:space:]]*$/{exit}" "$file" \
    | rg "'([A-Za-z][a-zA-Z_0-9]*)'" -o -r '$1' \
    | sort -u
}

# Extract PascalCase string literals from TLA+ specs as domain candidates.
# Usage: extract_tla_domain <dir_or_file>
extract_tla_domain() {
  local path="$1"
  rg '"([A-Z][a-zA-Z_0-9]*)"' "$path" -o -r '$1' 2>/dev/null | sort -u || true
}

# ── Comparison helper ──────────────────────────────────────────────────────────

# Compare two sorted variant sets and report drift.
# Usage: check_pair <label_a> <set_a> <label_b> <set_b>
check_pair() {
  local label_a="$1"
  local set_a="$2"
  local label_b="$3"
  local set_b="$4"

  local only_a only_b
  only_a=$(comm -23 <(echo "$set_a") <(echo "$set_b") | grep -v '^$' || true)
  only_b=$(comm -13 <(echo "$set_a") <(echo "$set_b") | grep -v '^$' || true)

  if [ -n "$only_a" ] || [ -n "$only_b" ]; then
    echo "FAIL: variant drift between ${label_a} and ${label_b}"
    if [ -n "$only_a" ]; then
      echo "  Only in ${label_a}:"
      echo "$only_a" | sed 's/^/    /'
    fi
    if [ -n "$only_b" ]; then
      echo "  Only in ${label_b}:"
      echo "$only_b" | sed 's/^/    /'
    fi
    exit_code=1
  else
    echo "OK: ${label_a} <-> ${label_b} in sync ($(echo "$set_a" | grep -c . || true) variants)"
  fi
}

# ── Check 1: Keeper_state_machine.phase (OCaml) vs KeeperPhase (TypeScript) ──

echo "=== Check 1: KeeperStateMachine.phase (OCaml) vs KeeperPhase (TypeScript) ==="

KSM_ML="lib/keeper/keeper_state_machine.ml"
KP_TS="dashboard/src/types/core.ts"

if [ -f "$KSM_ML" ] && [ -f "$KP_TS" ]; then
  ocaml_phases=$(extract_ocaml_all_list "$KSM_ML" "all_phases")
  ts_phases=$(extract_ts_union_type "$KP_TS" "KeeperPhase")

  if [ -z "$ocaml_phases" ]; then
    echo "WARN: could not extract OCaml phases from ${KSM_ML} (all_phases not found)"
  elif [ -z "$ts_phases" ]; then
    echo "WARN: could not extract TypeScript KeeperPhase from ${KP_TS}"
  else
    check_pair "OCaml(all_phases)" "$ocaml_phases" "TypeScript(KeeperPhase)" "$ts_phases"
  fi
else
  [ -f "$KSM_ML" ] || echo "WARN: ${KSM_ML} not found — skipping phase check"
  [ -f "$KP_TS"  ] || echo "WARN: ${KP_TS} not found — skipping phase check"
fi

# ── Check 2: turn_phase (OCaml) vs KTC labels in TLA+ flowchart ──────────────

echo ""
echo "=== Check 2: turn_phase (OCaml) vs KeeperCompositeLifecycle.tla domain ==="

KR_ML="lib/keeper/keeper_registry.ml"
KCL_TLA="specs/keeper-state-machine/KeeperCascadeLifecycle.tla"

if [ -f "$KR_ML" ]; then
  # turn_phase constructors (strip "Turn_" prefix, lowercase for TLA+ comparison)
  ocaml_turn=$(extract_ocaml_type "$KR_ML" "turn_phase" \
    | sed 's/Turn_//' | tr '[:upper:]' '[:lower:]' | sort -u)

  if [ -n "$ocaml_turn" ]; then
    if [ -f "$KCL_TLA" ]; then
      # TLA+ turn_phase domain (quoted lowercase strings like "idle", "executing")
      tla_turn=$(rg '"(idle|prompting|executing|compacting|finalizing)"' "$KCL_TLA" \
        -o -r '$1' 2>/dev/null | sort -u || true)
      if [ -n "$tla_turn" ]; then
        check_pair "OCaml(turn_phase)" "$ocaml_turn" "TLA+(turn_phase domain)" "$tla_turn"
      else
        echo "INFO: TLA+ turn_phase domain literals not found in ${KCL_TLA} — spec may use variable names only"
      fi
    else
      echo "INFO: ${KCL_TLA} not found — TLA+ turn_phase check skipped"
    fi
  else
    echo "WARN: could not extract OCaml turn_phase from ${KR_ML}"
  fi
else
  echo "WARN: ${KR_ML} not found — turn_phase check skipped"
fi

# ── Check 3: cascade_state (OCaml) vs KCL labels in TLA+ ────────────────────

echo ""
echo "=== Check 3: cascade_state (OCaml) vs KeeperCascadeLifecycle.tla domain ==="

if [ -f "$KR_ML" ]; then
  ocaml_cascade=$(extract_ocaml_type "$KR_ML" "cascade_state" \
    | sed 's/Cascade_//' | tr '[:upper:]' '[:lower:]' | sort -u)

  if [ -n "$ocaml_cascade" ]; then
    if [ -f "$KCL_TLA" ]; then
      tla_cascade=$(rg '"(idle|selecting|trying|done|exhausted)"' "$KCL_TLA" \
        -o -r '$1' 2>/dev/null | sort -u || true)
      if [ -n "$tla_cascade" ]; then
        check_pair "OCaml(cascade_state)" "$ocaml_cascade" "TLA+(cascade_state domain)" "$tla_cascade"
      else
        echo "INFO: TLA+ cascade_state domain literals not found in ${KCL_TLA}"
      fi
    else
      echo "INFO: ${KCL_TLA} not found — TLA+ cascade_state check skipped"
    fi
  fi
fi

# ── Check 4: PHASE_STYLES coverage (TypeScript) vs KeeperPhase ───────────────

echo ""
echo "=== Check 4: PHASE_STYLES record coverage vs KeeperPhase type ==="

KPI_TS="dashboard/src/components/keeper-phase-indicator.ts"

if [ -f "$KPI_TS" ] && [ -f "$KP_TS" ]; then
  ts_phases=$(extract_ts_union_type "$KP_TS" "KeeperPhase")
  # Extract keys from PHASE_STYLES: look for "Key:     {" pattern
  phase_style_keys=$(rg '^\s+([A-Z][a-zA-Z_0-9]*):\s+\{' "$KPI_TS" -o -r '$1' | sort -u || true)

  if [ -n "$ts_phases" ] && [ -n "$phase_style_keys" ]; then
    check_pair "TypeScript(KeeperPhase)" "$ts_phases" "TypeScript(PHASE_STYLES keys)" "$phase_style_keys"
  else
    echo "WARN: could not extract PHASE_STYLES keys or KeeperPhase from dashboard — check skipped"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
if [ "$exit_code" -eq 0 ]; then
  echo "=== check-variants: PASS ==="
else
  echo "=== check-variants: FAIL — fix drift before merging ==="
fi

exit "$exit_code"
