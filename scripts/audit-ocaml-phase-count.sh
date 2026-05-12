#!/usr/bin/env bash
# audit-ocaml-phase-count.sh — detect OCaml docstring/comment mentions
# of "N-state" / "N-phase" / "N phases" in lib/keeper/*.{ml,mli} that
# disagree with the `type phase` constructor count in
# keeper_state_machine.ml.
#
# Background: iter 49-53 closed the 6th drift class on the TLA+ spec
# side via `scripts/audit-tla-phase-count.sh` (R-H-1.c, #14874).  Iter
# 54 (R-H-1.e, #14886) discovered the same class lurking in OCaml
# docstrings: four sites still cited "12-state" even though the
# canonical type declaration had 13 constructors after Zombie
# (#14707, /loop iter 4) was added.  This script is the OCaml-side
# regression guard so the next phase-count change cannot quietly
# leave docstrings stale.
#
# Rule (mirrors audit-tla-phase-count.sh, OCaml comment syntax):
#   - SSOT: count `  | <CamelCase>` constructors between `type phase =`
#     and the next blank line in lib/keeper/keeper_state_machine.ml.
#   - Sweep `lib/keeper/*.{ml,mli}` for `\b(\d{1,2})[ -]state\b` and
#     `\b(\d{1,2})[ -]phase(s)?\b` inside comment lines (`(*`/`(**` or
#     continuation lines of a comment block).
#   - Range filter [SSOT-3 .. SSOT+5]: out-of-range numbers refer to
#     sibling FSMs (cascade=6, decision=5, turn-phase=7, etc.) and
#     are intentionally not flagged.
#   - Qualifier whitelist: if the line contains `non-`, `fragment`,
#     `projection`, `subset`, `relevant`, `out of scope`, `models`,
#     `collapse`, `symbol`, `triad`, `mapping`, `excluding`, `must skip`,
#     `excludes`, `other`, the mention is treated as an intentional
#     subset description.  `must skip` and `other` cover the
#     `keeper_runtime.ml:779`-style "the other N phases must skip"
#     comments where N = SSOT - 1.
#
# Usage: bash scripts/audit-ocaml-phase-count.sh [--verbose]
#
# RFC chain: R-B-1.c → R-H-1.c (TLA+ side #14874) → R-H-1.f (this
# script, OCaml side).
set -euo pipefail

for tool in rg awk grep; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "error: required tool '${tool}' not found in PATH" >&2
    exit 2
  }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEEPER_DIR="${REPO_ROOT}/lib/keeper"
SSOT_FILE="${REPO_ROOT}/lib/keeper/keeper_state_machine.ml"

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

# Baseline file format: one entry per line, "<repo-relative-path>:<lineno>",
# blank lines and lines starting with '#' are comments.  These entries
# are pre-existing drifts being fixed in flight by other PRs; the
# validator skips them so CI doesn't false-fail during the merge
# window.  Baseline entries MUST be removed once the corresponding fix
# PR lands.
declare -a BASELINE_KEYS=()
if [[ -n "${BASELINE_FILE}" ]]; then
  if [[ ! -f "${BASELINE_FILE}" ]]; then
    echo "error: baseline file not found: ${BASELINE_FILE}" >&2
    exit 2
  fi
  while IFS= read -r raw; do
    [[ -z "${raw}" ]] && continue
    case "${raw}" in '#'*) continue;; esac
    BASELINE_KEYS+=("${raw}")
  done < "${BASELINE_FILE}"
  [[ "${VERBOSE}" -eq 1 ]] && \
    echo "loaded ${#BASELINE_KEYS[@]} baseline entries" >&2
fi

in_baseline() {
  local key="$1"
  local b
  for b in "${BASELINE_KEYS[@]:-}"; do
    [[ "${b}" == "${key}" ]] && return 0
  done
  return 1
}

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

# Qualifier whitelist.  Adds `must skip`, `excludes`, "other N phases"
# / "the other N phases" on top of the TLA+ variant: these idioms appear
# in OCaml exhaustive-match comments like "the other N phases must
# skip ..." where N = SSOT - 1 (e.g. keeper_runtime.ml:779 with N=12 when
# SSOT=13).  `other` is anchored to "other N phases" so bare uses of the
# word "other" do not silently exempt real drifts.
QUALIFIERS='(non-|fragment|projection|subset|relevant|out of scope|models|collapse|symbol|triad|mapping|excluding|abstract|sibling|companion|must skip|excludes|(the )?other [0-9]+ phases?)'

