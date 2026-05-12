#!/usr/bin/env bash
# audit-ocaml-spec-nav-line-refs.sh — detect stale `[symbol] (~line N)`
# citations inside OCaml "Spec navigation (OCaml -> TLA+)" reverse-citation
# blocks in lib/keeper/*.{ml,mli}.
#
# Background: this is the OCaml-docstring twin of the TLA-side validator
# scripts/audit-tla-ml-line-refs.sh (iter 64 N-2.c, the 8th drift class's
# audit→fix→guard step 3).  That validator only scans
# specs/keeper-state-machine/*.tla preambles.  But the same drift exists
# on the OCaml side: a module's header docstring carries a reverse
# citation like
#
#     ExpireStale  [expire_stale] (~line 941) sweeps timed-out entries
#
# and the OCaml line drifts away from 941 as the file grows.  iter 70/71
# (#14939 keeper_failure_circuit_breaker, #14943 keeper_approval_queue)
# found four such sites with drift +29 .. +424; iter 71's survey memo is
# docs/tla-audit/ocaml-docstring-lineref-drift-class-2026-05-12.md.
#
# Rule:
#   - In each lib/keeper/*.{ml,mli}, find every match of
#     `\[(type )?<sym>\] ... line N` on a single line — i.e. a bracketed
#     symbol name (optionally prefixed with `type `) and a nearby
#     `line N` mention, with no bracket between them.
#   - Verify: `^let <sym>` / `^and <sym>` / `^type <sym>` / `^  type <sym>`
#     appears in the SAME file within [N - tolerance .. N + tolerance]
#     inclusive (default tolerance 5).
#   - Emit drift if the symbol does not appear in that window.
#
# Baseline: scripts/ocaml-spec-nav-line-refs-baseline.txt grandfathers the
# four sites in flight as of iter 72; each line "<repo-relative-path>:<sym>".
# Drain a line when its fix-PR merges (same convention as the
# ocaml-phase-count baseline header).
#
# Usage: bash scripts/audit-ocaml-spec-nav-line-refs.sh [--verbose] \
#          [--tolerance N] [--baseline FILE]
#
# RFC chain: R-B-1.c → R-H-1.c (#14874) → R-H-1.f (#14891) → N-2.c (#14925)
# → R-1.a (this script).  OCaml-docstring corner of the line-ref drift class.
set -euo pipefail

for tool in rg awk grep sed; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "error: required tool '${tool}' not found in PATH" >&2
    exit 2
  }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEEPER_DIR="${REPO_ROOT}/lib/keeper"

VERBOSE=0
TOLERANCE=5
BASELINE_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=1; shift ;;
    --tolerance) TOLERANCE="$2"; shift 2 ;;
    --tolerance=*) TOLERANCE="${1#*=}"; shift ;;
    --baseline) BASELINE_FILE="$2"; shift 2 ;;
    --baseline=*) BASELINE_FILE="${1#*=}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

declare -a BASELINE_KEYS=()
if [[ -n "${BASELINE_FILE}" ]]; then
  if [[ ! -f "${BASELINE_FILE}" ]]; then
    echo "error: baseline file not found: ${BASELINE_FILE}" >&2
    exit 2
  fi
  while IFS= read -r raw; do
    raw="${raw%%#*}"
    raw="$(printf '%s' "${raw}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "${raw}" ]] && continue
    BASELINE_KEYS+=("${raw}")
  done < "${BASELINE_FILE}"
fi

in_baseline() {
  local key="$1" b
  for b in "${BASELINE_KEYS[@]:-}"; do
    [[ "${b}" == "${key}" ]] && return 0
  done
  return 1
}

drift_count=0
file_count=0
cite_count=0
baseline_hit=0

shopt -s nullglob
for ml in "${KEEPER_DIR}"/*.ml "${KEEPER_DIR}"/*.mli; do
  file_count=$((file_count + 1))
  rel="lib/keeper/$(basename "${ml}")"
  ml_line_count="$(wc -l < "${ml}")"

  # Each `[sym] ... line N` pair (sym optionally `type `-prefixed; no
  # bracket between the symbol and the line number).
  while IFS= read -r match; do
    [[ -z "${match}" ]] && continue

    sym="$(printf '%s' "${match}" | sed -nE 's/.*\[(type )?([a-z_]+)\][^][]*line[s ]+([0-9]+).*/\2/p')"
    cited_line="$(printf '%s' "${match}" | sed -nE 's/.*\[(type )?([a-z_]+)\][^][]*line[s ]+([0-9]+).*/\3/p')"
    [[ -z "${sym}" || -z "${cited_line}" ]] && continue

    cite_count=$((cite_count + 1))
    key="${rel}:${sym}"

    if in_baseline "${key}"; then
      baseline_hit=$((baseline_hit + 1))
      [[ "${VERBOSE}" -eq 1 ]] && \
        echo "ok (baseline): ${key} cites line ${cited_line} (pending fix-PR)" >&2
      continue
    fi

    if (( cited_line > ml_line_count )); then
      printf 'drift: %s — cites [%s] at line %s but file has only %s lines\n' \
        "${rel}" "${sym}" "${cited_line}" "${ml_line_count}"
      drift_count=$((drift_count + 1))
      continue
    fi

    lo=$((cited_line - TOLERANCE)); [[ ${lo} -lt 1 ]] && lo=1
    hi=$((cited_line + TOLERANCE))

    if awk -v lo="${lo}" -v hi="${hi}" -v sym="${sym}" '
      NR >= lo && NR <= hi {
        if ($0 ~ "^(let|and)[[:space:]]+" sym "($|[[:space:](:])" ||
            $0 ~ "^[[:space:]]*type[[:space:]]+" sym "($|[[:space:]=])") {
          found = 1
        }
      }
      END { exit !found }
    ' "${ml}"; then
      [[ "${VERBOSE}" -eq 1 ]] && \
        echo "ok: ${key} at line ${cited_line} → matches in ${rel}" >&2
      continue
    fi

    actual_line="$(awk -v sym="${sym}" '
      $0 ~ "^(let|and)[[:space:]]+" sym "($|[[:space:](:])" ||
      $0 ~ "^[[:space:]]*type[[:space:]]+" sym "($|[[:space:]=])" { print NR; exit }
    ' "${ml}")"
    if [[ -n "${actual_line}" ]]; then
      drift=$((actual_line - cited_line)); sign='+'; (( drift < 0 )) && sign=''
      printf 'drift: %s — cites [%s] at line %s but actual is %s (drift %s%s)\n' \
        "${rel}" "${sym}" "${cited_line}" "${actual_line}" "${sign}" "${drift}"
    else
      printf 'drift: %s — cites [%s] at line %s but no let/and/type-declaration of "%s"\n' \
        "${rel}" "${sym}" "${cited_line}" "${sym}"
    fi
    drift_count=$((drift_count + 1))

  done < <(grep -oE '\[(type )?[a-z_]+\][^][]*line[s ]+[0-9]+' "${ml}" || true)
done

if [[ "${drift_count}" -gt 0 ]]; then
  echo "" >&2
  echo "${drift_count} OCaml-docstring line-reference drift(s) across ${file_count} file(s) (${cite_count} citation(s) checked, ${baseline_hit} baselined)." >&2
  echo "Fix: drop the line number and name the symbol (N-2.a shape), OR — if it must stay — re-anchor it.  See docs/tla-audit/ocaml-docstring-lineref-drift-class-2026-05-12.md." >&2
  exit 1
fi

echo "ocaml-spec-nav line-ref audit clean: ${cite_count} citation(s) verified across ${file_count} file(s) (${baseline_hit} baselined)." >&2
