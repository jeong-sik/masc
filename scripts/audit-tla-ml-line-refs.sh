#!/usr/bin/env bash
# audit-tla-ml-line-refs.sh — detect TLA+ spec preamble line-number
# citations that point at OCaml functions whose declarations have
# drifted relative to the cited line.
#
# Background: iter 63 #14919 audit found four citations in a now-retired
# queue model pointing at lines 751/772/941/970 in its OCaml source. The
# functions still existed at the time —
# submit_and_await / submit_pending / expire_stale — but at lines
# 996 / 1089 / 1335 / 1384 (+245 to +413 line drift).  Spec
# behavioural claims are accurate; only the line pointers are stale.
# Without a structural check, every commit that grows the OCaml file
# silently increases the drift.
#
# This validator is pipeline step 3/3 of the 8th drift class
# (audit → fix → guard), mirroring iter 52 #14874 (R-H-1.c TLA+
# phase-count) and iter 55 #14891 (R-H-1.f OCaml docstring phase-count).
#
# Rule 1 (drift check — prose `[func] ... line N` form):
#   - In each `specs/keeper-state-machine/*.tla` preamble (first 60
#     comment lines starting with `\*`), find every match of
#     `\[([a-z_]+)\][^,]*line[s ]+(\d+)` — i.e. a bracketed function
#     name and a nearby `line N` mention.
#   - Find the corresponding OCaml file: the first `lib/keeper/*.ml`
#     mention in the preamble (a `lib/keeper/*.mli` is used only if the
#     preamble cites no `.ml` at all).  Skip the cite if no file is
#     referenced.
#   - Verify: a binding of `<funcname>` (`let`, `let rec`, or `and`,
#     optionally indented) appears in that file within
#     [N - tolerance .. N + tolerance] inclusive (default tolerance 5).
#   - Emit drift if the function does not appear in that window.
#
# Tolerance keeps the validator silent for trivial whitespace/edit
# drift; structural moves (renames, large refactors, function deletion)
# fall outside.  Default 5 is empirical — KAQ's +245 drift would have
# tripped this at any tolerance under 200.
#
# Rule 2 (strict check — compact `file.ml:NNN` colon form):
#   - In each `specs/keeper-state-machine/*.tla` (whole file, not just
#     the preamble), reject any `<ident>.ml:<digit>` — the compact
#     `lib/keeper/keeper_foo.ml:648-656` form.  The iter-64 N-2.a
#     convention for this subdir is "no line numbers — cite OCaml by
#     symbol" (`keeper_foo.ml:my_function` or `keeper_foo.ml — my_function`);
#     line numbers drift on every edit to the OCaml file, symbols do not.
#   - Rule 1's prose-form regex (`[func] ... line N`) misses this compact
#     form entirely, so iter 84 #14971's mapping-table sweep + the
#     follow-up symbol-anchor commit left no automated guard against the
#     next preamble re-introducing it.  This rule closes that gap.
#   - `.ml` only — `.mli` interface files are small and don't grow, so
#     they're not subject to the growth-driven drift this guard targets,
#     and Rule 1 already de-prioritises `.mli` (it's only a fallback
#     there).  KeeperDecisionPipeline's `keeper_registry.mli:49-53` remains;
#     it is left for a separate cleanup if wanted.
#   - Scoped to keeper-state-machine because the other spec trees
#     (boundary/, bug-models/, auth/, ...) never adopted N-2.a and still
#     use the colon form freely; widening would need a baseline file.
#
# Usage: bash scripts/audit-tla-ml-line-refs.sh [--verbose] [--tolerance N]
#
# RFC chain: R-B-1.c → R-H-1.c (#14874) → R-H-1.f (#14891) → N-2.c
# (this script — Rule 1; iter 92 adds Rule 2), 8th drift class
# structural closure.
set -euo pipefail

for tool in awk grep sed; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "error: required tool '${tool}' not found in PATH" >&2
    exit 2
  }
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_DIR="${REPO_ROOT}/specs/keeper-state-machine"

VERBOSE=0
TOLERANCE=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=1; shift ;;
    --tolerance) TOLERANCE="$2"; shift 2 ;;
    --tolerance=*) TOLERANCE="${1#*=}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

drift_count=0
spec_count=0
cite_count=0

