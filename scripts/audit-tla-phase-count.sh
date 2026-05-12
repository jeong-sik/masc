#!/usr/bin/env bash
# audit-tla-phase-count.sh — detect TLA+ spec comments that mention
# an "N phases" / "N-phase" count which disagrees with the OCaml
# `type phase` constructor count in keeper_state_machine.ml.
#
# Background: iter 4 (#14707) added the Zombie constructor, raising
# the OCaml phase type from 12 to 13. Seven sibling specs (iter 49
# audit at docs/tla-audit/rh1b-sweep-zombie-12-phases-stale-2026-05-12.md)
# still cited the stale "12 phases" count six months later because no
# structural check existed.  Iter 50 batch-fixed those (#14863) and
# iter 51 added per-spec Zombie mapping notes (#14865); this script
# is pipeline step 3/3 — the regression guard that prevents the same
# class of drift from recurring on the next phase-count change.
#
# Rule:
#   - Count `^  | <CamelCase>` lines between `type phase =` and the
#     next blank line in lib/keeper/keeper_state_machine.ml.  That's
#     the source of truth (N).
#   - In specs/keeper-state-machine/*.tla, find every match of
#     `\b(\d{1,2})[ -]phase(s)?\b` inside `\* ` comment lines.
#   - If the matched number != N, the line MUST contain at least one
#     contextual qualifier (`non-`, `fragment`, `projection`, `subset`,
#     `relevant`, `out of scope`, `models`, `collapse`, `symbol`,
#     `triad`, `mapping`, `excluding`).  Otherwise it is flagged as
#     stale.
#   - The full count (N=13 today) is always allowed without qualifier.
#
# Usage: bash scripts/audit-tla-phase-count.sh [--verbose]
#
# RFC chain: R-B-1.c (annotation drift validator) → R-H-1.c (this
# script), 6th drift class structural closure.
set -euo pipefail

for tool in rg awk grep sed; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "error: required tool '${tool}' not found in PATH" >&2
    exit 2
  }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_DIR="${REPO_ROOT}/specs/keeper-state-machine"
SSOT_FILE="${REPO_ROOT}/lib/keeper/keeper_state_machine.ml"

VERBOSE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Extract phase constructor count.  awk reads the block between
# `type phase =` and the first blank line, counts `  | Ctor` lines.
SSOT_COUNT="$(awk '
  /^type phase =/ { in_block = 1; next }
  in_block && /^[[:space:]]*$/ { exit }
  in_block && /^[[:space:]]*\|[[:space:]]*[A-Z]/ { count++ }
  END { print count + 0 }
' "${SSOT_FILE}")"

if [[ -z "${SSOT_COUNT}" || "${SSOT_COUNT}" -lt 2 ]]; then
  echo "error: could not extract phase constructor count from ${SSOT_FILE}" >&2
  echo "       (got '${SSOT_COUNT}')" >&2
  exit 2
fi

[[ "${VERBOSE}" -eq 1 ]] && echo "SSOT phase count: ${SSOT_COUNT}" >&2

# Qualifier whitelist — when these tokens appear on the same line as
# a non-matching count, the mention is treated as an intentional
# subset/projection description rather than a stale full-count claim.
QUALIFIERS='(non-|fragment|projection|subset|relevant|out of scope|models|collapse|symbol|triad|mapping|excluding|abstract|sibling|companion)'

drift_count=0
tmpfile="$(mktemp)"
trap 'rm -f "${tmpfile}"' EXIT

# rg without -o emits the full line; we parse number out per match.
# We filter to comment lines (`\* `) only — body actions referencing
# N are not the drift class this guard targets.
rg -n --no-heading --glob '*.tla' \
  -e '\\\*[^\n]*\b([0-9]{1,2})[ -]phase(s)?\b' \
  "${SPEC_DIR}" 2>/dev/null > "${tmpfile}" || true

while IFS= read -r entry; do
  [[ -z "${entry}" ]] && continue
  # entry format: <file>:<lineno>:<matched substring starting with \*>
  file="${entry%%:*}"
  rest="${entry#*:}"
  lineno="${rest%%:*}"
  content="${rest#*:}"

  # Extract first 1-2 digit number adjacent to "phase"/"phases".
  # `\b` is not portable in BSD sed (macOS); use grep -oE which works
  # on both GNU and BSD.
  matched_n="$(printf '%s' "${content}" \
    | grep -oE '[0-9]{1,2}[ -]phase(s)?' \
    | head -1 \
    | grep -oE '^[0-9]+')"
  [[ -z "${matched_n}" ]] && continue

  if [[ "${matched_n}" == "${SSOT_COUNT}" ]]; then
    continue
  fi

  # Domain disambiguation: "phase" is overloaded in this codebase —
  # cascade FSM has 6 phases, turn cycle has 3 axes, decision pipeline
  # has 5, etc.  Any subset/projection count is ≤7 and is never a
  # keeper-count drift signal.  Only flag values in the range
  # [SSOT_COUNT-3 .. SSOT_COUNT+5] so we catch realistic stale keeper
  # counts (e.g. 12 vs 13) but not sibling-FSM enum sizes.
  range_lo=$((SSOT_COUNT - 3))
  range_hi=$((SSOT_COUNT + 5))
  if (( matched_n < range_lo || matched_n > range_hi )); then
    [[ "${VERBOSE}" -eq 1 ]] && \
      echo "ok (out-of-keeper-range): ${file}:${lineno} — ${matched_n} not in [${range_lo}..${range_hi}]" >&2
    continue
  fi

  if printf '%s' "${content}" | grep -qiE "${QUALIFIERS}"; then
    [[ "${VERBOSE}" -eq 1 ]] && \
      echo "ok (qualified): ${file}:${lineno} — ${matched_n} != ${SSOT_COUNT}" >&2
    continue
  fi

  printf 'drift: %s:%s — mentions "%s phases" but SSOT has %s constructors (no qualifier on line)\n' \
    "${file#${REPO_ROOT}/}" "${lineno}" "${matched_n}" "${SSOT_COUNT}"
  drift_count=$((drift_count + 1))
done < "${tmpfile}"

if [[ "${drift_count}" -gt 0 ]]; then
  echo "" >&2
  echo "${drift_count} phase-count drift(s) detected." >&2
  echo "Fix: update the spec comment to match keeper_state_machine.ml (${SSOT_COUNT} constructors)," >&2
  echo "or add a qualifier (non-Zombie, projection, fragment, ...) if the mention is intentionally" >&2
  echo "a subset count." >&2
  exit 1
fi

echo "phase-count audit clean: SSOT=${SSOT_COUNT}, no unqualified mismatches." >&2
