#!/usr/bin/env bash
# Shared PR-check Draft snapshot evidence. Source from Bash 3.2 callers.
# JSON is decoded by the caller's paginated gh --jq callback, never standalone jq.
# Only the new, complete six-job Draft namespace is excludable as Draft.
# Cancelled twins retain their existing loser rule. Historical
# canonical skipped checks and unrelated workflows keep the caller's policy.
PR_CHECK_WORKFLOWS_JQ='.workflow_runs[] | [(.workflow_id|tostring), (if .conclusion == "cancelled" then "0" else "1" end), (.run_number|tostring), (.name // "-"), .status, (.conclusion // "none"), (.id|tostring), ((.check_suite_id // 0)|tostring), (.event // "none"), (.path // "-"), (.head_branch // "-"), (.head_sha // "-"), (.created_at // "-")] | @tsv'
PR_CHECK_CHECKS_JQ='.check_runs[] | [.name, .status, (.conclusion // "none"), (.id|tostring), ((.check_suite.id // 0)|tostring), (.started_at // "-")] | @tsv'

pr_check_names() {
  printf '%s\n' 'TLA model check' 'lint suite' 'dune build @check' \
    'dune build --profile release @check' 'dashboard typecheck' 'PR required success'
}

# Keep the guard's latest per-name rule, constrained to ONE selected suite.
# Independent successes from different workflow suites cannot be combined.
pr_check_suite_rows() { # checks suite
  printf '%s\n' "$1" | awk -F '\t' -v suite="$2" 'NF && $5 == suite' |
    sort -t "$(printf '\t')" -k1,1 -k4,4nr | awk -F '\t' '!seen[$1]++'
}

