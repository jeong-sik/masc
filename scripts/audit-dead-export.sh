#!/usr/bin/env bash
# audit-dead-export.sh — Pre-removal audit for OCaml .mli exports.
#
# Background: five consecutive "0 callers" dead-export sweep PRs
# (#17946 Auth_strict_mode.of_string, #17947 set_util.{of_list_with,
# count_distinct}, #17950 Prompt_defaults.init, #17998
# Lockfree_atomic.update_with_result, #18009
# Exec_adaptive_timeout.{stats,stats_to_json}) all merged with a
# correct "no production callers" reading but missed the test
# callers — leaving compile breakage that took follow-up PRs to
# restore or migrate. The shared missing step in every audit body
# was `rg <name> test/`.
#
# This script makes the audit reproducible and categorizes call
# sites so the sweeper sees facade exposures and test pins before
# concluding "dead".
#
# Usage:
#   bash scripts/audit-dead-export.sh <Module.name>
#   bash scripts/audit-dead-export.sh <name>             # unqualified
#
# Examples:
#   bash scripts/audit-dead-export.sh Auth_strict_mode.of_string
#   bash scripts/audit-dead-export.sh count_distinct
#
# Output sections (each header includes a count):
#   1. Qualified production callers      (lib/* outside the defining module)
#   2. Test callers                       (test/*)
#   3. Facade exposures                   (include / module M = Mod / let f = Mod.f)
#   4. mli docstring mentions             (e.g. {!Mod.name} or [Mod.name])
#   5. Bare-name callers                  (caller likely has `open Mod`)
#
# Exit status:
#   0   no callers anywhere (genuinely dead — safe to remove)
#   1   only test callers and/or facade exposures (audit-miss risk;
#       restore-vs-migrate decision needed — see classification
#       matrix in any of the iter-1..iter-5 PR bodies referenced
#       above)
#   2   production callers exist (do NOT remove)
#
# The exit codes intentionally distinguish the "0 production but
# non-zero test" case so CI gates or pre-commit hooks can require
# a justification PR body when that bucket is non-empty.
#
# See: instructions/software-development.md §"AI 코드 생성 안티패턴"
# (#3 in the audit-driven removal cluster).

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <Module.name | bare_name>" >&2
  exit 64
fi

input="$1"

# Parse Module.name vs bare name.
if [[ "$input" == *.* ]]; then
  module="${input%%.*}"
  name="${input##*.}"
  qualified="$input"
else
  module=""
  name="$input"
  qualified=""
fi

# Word-boundary regex for the bare name.
name_pattern="\b${name}\b"

# Inferred defining file (best-effort; only used to exclude self-refs).
defining_ml=""
if [[ -n "$module" ]]; then
  # OCaml module Mod_name comes from mod_name.ml.
  mod_lower=$(echo "$module" | tr '[:upper:]' '[:lower:]')
  defining_ml="lib/${mod_lower}.ml"
fi

# Build rg excludes. Always exclude _build and worktrees.
rg_base=(rg --no-heading -n -g '!_build*' -g '!.worktrees/*')

# ─── 1. Qualified production callers ──────────────────────────────
echo "=== 1. Qualified production callers (lib/*) ==="
if [[ -n "$qualified" ]]; then
  qualified_lib=$("${rg_base[@]}" "${qualified//./\\.}" lib/ 2>/dev/null \
    | grep -v "^${defining_ml}:" || true)
else
  qualified_lib=$("${rg_base[@]}" "\.${name}\b" lib/ 2>/dev/null || true)
fi
prod_count=$(printf '%s' "$qualified_lib" | grep -c '^.' || true)
echo "$qualified_lib"
echo "(count: $prod_count)"
echo

# ─── 2. Test callers (the historically missed bucket) ─────────────
# Tests almost always alias the defining module (`module L = Foo`),
# so a strictly-qualified search misses real callers. Use a
# capital-prefix dot-access shape `<Mod>.<name>` so a generic bare
# name like `init` or `of_string` doesn't drown the signal in
# unrelated namespaces.
echo "=== 2. Test callers (test/*) ==="
test_pat="[A-Z][A-Za-z0-9_]*\.${name}\b"
test_callers=$("${rg_base[@]}" "$test_pat" test/ 2>/dev/null || true)
test_count=$(printf '%s' "$test_callers" | grep -c '^.' || true)
echo "$test_callers"
echo "(count: $test_count — matched 'X.${name}' shape, any module/alias prefix)"
echo

