#!/usr/bin/env bash
# OCaml structural-debt ratchet gate.
#
# Tracks 6 metrics that capture structural debt called out by external review
# (Jane-Street-style large-OCaml expectations):
#
#   - keeper_mli_missing: count of lib/keeper/keeper_*.ml files without a
#     matching .mli (interface-first design gap)
#   - coord_mli_missing : same metric for lib/coord/
#   - godsplit_count    : occurrences of `;; godsplit` markers in lib/dune
#     (god-file decomposition stubs left as comments — should converge to 0
#     by sub-library extraction)
#   - lib_dune_lines    : raw line count of lib/dune (proxy for the
#     monolithic-library debt; sub-library splits should reduce this)
#   - inferred_dump_headers: count of .mli files in lib/ carrying an
#     auto-generated `(** X inferred mli **)` self-incriminating header.
#     Each such header signals a never-curated interface dump; the .mli
#     content is verbatim inferred-type output that should be normalized
#     to a real one-line docstring.
#   - lib_other_mli_missing: long-tail .mli coverage — every lib/*/*.ml
#     file outside lib/keeper/ and lib/coord/ that lacks a sibling .mli.
#     Captures lib/server/, lib/dashboard/, lib/config/, lib/local/,
#     lib/types/, lib/voice/, etc.
#
# Policy: ratchet only — current value must be <= committed baseline. PRs
# that reduce debt may regenerate the baseline (intentional "downward
# ratchet"). Increases must be justified by --regenerate with a paired
# follow-up issue (anti-pattern: silent baseline rebound after admin
# override; see masc-mcp memory feedback_ratchet-naturalization-after-admin-merge).
#
# Usage:
#   scripts/ocaml-structure-ratchet.sh              # check; exit 0 ok / 2 drift up / 1 error
#   scripts/ocaml-structure-ratchet.sh --regenerate # rewrite baseline from current counts
#   scripts/ocaml-structure-ratchet.sh --print      # print current counts, no compare

set -euo pipefail

# Required tools — fail fast with an actionable message rather than the
# silent exit-127 that bites a pipefail-protected `rg | wc | tr` when
# ripgrep is absent (regression that broke every PR's ratchet for ~2h
# after PR #11402 added count_inferred_dump_headers).
for tool in rg python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' not found on PATH." >&2
    echo "  On Debian/Ubuntu: sudo apt-get install -y -qq ripgrep python3" >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASELINE_FILE="${REPO_ROOT}/scripts/ocaml-structure-baseline.json"

count_mli_missing() {
  local dir="$1"
  local prefix_glob="$2"
  local ml_count mli_count
  ml_count=$(find "${REPO_ROOT}/${dir}" -maxdepth 1 -type f -name "${prefix_glob}.ml" 2>/dev/null | wc -l | tr -d ' ')
  mli_count=$(find "${REPO_ROOT}/${dir}" -maxdepth 1 -type f -name "${prefix_glob}.mli" 2>/dev/null | wc -l | tr -d ' ')
  echo $((ml_count - mli_count))
}

count_godsplit() {
  rg -c '^\s*;;\s*godsplit' "${REPO_ROOT}/lib/dune" 2>/dev/null || echo 0
}

count_lib_dune_lines() {
  wc -l < "${REPO_ROOT}/lib/dune" | tr -d ' '
}

count_inferred_dump_headers() {
  # rg exits 1 with no matches; pipe to wc -l so an empty stream still
  # prints 0. Using -l (file count) — one self-incriminating header per file.
  rg -l "inferred mli" "${REPO_ROOT}/lib" 2>/dev/null | wc -l | tr -d ' '
}

count_lib_other_mli_missing() {
  # All lib/*/*.ml files without a sibling .mli, EXCLUDING lib/keeper/
  # and lib/coord/ which have dedicated metrics. Captures the long
  # tail (lib/server/, lib/dashboard/, lib/config/, lib/local/, etc.).
  python3 - <<'EOF' "${REPO_ROOT}"
import os, sys, glob
repo_root = sys.argv[1]
total = 0
for d in glob.glob(os.path.join(repo_root, 'lib', '*') + '/'):
    name = d.rstrip('/').rsplit('/', 1)[-1]
    if name in ('keeper', 'coord'):
        continue
    for ml in glob.glob(d + '*.ml'):
        if not os.path.exists(ml + 'i'):
            total += 1
print(total)
EOF
}

