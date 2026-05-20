#!/usr/bin/env bash
# Code-smell monotone-decrease ratchet.
#
# Locks the four metrics defined in
# memory/masc-mcp-code-smell-report-2026-05-19.html §6 (Reproducibility)
# against a stored baseline (.ci/code-smell-baseline.json). PRs may
# decrease or hold counts; increases fail this check.
#
# Metrics (measured EXACTLY as the HTML prescribes):
#   1. godfile            — .ml files >= 1000 LoC under lib/
#   2. catch_all          — "| _ ->" arms in lib/**/*.ml
#   3. contains_substring — top-level "let contains_substring" definitions
#   4. ignore_calls       — "^\s*ignore (" call sites
#
# Usage:
#   scripts/ci-code-smell-ratchet.sh --measure      # print current JSON, no compare
#   scripts/ci-code-smell-ratchet.sh --check        # compare current vs baseline; fail if any metric exceeds baseline
#   scripts/ci-code-smell-ratchet.sh --rebaseline   # main-only: write current counts to baseline JSON
#
# Escape hatch: see PR body label `RATCHET-WAIVED: <reason>`. CI workflow
# (.github/workflows/code-smell-ratchet.yml) skips --check failure when
# label present.
#
# DO NOT change metric definitions without an RFC update.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

BASELINE_FILE=".ci/code-smell-baseline.json"

# Resolve real find(1). Some shells alias `find` to ripgrep.
FIND_BIN="$(command -v /usr/bin/find || command -v find)"

measure_godfile() {
  # HTML command: find lib -name "*.ml" -exec wc -l {} + | awk '$1>=1000{c++}END{print c+0}'
  # Note: wc with multiple chunks emits "total" lines; the HTML count includes them.
  # Reproduce HTML count literally — both runs match (no totals at >=1000 in practice for grouped chunks here).
  "$FIND_BIN" lib -name "*.ml" -exec wc -l {} + \
    | awk '$1>=1000 && $2!="total"{c++}END{print c+0}'
}

measure_catch_all() {
  rg -c "^\s*\| _ ->" lib/ --type ml | awk -F: '{s+=$NF}END{print s+0}'
}

measure_contains_substring() {
  rg -c "^let contains_substring" lib/ --type ml | awk -F: '{s+=$NF}END{print s+0}'
}

measure_ignore_calls() {
  rg "^\s*ignore \(" lib/ --type ml -c | awk -F: '{s+=$NF}END{print s+0}'
}

emit_json() {
  local godfile catch_all contains_substring ignore_calls
  godfile="$(measure_godfile)"
  catch_all="$(measure_catch_all)"
  contains_substring="$(measure_contains_substring)"
  ignore_calls="$(measure_ignore_calls)"
  printf '{\n'
  printf '  "godfile": %s,\n' "$godfile"
  printf '  "catch_all": %s,\n' "$catch_all"
  printf '  "contains_substring": %s,\n' "$contains_substring"
  printf '  "ignore_calls": %s\n' "$ignore_calls"
  printf '}\n'
}

read_baseline_key() {
  # Tiny JSON read without jq dependency — keys are simple integers.
  local key="$1"
  python3 -c "import json,sys; print(json.load(open('$BASELINE_FILE'))['$key'])"
}

do_check() {
  local current godfile_cur catch_all_cur contains_cur ignore_cur
  local godfile_base catch_all_base contains_base ignore_base
  local failed=0

  godfile_cur="$(measure_godfile)"
  catch_all_cur="$(measure_catch_all)"
  contains_cur="$(measure_contains_substring)"
  ignore_cur="$(measure_ignore_calls)"

  godfile_base="$(read_baseline_key godfile)"
  catch_all_base="$(read_baseline_key catch_all)"
  contains_base="$(read_baseline_key contains_substring)"
  ignore_base="$(read_baseline_key ignore_calls)"

  printf "Code-smell ratchet (monotone-decrease)\n"
  printf "Source: memory/masc-mcp-code-smell-report-2026-05-19.html §6\n"
  printf "%-22s %10s %10s %s\n" "metric" "baseline" "current" "verdict"
  printf "%-22s %10s %10s %s\n" "----------------------" "--------" "-------" "-------"

  check_one() {
    local name="$1" base="$2" cur="$3"
    local verdict
    if [ "$cur" -gt "$base" ]; then
      verdict="FAIL (+$((cur - base)))"
      failed=1
    elif [ "$cur" -lt "$base" ]; then
      verdict="OK (decreased -$((base - cur)))"
    else
      verdict="OK (held)"
    fi
    printf "%-22s %10s %10s %s\n" "$name" "$base" "$cur" "$verdict"
  }

  check_one "godfile"            "$godfile_base"  "$godfile_cur"
  check_one "catch_all"          "$catch_all_base" "$catch_all_cur"
  check_one "contains_substring" "$contains_base" "$contains_cur"
  check_one "ignore_calls"       "$ignore_base"   "$ignore_cur"

  if [ "$failed" -ne 0 ]; then
    printf "\nratchet FAILED — at least one metric increased above baseline.\n"
    printf "Options:\n"
    printf "  (a) reduce the metric in this PR (root fix > workaround)\n"
    printf "  (b) add 'RATCHET-WAIVED: <reason>' to PR body and link a sunset RFC\n"
    return 1
  fi
  printf "\nratchet PASSED.\n"
  return 0
}

do_rebaseline() {
  # main-only: write current measurements to baseline JSON. CI workflow
  # job guards branch to refs/heads/main; this is a sanity check.
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [ "$current_branch" != "main" ] && [ "${ALLOW_REBASELINE_OFF_MAIN:-0}" != "1" ]; then
    printf "refusing to rebaseline off main (branch=%s). Set ALLOW_REBASELINE_OFF_MAIN=1 to override.\n" "$current_branch" >&2
    return 2
  fi
  local godfile catch_all contains_substring ignore_calls commit ts
  godfile="$(measure_godfile)"
  catch_all="$(measure_catch_all)"
  contains_substring="$(measure_contains_substring)"
  ignore_calls="$(measure_ignore_calls)"
  commit="$(git rev-parse HEAD)"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  cat > "$BASELINE_FILE" <<EOF
{
  "_comment": "Code-smell monotone-decrease ratchet baseline. Source: memory/masc-mcp-code-smell-report-2026-05-19.html §6 (Reproducibility commands). PRs may decrease or hold counts; increases fail unless PR body carries RATCHET-WAIVED: <reason>. Updated only on main via scripts/ci-code-smell-ratchet.sh --rebaseline.",
  "godfile": $godfile,
  "catch_all": $catch_all,
  "contains_substring": $contains_substring,
  "ignore_calls": $ignore_calls,
  "lastUpdated": "$ts",
  "lastUpdatedCommit": "$commit"
}
EOF
  printf "rebaselined: godfile=%s catch_all=%s contains_substring=%s ignore_calls=%s\n" \
    "$godfile" "$catch_all" "$contains_substring" "$ignore_calls"
}

case "${1:---check}" in
  --measure)    emit_json ;;
  --check)      do_check ;;
  --rebaseline) do_rebaseline ;;
  -h|--help)
    sed -n '2,30p' "$0"
    ;;
  *)
    printf "unknown option: %s (use --measure | --check | --rebaseline)\n" "$1" >&2
    exit 2
    ;;
esac