drift_count=0
tmpfile="$(mktemp)"
trap 'rm -f "${tmpfile}"' EXIT

# rg over OCaml comment-bearing lines.  We match both `N-state` and
# `N[ -]phase(s)?` patterns since OCaml docstrings use both
# ("13-state keeper lifecycle", "13-phase enum", "13 phases").
rg_exit=0
rg -n --no-heading --glob '*.ml' --glob '*.mli' \
  -e '\b([0-9]{1,2})[ -](state|phase(s)?)\b' \
  "${KEEPER_DIR}" > "${tmpfile}" 2>/dev/null || rg_exit=$?
# rg exit 1 = no matches (treat as clean); exit 2+ = error (regex / I/O / glob).
if [[ "${rg_exit}" -ge 2 ]]; then
  echo "ERROR: ripgrep failed with exit ${rg_exit} while scanning ${KEEPER_DIR}" >&2
  exit "${rg_exit}"
fi

while IFS= read -r entry; do
  [[ -z "${entry}" ]] && continue
  file="${entry%%:*}"
  rest="${entry#*:}"
  lineno="${rest%%:*}"
  content="${rest#*:}"

  # Restrict to lines that look like OCaml comment / docstring context.
  # OCaml comment syntaxes: `(* ... *)` and `(** ... *)`.  Heuristic
  # (the script intentionally avoids a full OCaml comment-span parser):
  # require the line, after stripping leading whitespace, to either
  # (a) start with `(*` / `(**` / `*` (in-comment continuation) — i.e.
  # clearly inside a comment block, or (b) contain `*)` (comment closer
  # on the same line).  Code lines like `let foo = ...`, `type t = ...`,
  # variant arms etc. are rejected because they neither start with
  # `(*` / `*` nor contain `*)`.  This is more reliable than the prior
  # left-anchored keyword filter, which let prefixed-whitespace code
  # through and could flag string literals.
  stripped="${content#"${content%%[![:space:]]*}"}"
  case "${stripped}" in
    '(*'*|'(**'*|'*'*) : ;;          # comment open or continuation
    *)
      case "${content}" in
        *'*)'*) : ;;                 # contains comment closer
        *) continue ;;
      esac
      ;;
  esac

  matched_n="$(printf '%s' "${content}" \
    | grep -oE '[0-9]{1,2}[ -](state|phase)' \
    | head -1 \
    | grep -oE '^[0-9]+')"
  [[ -z "${matched_n}" ]] && continue

  if [[ "${matched_n}" == "${SSOT_COUNT}" ]]; then
    continue
  fi

  # Range filter — sibling FSMs (cascade=6, decision=5, turn=7, etc.)
  # use the same "N-state" / "N-phase" idiom and are intentionally not
  # the keeper-count drift class.
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

  rel_path="${file#${REPO_ROOT}/}"
  key="${rel_path}:${lineno}"
  if in_baseline "${key}"; then
    [[ "${VERBOSE}" -eq 1 ]] && \
      echo "ok (baseline): ${key} — ${matched_n} != ${SSOT_COUNT} (pending fix-PR)" >&2
    continue
  fi

  printf 'drift: %s — mentions "%s" but SSOT (lib/keeper/keeper_state_machine.ml type phase) has %s constructors\n' \
    "${key}" "${matched_n}-state/phase" "${SSOT_COUNT}"
  drift_count=$((drift_count + 1))
done < "${tmpfile}"

if [[ "${drift_count}" -gt 0 ]]; then
  echo "" >&2
  echo "${drift_count} OCaml docstring phase-count drift(s) detected." >&2
  echo "Fix: update the docstring/comment to match keeper_state_machine.ml" >&2
  echo "(${SSOT_COUNT} constructors), or add a qualifier (non-Zombie, projection," >&2
  echo "fragment, must skip, ...) if the mention is intentionally a subset count." >&2
  exit 1
fi

echo "OCaml phase-count audit clean: SSOT=${SSOT_COUNT}, no unqualified mismatches." >&2
