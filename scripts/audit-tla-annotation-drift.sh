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

# Hard dependency check.  Without this, [set -euo pipefail] plus the
# [|| true] guards on the extraction calls would silently turn a missing
# binary into a "warn: ... empty" line and an exit-0 — drift would slip
# through CI.  Fail-fast so unhealthy environments are visible.
for tool in rg awk sed sort grep tr; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "error: required tool '${tool}' not found in PATH" >&2
    exit 2
  }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_DIR="${REPO_ROOT}/specs/keeper-state-machine"
LIB_DIR="${REPO_ROOT}/lib"

VERBOSE=0
BASELINE_FILE=""
CHECK_CROSS_SPEC=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=1; shift ;;
    --baseline) BASELINE_FILE="$2"; shift 2 ;;
    --baseline=*) BASELINE_FILE="${1#*=}"; shift ;;
    --check-cross-spec) CHECK_CROSS_SPEC=1; shift ;;
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
# TLA+ set identifiers.  Extend this list as new `[@@deriving tla]`
# types appear.
#
declare -a TYPE_SET_PAIRS=(
  "turn_phase:TurnPhaseSet"
  "decision_stage:DecisionSet"
  # KSM `phase` variant uses a different spec representation (Phase
  # constant via DerivePhase, not a closed set literal).  R-B-1.c can
  # extend to KSM in a follow-up by adding spec-side `PhaseSet` first
  # and matching here.
)

# Aux: extract spec set members.  Greps the `XxxSet == { ... }` block,
# bounded to the same set definition (stops at the closing `}` or the
# next top-level identifier).  Greedy multi-line capture would pull
# members from adjacent sets.
#
# Scope note: the awk pass aggregates across every `${SPEC_DIR}/*.tla`
# and the trailing `sort -u` unions the results.  This is intentional —
# the validator's job is to verify that *somewhere* in the TLA+ corpus
# the OCaml symbol is declared.  Per-spec consistency (some specs
# omitting a member that another defines, e.g. for scope-restricted
# proofs) is a *separate* audit; tracking it here would over-fire on
# legitimately-narrow specs.  R-B-1.d follow-up.
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