# ─── 3. Facade exposures ──────────────────────────────────────────
# An `include Mod`, `module X = Mod`, or `let f = Mod.f` line means
# bare-name references downstream may be reaching this export.
echo "=== 3. Facade exposures (include / alias / re-export) ==="
if [[ -n "$module" ]]; then
  facade=$("${rg_base[@]}" -e "^include ${module}$" \
                            -e "^include ${module} " \
                            -e "^module [A-Z][A-Za-z_]* = ${module}$" \
                            -e "^let ${name} = ${module}\.${name}$" \
                            lib/ 2>/dev/null || true)
else
  facade=""
fi
facade_count=$(printf '%s' "$facade" | grep -c '^.' || true)
echo "$facade"
echo "(count: $facade_count)"
echo

# ─── 4. mli docstring mentions ────────────────────────────────────
echo "=== 4. mli docstring mentions ==="
if [[ -n "$qualified" ]]; then
  doc_mentions=$("${rg_base[@]}" \
    -e "\{!${qualified//./\\.}\}" \
    -e "\[${qualified//./\\.}\]" \
    "**/*.mli" 2>/dev/null || true)
else
  doc_mentions=$("${rg_base[@]}" \
    -e "\{!${name}\}" \
    -e "\[${name}\]" \
    "**/*.mli" 2>/dev/null || true)
fi
doc_count=$(printf '%s' "$doc_mentions" | grep -c '^.' || true)
echo "$doc_mentions"
echo "(count: $doc_count)"
echo

# ─── 5. Bare-name callers ─────────────────────────────────────────
# Only meaningful when a facade exposure exists OR caller opens the
# defining module; this surfaces both cases.
echo "=== 5. Bare-name callers (likely via open/include) ==="
bare=$("${rg_base[@]}" "$name_pattern" --type ml 2>/dev/null \
  | grep -v "^${defining_ml}:" || true)
# Filter out the qualified hits we already showed.
if [[ -n "$qualified" ]]; then
  bare=$(printf '%s\n' "$bare" | grep -v "${qualified//./\\.}" || true)
fi
bare_count=$(printf '%s' "$bare" | grep -c '^.' || true)
# Truncate output — bare name searches can be very noisy.
if (( bare_count > 50 )); then
  printf '%s\n' "$bare" | head -50
  echo "  ... ($((bare_count - 50)) more lines suppressed; inspect manually)"
else
  echo "$bare"
fi
echo "(count: $bare_count)"
echo

# ─── Summary + exit ───────────────────────────────────────────────
echo "─── Summary ─────────────────────────────────────────────────"
printf '  production callers:  %d\n' "$prod_count"
printf '  test callers:        %d  <- most-missed bucket\n' "$test_count"
printf '  facade exposures:    %d\n' "$facade_count"
printf '  mli doc mentions:    %d\n' "$doc_count"
printf '  bare-name callers:   %d  (heuristic; review when facade>0)\n' "$bare_count"
echo

if (( prod_count > 0 )); then
  echo "RESULT: production callers exist — do NOT remove. Migrate callers first."
  exit 2
fi

if (( test_count > 0 )) || (( facade_count > 0 )); then
  echo "RESULT: zero production callers, but test/facade exposures exist."
  echo "  Restore-vs-migrate decision per the loop/surface-ssot classification matrix:"
  echo "    - mli docstring explicitly justifies the surface (e.g. 'exposed for"
  echo "      unit tests', 'thin fixture-level entry point') ............... RESTORE"
  echo "    - generic mli header only; no role differentiation ............ DELETE + migrate tests"
  echo "    - sibling form (record vs tuple, etc.) absorbs the surface .... MIGRATE callers"
  exit 1
fi

echo "RESULT: zero callers anywhere — safe to remove from both .ml and .mli."
exit 0