pr_check_classify() { # repo head workflow-TSV check-TSV gh_json_callback
  # Call directly (not in $(...)): outputs are these globals. Return 1 only
  # on API failure. INVALID is an explicit refusal, never a normal fallback.
  PR_CHECK_DRAFT_RUNS=""; PR_CHECK_DRAFT_SUITES=""; PR_CHECK_INVALID=""
  PR_CHECK_CANCELLED_RUNS=""; PR_CHECK_CANCELLED_SUITES=""
  PR_CHECK_READY_RUN=""; PR_CHECK_READY_SUITE=""; PR_CHECK_READY_OK=no
  local repo="$1" head="$2" workflows="$3" checks="$4" api="$5"
  local suites suite meta count wid rank num name status conclusion run event path branch sha created
  local jobs rows expected actual pairs check_pairs draft_wid="" ready
  suites=$(printf '%s\n' "$checks" | awk -F '\t' 'index($1,"Draft snapshot / ")==1 {print $5}' | sort -u)
  [ -n "$suites" ] || return 0
  expected=$(pr_check_names | sed 's|^|Draft snapshot / |' | LC_ALL=C sort)
  for suite in $suites; do
    meta=$(printf '%s\n' "$workflows" | awk -F '\t' -v suite="$suite" '$8 == suite')
    count=$(printf '%s\n' "$meta" | awk 'NF {n++} END {print n+0}')
    IFS=$'\t' read -r wid rank num name status conclusion run suite event path branch sha created <<<"$meta"
    if [ "$count" != 1 ] || ! [[ "$wid" =~ ^[1-9][0-9]*$ && "$num" =~ ^[1-9][0-9]*$ && "$run" =~ ^[1-9][0-9]*$ && "$suite" =~ ^[1-9][0-9]*$ ]] ||
       [ "$sha" != "$head" ] || [ "$event" != pull_request ] ||
       [ "$path" != .github/workflows/pr-check.yml ] || [ "$status" != completed ]; then
      PR_CHECK_INVALID="invalid Draft snapshot workflow binding"; return 0
    fi
    if [ -n "$draft_wid" ] && [ "$draft_wid" != "$wid" ]; then
      PR_CHECK_INVALID="Draft snapshot workflow identity changed"; return 0
    fi
    draft_wid="$wid"
    # A cancelled sibling already loses under the caller's existing run rule.
    # It may never have emitted all six jobs. Keep this distinct from the
    # complete skipped-Draft proof, and still require independent Ready evidence.
    if [ "$conclusion" = cancelled ] && printf '%s\n' "$workflows" | awk -F '\t' -v wid="$wid" \
      '$1 == wid && $6 != "cancelled" {found=1} END {exit !found}'; then
      PR_CHECK_CANCELLED_RUNS="$PR_CHECK_CANCELLED_RUNS $run"
      PR_CHECK_CANCELLED_SUITES="$PR_CHECK_CANCELLED_SUITES $suite"
      continue
    fi
    if [ "$conclusion" != success ] && [ "$conclusion" != skipped ]; then
      PR_CHECK_INVALID="invalid Draft snapshot workflow result for run $run"; return 0
    fi
    # --paginate is the callback's contract. Aggregate rows BEFORE checking the
    # multiset: per-page booleans could accept an extra or duplicate seventh job.
    jobs=$("$api" "repos/$repo/actions/runs/$run/jobs?filter=latest&per_page=100" \
      '.jobs[] | [.name, .status, (.conclusion // "none"), (.id|tostring), ((.run_id // 0)|tostring), (.head_sha // "-")] | @tsv') || return 1
    actual=$(printf '%s\n' "$jobs" | cut -f1 | LC_ALL=C sort)
    if [ "$actual" != "$expected" ] || ! printf '%s\n' "$jobs" | awk -F '\t' -v run="$run" -v head="$head" \
      'NF != 6 || $2 != "completed" || $3 != "skipped" || $4 !~ /^[1-9][0-9]*$/ || seen[$4]++ || $5 != run || $6 != head {bad=1} END {exit bad}'; then
      PR_CHECK_INVALID="invalid Draft snapshot jobs for run $run"; return 0
    fi
    rows=$(pr_check_suite_rows "$checks" "$suite")
    pairs=$(printf '%s\n' "$jobs" | cut -f1-4 | LC_ALL=C sort)
    check_pairs=$(printf '%s\n' "$rows" | cut -f1-4 | LC_ALL=C sort)
    if [ "$pairs" != "$check_pairs" ]; then
      PR_CHECK_INVALID="Draft snapshot jobs/check suite mismatch for run $run"; return 0
    fi
    PR_CHECK_DRAFT_RUNS="$PR_CHECK_DRAFT_RUNS $run"
    PR_CHECK_DRAFT_SUITES="$PR_CHECK_DRAFT_SUITES $suite"
  done
  # Apply the existing newest noncancelled-run rule within this workflow only.
  # A newer Ready pending/failing run must never be hidden by an earlier green.
  ready=$(printf '%s\n' "$workflows" | awk -F '\t' -v wid="$draft_wid" -v drop="$PR_CHECK_DRAFT_RUNS $PR_CHECK_CANCELLED_RUNS" '
    BEGIN {n=split(drop,a," "); for(i=1;i<=n;i++) gone[a[i]]=1}
    $1 == wid && !($7 in gone)' | sort -t "$(printf '\t')" -k2,2nr -k3,3nr | head -n 1)
  IFS=$'\t' read -r wid rank num name status conclusion run suite event path branch sha created <<<"$ready"
  if ! [[ "$num" =~ ^[1-9][0-9]*$ && "$run" =~ ^[1-9][0-9]*$ && "$suite" =~ ^[1-9][0-9]*$ ]] ||
     [ "$sha" != "$head" ] || [ "$event" != pull_request ] ||
     [ "$path" != .github/workflows/pr-check.yml ]; then
    return 0
  fi
  PR_CHECK_READY_RUN="$run"; PR_CHECK_READY_SUITE="$suite"
  [ "$status" = completed ] && [ "$conclusion" = success ] || return 0
  rows=$(pr_check_suite_rows "$checks" "$suite")
  actual=$(printf '%s\n' "$rows" | cut -f1 | LC_ALL=C sort)
  expected=$(pr_check_names | LC_ALL=C sort)
  [ "$actual" = "$expected" ] || return 0
  if printf '%s\n' "$rows" | awk -F '\t' \
    '$2 != "completed" || $3 != "success" || $4 !~ /^[1-9][0-9]*$/ || seen[$4]++ {bad=1} END {exit bad}'; then
    PR_CHECK_READY_OK=yes
  fi
}