# Aux: extract a spec set's members PER SPEC FILE, so the caller can
# detect cross-spec drift (e.g. KTC.tla defines TurnPhaseSet with 7
# members but KCL.tla defines it with 5 — R-E-1.b finding from iter 38
# audit `docs/tla-audit/kcl-e1-cross-spec-projection-drift-2026-05-12.md`).
#
# Output: one line per spec file that contains the set:
#   <spec_basename>: <space-sorted member1> <member2> ...
#
# Empty output means the set is not defined in any spec.
extract_set_members_per_spec() {
  local set_name="$1"
  local spec
  for spec in "${SPEC_DIR}"/*.tla; do
    local members
    members=$(awk -v set="${set_name}" '
      BEGIN { capturing = 0 }
      $0 ~ "^" set "[[:space:]]*==" { capturing = 1 }
      capturing == 1 {
        buf = buf $0 " "
        if (index($0, "}") > 0) { capturing = 0; print buf; buf = "" }
      }
    ' "${spec}" 2>/dev/null \
      | rg -o '"[a-z_]+"' \
      | tr -d '"' \
      | sort -u \
      | tr '\n' ' ')
    members="${members% }"   # strip trailing space
    if [[ -n "${members}" ]]; then
      echo "$(basename "${spec}" .tla): ${members}"
    fi
  done
}

# Aux: extract OCaml constructor names tagged with `[@tla.*]` for a
# given type.  Returns lowercase symbols (cd.pcd_name.txt → lowercased).
#
# Regex note: ripgrep's default Rust regex engine *does* support lazy
# quantifiers (`*?`, `+?`), so `[\s\S]*?` is portable here — verified by
# empirical run against the repo (16 constructors across 3 type/set
# pairs).  We do not need `-P`/PCRE2 unless `\s\S` semantics ever diverge
# from "any whitespace including newline" / "any non-whitespace".
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
  spec_set="${pair#*:}"

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
  # constructor prefix: turn_phase → "turn", decision_stage → "decision".
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

# ── Cross-spec set uniformity check (R-E-1.b, iter 40) ─────────────
#
# When a set name appears in MULTIPLE *.tla files, check that all
# occurrences define the same member set.  Detects drift where one
# spec is widened (e.g. iter 28 KTC TurnPhaseSet 5→7) but observer
# specs (KCL) are not synced — the bug class identified in iter 38
# audit (`docs/tla-audit/kcl-e1-cross-spec-projection-drift-2026-05-12.md`).
#
# Rule of thumb: spec set names that appear verbatim in multiple
# specs are EXPECTED to be uniform.  Deliberate projection collapses
# (e.g. KCL's KcafPhaseSet collapses KCAF's PhaseSet 6→3) use a
# DIFFERENT set name on purpose, so they don't appear here.
#
# Listed sets are the cross-spec-shared identifiers most likely to
# drift across spec extensions.  Extend as new shared sets emerge.
# Each entry should appear in 2+ *.tla files for the check to be
# meaningful.  Entries that appear in only one spec are silently
# skipped — see the empty-output guard inside the loop.
declare -a CROSS_SPEC_UNIFORM_SETS=(
  # KTC + KCL: turn-phase projection (synced in iter 39 R-E-1.a).
  "TurnPhaseSet"
  # KTC + KCL: decision projection.
  "DecisionSet"
  # KTC + KCL: runtime-state projection.
  "RuntimeSet"
)

CROSS_SPEC_DRIFTS=0
CROSS_SPEC_CHECKED=0
if [[ "${CHECK_CROSS_SPEC}" == "1" ]]; then
for shared_set in "${CROSS_SPEC_UNIFORM_SETS[@]}"; do
  [[ -z "${shared_set}" ]] && continue
  CROSS_SPEC_CHECKED=$((CROSS_SPEC_CHECKED + 1))
  per_spec_output=$(extract_set_members_per_spec "${shared_set}" || true)
  if [[ -z "${per_spec_output}" ]]; then
    if [[ "${VERBOSE}" == "1" ]]; then
      echo "── ${shared_set} cross-spec ──  (not defined in any spec, skipping)"
    fi
    continue
  fi
  unique_member_signatures=$(echo "${per_spec_output}" | awk -F': ' '{print $2}' | sort -u | wc -l | tr -d ' ')
  occurrences=$(echo "${per_spec_output}" | wc -l | tr -d ' ')
  if [[ "${VERBOSE}" == "1" ]]; then
    echo "── ${shared_set} cross-spec (${occurrences} spec(s), ${unique_member_signatures} unique signature(s)) ──"
    echo "${per_spec_output}" | sed 's/^/  /'
  fi
  if [[ "${unique_member_signatures}" -gt 1 ]]; then
    echo "cross-spec-drift: set '${shared_set}' has divergent definitions across spec files"
    echo "${per_spec_output}" | sed 's/^/  /'
    CROSS_SPEC_DRIFTS=$((CROSS_SPEC_DRIFTS + 1))
  fi
done
fi

echo ""
if [[ "${CHECK_CROSS_SPEC}" == "1" ]]; then
  echo "tla-annotation-drift summary: ${TOTAL_CHECKED} constructors checked across ${TOTAL_PAIRS} type/set pairs, ${VIOLATIONS} new drift(s), ${KNOWN_DRIFTS} baseline-known drift(s); ${CROSS_SPEC_CHECKED} cross-spec set(s) checked, ${CROSS_SPEC_DRIFTS} cross-spec drift(s)"
else
  echo "tla-annotation-drift summary: ${TOTAL_CHECKED} constructors checked across ${TOTAL_PAIRS} type/set pairs, ${VIOLATIONS} new drift(s), ${KNOWN_DRIFTS} baseline-known drift(s) (cross-spec scan available via --check-cross-spec, opt-in)"
fi

if [[ "${VIOLATIONS}" -gt 0 || "${CROSS_SPEC_DRIFTS}" -gt 0 ]]; then
  echo ""
  echo "RFC reference: R-B-1.c (iter 19 KTC B-1 audit), R-E-1.b (iter 38 KCL E-1 audit, cross-spec pass)."
  echo "Fix (annotation drift): either (a) add missing members to TLA+ spec set, or (b) remove obsolete OCaml constructor."
  echo "Fix (cross-spec drift): sync all spec files defining the same set name to the same members.  If the projection is DELIBERATE (observer pattern), rename to a distinct identifier (e.g. KcafPhaseSet vs PhaseSet) and document in the spec header."
  echo "Note: this validator extracts constructor names only — it does not yet parse [@tla.symbol] PPX overrides, so (c) alias-based reconciliation is not available until the extractor learns that attribute (tracked under R-B-1.d follow-up)."
  exit 1
fi
exit 0