# Metric definitions: name|hint
METRICS=(
  "keeper_mli_missing|Add .mli for the new lib/keeper/keeper_*.ml file. See planning/claude-plans/moonlit-finding-russell.md PR#2-4."
  "coord_mli_missing|Add .mli for the new lib/coord/*.ml file."
  "godsplit_count|Do not add new ';; godsplit' markers in lib/dune — extract a real sub-library instead. See PR#7-10."
  "lib_dune_lines|lib/dune is growing — consider extracting modules into a sub-library (lib/keeper/dune, lib/oas/dune, lib/dashboard/dune)."
  "inferred_dump_headers|Replace the '(** X inferred mli **)' header with a real one-line docstring. See PR#11286/11290/11296/11303/11309/11321/11401 for the closure series."
  "lib_other_mli_missing|Add .mli for the new lib/*/*.ml file (covers every dir except keeper/coord which have their own metrics)."
)

current_value() {
  case "$1" in
    keeper_mli_missing)     count_mli_missing "lib/keeper" "keeper_*" ;;
    coord_mli_missing)      count_mli_missing "lib/coord"  "*" ;;
    godsplit_count)         count_godsplit ;;
    lib_dune_lines)         count_lib_dune_lines ;;
    inferred_dump_headers)  count_inferred_dump_headers ;;
    lib_other_mli_missing)  count_lib_other_mli_missing ;;
    *) echo "unknown metric: $1" >&2; exit 1 ;;
  esac
}

baseline_value() {
  local name="$1"
  if [[ -f "$BASELINE_FILE" ]]; then
    python3 -c "
import json, sys
with open('$BASELINE_FILE') as f:
    data = json.load(f)
print(data.get('$name', 0))
"
  else
    echo 0
  fi
}

print_counts() {
  printf "%-22s %9s  %9s\n" "metric" "current" "baseline"
  echo "------------------------------------------------"
  for spec in "${METRICS[@]}"; do
    local name="${spec%%|*}"
    local current baseline
    current=$(current_value "$name")
    baseline=$(baseline_value "$name")
    printf "%-22s %9d  %9d\n" "$name" "$current" "$baseline"
  done
}

regenerate() {
  local tmpfile
  tmpfile=$(mktemp)
  {
    echo '{'
    echo '  "_comment": "OCaml structural-debt baseline. Regenerate with scripts/ocaml-structure-ratchet.sh --regenerate.",'
    echo '  "_metrics": "See scripts/ocaml-structure-ratchet.sh METRICS array.",'
    local first=1
    for spec in "${METRICS[@]}"; do
      local name="${spec%%|*}"
      local current
      current=$(current_value "$name")
      if [[ $first -eq 1 ]]; then first=0; else echo ','; fi
      printf '  "%s": %s' "$name" "$current"
    done
    echo
    echo '}'
  } > "$tmpfile"
  mv "$tmpfile" "$BASELINE_FILE"
  echo "Baseline written to $BASELINE_FILE"
  print_counts
}

check() {
  if [[ ! -f "$BASELINE_FILE" ]]; then
    echo "ERROR: baseline file not found: $BASELINE_FILE" >&2
    echo "Run: $0 --regenerate" >&2
    exit 1
  fi

  local drift_up=0
  local drift_down=0

  for spec in "${METRICS[@]}"; do
    local name="${spec%%|*}"
    local hint="${spec#*|}"
    local current baseline
    current=$(current_value "$name")
    baseline=$(baseline_value "$name")

    if [[ "$current" -gt "$baseline" ]]; then
      echo "FAIL $name: $current > baseline $baseline" >&2
      echo "     Fix: $hint" >&2
      drift_up=$((drift_up + 1))
    elif [[ "$current" -lt "$baseline" ]]; then
      echo "OK   $name: $current < baseline $baseline (baseline can be lowered)" >&2
      drift_down=$((drift_down + 1))
    fi
  done

  if [[ $drift_up -gt 0 ]]; then
    echo >&2
    echo "OCaml structure ratchet: $drift_up metric(s) exceeded baseline." >&2
    echo "Either fix the regression, or (if intentional) run: $0 --regenerate" >&2
    echo "and pair the regenerate commit with a follow-up issue." >&2
    exit 2
  fi

  if [[ $drift_down -gt 0 ]]; then
    echo >&2
    echo "Hint: $drift_down metric(s) dropped below baseline. Consider: $0 --regenerate" >&2
  fi

  echo "OCaml structure ratchet: OK"
  exit 0
}

case "${1:-check}" in
  --regenerate) regenerate ;;
  --print)      print_counts ;;
  check|"")     check ;;
  -h|--help)
    sed -n '1,38p' "$0"
    exit 0
    ;;
  *)
    echo "Unknown arg: $1" >&2
    exit 1
    ;;
esac
