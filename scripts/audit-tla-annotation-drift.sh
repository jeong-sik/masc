#!/usr/bin/env bash
# audit-tla-annotation-drift.sh — detect OCaml [@tla.*] annotations
# whose lowercase symbol is not a member of the corresponding TLA+
# spec set.
#
# Background: ppx_tla generates `to_tla_symbol`, `all_symbols`, etc.
# from `[@@deriving tla]` types with per-constructor `[@tla.idle|active|
# terminal]` annotations.  The annotations are *forward-looking* — they
# claim "this variant is X per TLA+", but the PPX does NOT verify the
# spec actually declares the symbol.  Result: a constructor added to
# OCaml without updating the spec is silently allowed (KTC B-1 audit
# memo at `docs/tla-audit/ktc-b1-turn-phase-spec-gap-2026-05-12.md`
# documents Turn_routing/Turn_exhausted as exactly this case).
#
# This script closes the loop by static cross-check.  Exit non-zero on
# drift so CI catches future regressions.
#
# Usage: bash scripts/audit-tla-annotation-drift.sh
#        bash scripts/audit-tla-annotation-drift.sh --verbose
#
# RFC: R-B-1.c (iter 19 KTC B-1 audit memo).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_DIR="${REPO_ROOT}/specs/keeper-state-machine"
LIB_DIR="${REPO_ROOT}/lib"

VERBOSE=0
BASELINE_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=1; shift ;;
    --baseline) BASELINE_FILE="$2"; shift 2 ;;
    --baseline=*) BASELINE_FILE="${1#*=}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Load baseline known-drift entries (one per line, format: "type:symbol").