for spec in "${SPEC_DIR}"/*.tla; do
  spec_count=$((spec_count + 1))
  spec_name="$(basename "${spec}")"

  # Preamble is first 60 lines of `\*` comments (covers all current specs).
  preamble="$(head -60 "${spec}" | grep -E '^\\\*' || true)"
  [[ -z "${preamble}" ]] && continue

  # File reference in the preamble.  Rule: the first `.ml` mention wins;
  # a `.mli` is used only if the preamble cites no `.ml` at all.  Collect
  # every `.ml`/`.mli` ref first, then prefer the `.ml` ones — a plain
  # `head -1` over the mixed list would pick a `.mli` that merely appears
  # earlier than a later `.ml`.
  ml_refs="$(printf '%s' "${preamble}" \
    | { grep -oE 'lib/keeper/[a-z_]+\.mli?' || true; })"
  ml_file="$(printf '%s\n' "${ml_refs}" | { grep -E '\.ml$' || true; } | head -1)"
  [[ -z "${ml_file}" ]] && ml_file="$(printf '%s\n' "${ml_refs}" | head -1)"
  if [[ -z "${ml_file}" ]]; then
    continue
  fi

  ml_path="${REPO_ROOT}/${ml_file}"
  if [[ ! -f "${ml_path}" ]]; then
    [[ "${VERBOSE}" -eq 1 ]] && \
      echo "skip (file missing): ${spec_name} -> ${ml_file}" >&2
    continue
  fi

  ml_line_count="$(wc -l < "${ml_path}")"

  # Find `[funcname] ... line N` pairs in the preamble.  Each pair is
  # one citation we'll verify.  The regex requires the bracketed name
  # and the line number to be on the same comment line (preamble
  # lines are short enough that this holds for every current cite).
  while IFS= read -r match; do
    [[ -z "${match}" ]] && continue
    cite_count=$((cite_count + 1))

    func="$(printf '%s' "${match}" | sed -nE 's/.*\[([a-z_]+)\][^,]*line[s ]+([0-9]+).*/\1/p')"
    cited_line="$(printf '%s' "${match}" | sed -nE 's/.*\[([a-z_]+)\][^,]*line[s ]+([0-9]+).*/\2/p')"

    if [[ -z "${func}" || -z "${cited_line}" ]]; then
      continue
    fi

    if (( cited_line > ml_line_count )); then
      printf 'drift: %s — cites [%s] at line %s but %s has only %s lines\n' \
        "${spec_name}" "${func}" "${cited_line}" "${ml_file}" "${ml_line_count}"
      drift_count=$((drift_count + 1))
      continue
    fi

    lo=$((cited_line - TOLERANCE))
    [[ ${lo} -lt 1 ]] && lo=1
    hi=$((cited_line + TOLERANCE))

    # Capture `func`'s binding in the window.  Accept `let <name>`,
    # `let rec <name>`, and `and <name>` (the `let ... and ...` chain
    # continuation), with optional leading whitespace — top-level binds
    # sit at column 1 but a stray indent shouldn't make the check miss.
    if awk -v lo="${lo}" -v hi="${hi}" -v fn="${func}" '
      NR >= lo && NR <= hi {
        if ($0 ~ "^[[:space:]]*(let([[:space:]]+rec)?|and)[[:space:]]+" fn "($|[[:space:](])") {
          found = 1
        }
      }
      END { exit !found }
    ' "${ml_path}"; then
      [[ "${VERBOSE}" -eq 1 ]] && \
        echo "ok: ${spec_name} [${func}] at line ${cited_line} → matches in ${ml_file}" >&2
      continue
    fi

    # Find the actual current line, if any (same binding forms as above).
    actual_line="$(awk -v fn="${func}" '$0 ~ "^[[:space:]]*(let([[:space:]]+rec)?|and)[[:space:]]+" fn "($|[[:space:](])" { print NR; exit }' "${ml_path}")"
    if [[ -n "${actual_line}" ]]; then
      drift=$((actual_line - cited_line))
      sign='+'; (( drift < 0 )) && sign=''
      printf 'drift: %s — cites [%s] at line %s but actual is %s (drift %s%s) in %s\n' \
        "${spec_name}" "${func}" "${cited_line}" "${actual_line}" "${sign}" "${drift}" "${ml_file}"
    else
      printf 'drift: %s — cites [%s] at line %s but no let-declaration of "%s" in %s\n' \
        "${spec_name}" "${func}" "${cited_line}" "${func}" "${ml_file}"
    fi
    drift_count=$((drift_count + 1))

  done < <(printf '%s\n' "${preamble}" | grep -oE '\[[a-z_]+\][^,]*line[s ]+[0-9]+')
done

# ── Rule 2: strict colon-form `file.ml:NNN` check ──────────────────
# Whole-file scan (the colon form shows up in mapping tables and
# inline `\*` comments, not just the preamble).  Any hit is an N-2.a
# violation — line numbers must be symbols in this subdir.
colon_ref_count=0
for spec in "${SPEC_DIR}"/*.tla; do
  spec_name="$(basename "${spec}")"
  while IFS= read -r hit; do
    [[ -z "${hit}" ]] && continue
    colon_ref_count=$((colon_ref_count + 1))
    line_no="${hit%%:*}"
    line_txt="$(printf '%s' "${hit#*:}" | sed -E 's/^[[:space:]]+//' | cut -c1-100)"
    printf 'colon-ref: %s:%s — N-2.a: cite by symbol, not line — %s\n' \
      "${spec_name}" "${line_no}" "${line_txt}"
  done < <(grep -nE '[A-Za-z0-9_]+\.ml:[0-9]' "${spec}" || true)
done

if [[ "${drift_count}" -gt 0 || "${colon_ref_count}" -gt 0 ]]; then
  echo "" >&2
  if [[ "${drift_count}" -gt 0 ]]; then
    echo "${drift_count} line-reference drift(s) detected across ${spec_count} spec(s) (${cite_count} citation(s) checked)." >&2
    echo "Fix (Rule 1, drift): update the cited line numbers, OR replace the line-number cite with a symbol reference (N-2.a shape — e.g. \`keeper_foo.ml:my_function\` or \`keeper_foo.ml — my_function\`; iter 59 L-2.b precedent)." >&2
  fi
  if [[ "${colon_ref_count}" -gt 0 ]]; then
    echo "${colon_ref_count} colon-form line-ref(s) (\`file.ml:NNN\`) detected in specs/keeper-state-machine/*.tla — N-2.a requires symbol anchors." >&2
    echo "Fix (Rule 2, colon-form forbidden): replace each \`file.ml:NNN\` with a symbol anchor (\`file.ml:symbol\`) or a prose mention; line-number cites are not allowed under N-2.a." >&2
  fi
  exit 1
fi

echo "line-ref audit clean: ${cite_count} prose-form citation(s) verified + ${colon_ref_count} colon-form line-ref(s) across ${spec_count} spec(s)." >&2
