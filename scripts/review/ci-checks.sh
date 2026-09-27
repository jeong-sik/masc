# Read-only workflow/check gate shared by approval and the final merge read.
# Caller supplies GH, repo, pr, head and gitdir. On success wf, wf_ids, n_runs and
# dispatch_skips describe the admitted checks for the approval receipt.
# Status 1 means an API read failed; status 2 means the checks refuse the write.
ci_gh_json() {
  local out
  if ! out="$("$GH" api --paginate "$1" --jq "$2" 2>&1)"; then
    echo "approve-guard: gh api $1 failed: $out" >&2; return 1
  fi
  printf '%s' "$out"
}

check_current_ci() {
  local ci_reasons=()
  local ci_branch unrelated_suites active_suites
  ci_branch="$(ci_gh_json "repos/${repo}/pulls/${pr}" '.head.ref // ""')" || return 1
  if [ -z "$ci_branch" ]; then
    echo "REFUSED #${pr} head ${head}: current PR branch unavailable" >&2
    return 2
  fi
# ---- 3. workflow runs on this exact SHA (catches queued workflows) ----
# One SHA can carry several runs of one workflow: a run cancelled by a
# concurrency group, or a failed run followed by a reopen or a dispatch that
# passed. Only the newest run of each workflow/event says what it thinks
# of this SHA now -- the same rule section 4 applies per check name.
# A cancelled run says nothing about the SHA; it lost a concurrency race. On
# #39049 (2026-09-25) runs 14708 (success) and 14709 (cancelled) of one
# workflow started in the same second, so the newest number was the cancelled
# twin. A cancelled run is therefore ranked below every run that is not
# cancelled; it decides only when every run of that workflow was cancelled,
# and then the guard refuses. A newer queued or in-progress run still outranks
# an older finished one.
# sort+awk rather than an associative array: lanes may run bash 3.2.
wf_all="$(ci_gh_json "repos/${repo}/actions/runs?head_sha=${head}&per_page=100" '.workflow_runs[] | [(.workflow_id|tostring), (if .conclusion == "cancelled" then "0" else "1" end), (.run_number|tostring), .name, .status, (.conclusion // "none"), (.id|tostring), ((.check_suite_id // 0)|tostring), (.event // "none"), (.path // ""), (.head_branch // ""), ([.pull_requests[]?.number | tostring] | join(","))] | @tsv')" || return 1
# Different PR branches may share a SHA. Bind PR-event rows before picking
# a newest run, and discard their suites as well as superseded/cancelled ones.
# Empty associations require the event branch; ci-freshness validates the cited
# run's suite linkage independently. Non-PR workflows keep their existing gate.
unrelated_suites="$(printf '%s\n' "$wf_all" | awk -F '\t' -v branch="$ci_branch" -v pr="$pr" '
  NF && $9=="pull_request" && ($11!=branch || ($12!="" && !index("," $12 ",", "," pr ","))) {
    if ($8!="0") printf "%s ", $8
  }')"
wf_all="$(printf '%s\n' "$wf_all" | awk -F '\t' -v branch="$ci_branch" -v pr="$pr" '
  NF && ($9!="pull_request" || ($11==branch && ($12=="" || index("," $12 ",", "," pr ","))))')"
if ! printf '%s\n' "$wf_all" | awk -F '\t' '
  $9=="pull_request" && $10==".github/workflows/pr-check.yml" { found=1 }
  END { exit !found }'; then
  ci_reasons+=("no PR-check workflow run for PR ${pr} branch ${ci_branch}")
fi
wf_all="$(printf '%s\n' "$wf_all" | sort -t "$(printf '\t')" -k1,1 -k2,2nr -k3,3nr)"
wf="$(printf '%s\n' "$wf_all" | awk -F '\t' 'NF && !seen[$1 SUBSEP $9]++')"
# Event kinds remain separate: a newer workflow_dispatch success is not a
# replacement for this PR event's failure on a multi-event workflow.
# Which suite belongs to which event and workflow file: section 4 needs it to
# tell a by-design skipped dispatch job from a skipped one that should have run.
suite_kinds="$(printf '%s\n' "$wf_all" | awk -F '\t' 'NF && $8 + 0 != 0 { print $8 "\t" $9 "\t" $10 }')"
# The check suites of the runs that lost (older, or cancelled twins). Their
# check-runs are dropped in section 4: #39049's cancelled twin run 14709 owned
# the newest suite (97837801954) and all five of its check-runs were skipped.
lost_suites="${unrelated_suites}$(printf '%s\n' "$wf_all" | awk -F '\t' 'NF && seen[$1 SUBSEP $9]++ && $8 != "0" {printf "%s ", $8}')"
wf_ids=()
while IFS=$'\t' read -r _wid _rank _num name status concl id _suite; do
  [ -n "${name:-}" ] || continue
  wf_ids+=("$id")
  if [ "$status" != "completed" ] || [ "$concl" != "success" ]; then
    ci_reasons+=("workflow '${name}' run ${id} is ${status}/${concl}")
  fi
done <<<"$wf"
[ ${#wf_ids[@]} -gt 0 ] || ci_reasons+=("no workflow runs for ${head}")

# ---- 4. check-runs on this exact SHA ----
# One SHA can carry several check-runs of one name: a Draft-time suite whose
# jobs were skipped, then the suite that ran after ready_for_review; or a
# failed run followed by a re-run. The API returns every suite's rows, not one
# per name, so only the row from the newest suite says what that check thinks
# of this SHA now. The newest suite is the highest check_suite id, not the
# highest check-run id: on #39046 (2026-09-25) the Draft-time skipped row of
# 'dune build @check' had check-run id 108051996594, above the Ready-time
# success 108051995088, while its suite 97836272095 was older than 97836300496.
# Within one suite (a re-run), the higher check-run id is the newer row.
# sort+awk rather than an associative array: lanes may run bash 3.2.
runs="$(ci_gh_json "repos/${repo}/commits/${head}/check-runs?per_page=100" '.check_runs[] | [.name, .status, (.conclusion // "none"), (.id|tostring), ((.check_suite.id // 0)|tostring)] | @tsv')" || return 1
# Rows from a suite whose workflow run lost in section 3 never count.
runs="$(printf '%s\n' "$runs" | awk -F '\t' -v lost="$lost_suites" 'BEGIN { n = split(lost, l, " "); for (i = 1; i <= n; i++) if (l[i] != "") drop[l[i]] = 1 } NF && !($5 in drop)')"
# A multi-event workflow may use the same check name in PR and dispatch
# suites. Keep the newest check in each admitted workflow/event, so a dispatch
# success cannot replace a PR failure. Checks without a workflow suite retain
# the original newest-suite-per-name rule.
active_suites="$(printf '%s\n' "$wf" | awk -F '\t' 'NF && $8!="0" { printf "%s:%s:%s ", $8, $1, $9 }')"
runs="$(printf '%s\n' "$runs" | awk -F '\t' -v keys="$active_suites" '
  BEGIN {
    OFS=FS; n=split(keys, rows, " ")
    for (i=1; i<=n; i++) if (split(rows[i], fields, ":")==3) owner[fields[1]]=fields[2] ":" fields[3]
  }
  NF { print $0, ($5 in owner ? owner[$5] : "unlinked") }
' | sort -t "$(printf '\t')" -k1,1 -k6,6 -k5,5nr -k4,4nr | awk -F '\t' '
  BEGIN { OFS=FS }
  NF && !seen[$1 SUBSEP $6]++ { print $1,$2,$3,$4,$5 }')"
# A skipped row of the newest suite is a refusal, except when the job is one
# the pull_request event never runs: its `if:` requires workflow_dispatch
# (#38873, 2026-09-25: compare-tui exists only to be dispatched, so every PR
# run of that workflow carries it skipped). Narrow on purpose: a required job
# whose `if:` misfires still refuses, so this cannot turn a broken check
# green. The condition is read from the workflow file itself, and only for a
# pull_request-event suite; a dispatch suite owns the job's real verdict.
# GUARD_REPO_ROOT overrides where the workflow files are read from; the
# selftest points it at fixture trees.
dispatch_skips=""
n_runs=0; run_ids=()
while IFS=$'\t' read -r name status concl id suite; do
  [ -n "${name:-}" ] || continue
  if [ "$status" = "completed" ] && [ "$concl" = "skipped" ]; then
    suite_event="$(printf '%s\n' "$suite_kinds" | awk -F '\t' -v s="$suite" '$1 == s { print $2; exit }')"
    if [ "$suite_event" = "pull_request" ]; then
      # The check-run does not name its workflow file; find it from the runs
      # of this suite that section 3 already read.
      suite_path="$(printf '%s\n' "$suite_kinds" | awk -F '\t' -v s="$suite" '$1 == s { print $3; exit }')"
      wf_file="${GUARD_REPO_ROOT:-$gitdir}/${suite_path:-}"
      if [ -n "$suite_path" ] && [ -f "$wf_file" ] && \
         sed -n "/^  ${name}:$/,/^  [^ ]/p" "$wf_file" 2>/dev/null | grep -q "workflow_dispatch"; then
        dispatch_skips="$dispatch_skips $name"
        continue
      fi
    fi
  fi
  n_runs=$((n_runs+1)); run_ids+=("$id")
  if [ "$status" != "completed" ] || [ "$concl" != "success" ]; then
    ci_reasons+=("check '${name}' is ${status}/${concl} (check-run ${id})")
  fi
done <<<"$runs"
[ "$n_runs" -gt 0 ] || ci_reasons+=("no check-runs on ${head} (empty is not green)")
if [ ${#ci_reasons[@]} -ne 0 ]; then
  echo "REFUSED #${pr} head ${head}" >&2
  printf '  - %s\n' "${ci_reasons[@]}" >&2
  return 2
fi

}