# Lines starting with # and blank lines are ignored.  Baseline entries
# are existing drifts awaiting resolution (e.g. spec extension RFC) —
# the validator skips them so CI catches only NEW regressions.
declare -a BASELINE=()
if [[ -n "${BASELINE_FILE}" && -f "${BASELINE_FILE}" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"  # strip trailing comments
    line="${line## }"
    line="${line%% }"
    [[ -z "${line}" ]] && continue
    BASELINE+=("${line}")
  done < "${BASELINE_FILE}"
  if [[ "${VERBOSE}" == "1" ]]; then
    echo "loaded baseline: ${#BASELINE[@]} known-drift entries from ${BASELINE_FILE}"
  fi
fi

in_baseline() {
  local key="$1"
  for entry in "${BASELINE[@]:-}"; do
    if [[ "${entry}" == "${key}" ]]; then return 0; fi
  done
  return 1
}

# Type → Set mapping.  OCaml type names (lowercase_with_underscores) to
# TLA+ set identifiers (CamelCase + "Set").  Extend this list as new
# `[@@deriving tla]` types appear.
declare -a TYPE_SET_PAIRS=(
  "turn_phase:TurnPhaseSet"
  "decision_stage:DecisionSet"
  "cascade_state:CascadeSet"
  # KSM `phase` variant uses a different spec representation (Phase
  # constant via DerivePhase, not a closed set literal).  R-B-1.c can
  # extend to KSM in a follow-up by adding spec-side `PhaseSet` first
  # and matching here.
)

# Aux: extract spec set members.  Greps the `XxxSet == { ... }` block,
# bounded to the same set definition (stops at the closing `}` or the
# next top-level identifier).  Greedy multi-line capture would pull
# members from adjacent sets.
extract_spec_members() {
  local set_name="$1"
  # Use awk to extract from `XxxSet ==` line until the closing `}`.
  awk -v set="${set_name}" '
    BEGIN { capturing = 0 }
    $0 ~ "^" set "[[:space:]]*==" { capturing = 1 }
    capturing == 1 {
      buf = buf $0 " "
      if (index($0, "}") > 0) { capturing = 0; print buf; buf = "" }
    }
  ' "${SPEC_DIR}"/*.tla 2>/dev/null \
    | rg -o '"[a-z_]+"' \
    | tr -d '"' \
    | sort -u
}

# Aux: extract OCaml constructor names tagged with `[@tla.*]` for a
# given type.  Returns lowercase symbols (cd.pcd_name.txt → lowercased).
extract_ocaml_members() {
  local type_name="$1"
  # Find the type definition, then read up to the closing `]` annotation
  # block.  ppx_tla uses `[@@deriving tla]` as the terminator.
  rg --multiline -U "type ${type_name}\b[^=]*=([\s\S]*?)\[@@deriving tla\]" "${LIB_DIR}" 2>/dev/null \
    | rg -o '\| [A-Z][A-Za-z_0-9]+' \
    | sed 's/^| //' \
    | tr '[:upper:]' '[:lower:]' \
    | sort -u
}

VIOLATIONS=0
KNOWN_DRIFTS=0
TOTAL_PAIRS=0
TOTAL_CHECKED=0

for pair in "${TYPE_SET_PAIRS[@]}"; do
  TOTAL_PAIRS=$((TOTAL_PAIRS + 1))
  ocaml_type="${pair%%:*}"
  spec_set="${pair##*:}"

  if [[ "${VERBOSE}" == "1" ]]; then
    echo "── ${ocaml_type} ↔ ${spec_set} ──"
  fi

  spec_members=$(extract_spec_members "${spec_set}" || true)
  ocaml_members=$(extract_ocaml_members "${ocaml_type}" || true)

  if [[ -z "${spec_members}" ]]; then
    echo "warn: spec set '${spec_set}' not found or empty in ${SPEC_DIR}"
    continue
  fi
  if [[ -z "${ocaml_members}" ]]; then
    echo "warn: ocaml type '${ocaml_type}' not found or empty in ${LIB_DIR}"
    continue
  fi

  # First underscore-separated word of the type name is the meaningful
  # constructor prefix: turn_phase → "turn", decision_stage → "decision",
  # cascade_state → "cascade", phase → "phase" (no strip).
  prefix_word="${ocaml_type%%_*}"

  while IFS= read -r ocaml_sym; do
    [[ -z "${ocaml_sym}" ]] && continue
    TOTAL_CHECKED=$((TOTAL_CHECKED + 1))
    sym_full="${ocaml_sym}"
    # Strip "<prefix_word>_" from front (e.g. "turn_idle" → "idle").
    sym_stripped="${ocaml_sym#${prefix_word}_}"

    if echo "${spec_members}" | grep -qx "${sym_full}" \
       || echo "${spec_members}" | grep -qx "${sym_stripped}"; then
      if [[ "${VERBOSE}" == "1" ]]; then
        echo "  ✓ ${sym_stripped} (from ${sym_full}) in ${spec_set}"
      fi
    elif in_baseline "${ocaml_type}:${ocaml_sym}"; then
      if [[ "${VERBOSE}" == "1" ]]; then
        echo "  ~ ${sym_full} (type=${ocaml_type}) — known drift, skipped (baseline)"
      fi
      KNOWN_DRIFTS=$((KNOWN_DRIFTS + 1))
    else
      echo "drift: ocaml constructor '${ocaml_sym}' (type=${ocaml_type}) has no matching member in TLA+ ${spec_set}"
      echo "       tried: '${sym_full}', '${sym_stripped}'"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done <<< "${ocaml_members}"
done

echo ""
echo "tla-annotation-drift summary: ${TOTAL_CHECKED} constructors checked across ${TOTAL_PAIRS} type/set pairs, ${VIOLATIONS} new drift(s), ${KNOWN_DRIFTS} baseline-known drift(s)"

if [[ "${VIOLATIONS}" -gt 0 ]]; then
  echo ""
  echo "RFC reference: R-B-1.c (iter 19 KTC B-1 audit)."
  echo "Fix: either (a) add missing members to TLA+ spec set, or (b) remove obsolete OCaml constructor, or (c) add an explicit [@tla.symbol \"explicit_name\"] override on the OCaml constructor if the spec uses a different name."
  exit 1
fi
exit 0
