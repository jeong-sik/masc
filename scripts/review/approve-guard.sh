#!/usr/bin/env bash
# approve-guard.sh — the only way a review lane posts APPROVE on jeong-sik/masc.
#
# Refuses unless ALL of these hold at call time (task-1718, goal-1790241464021):
#   1. --head is a 40-hex SHA
#   2. the PR is open, not draft, base == main, and its head is still that SHA
#   3. the newest run of every GitHub Actions workflow for that SHA that is not
#      a cancelled twin is completed+success
#      (a queued workflow has no check-runs yet; this catches it)
#   4. the check-run of every name from the newest check suite on that SHA is
#      completed+success, ignoring suites of runs that lost in 3 (none -> refuse)
#   5. the body file is non-empty (no evidence-free approvals), and its first
#      line is a literal R1 verdict line for this head:
#        verdict: PASS head: <--head> run: <workflow run id on --head> by: <keeper>
#      where <keeper> is not this account's login (#38975, 2026-09-26)
#   6. no account has an open CHANGES_REQUESTED on the PR -- except this
#      account's own one when --replace-own-cr names exactly that review id
# Skips (exit 0, no write) only if this account's APPROVED review body
# names this SHA in both its verdict and approve-guard footer. GitHub may
# rewrite a review's REST commit_id after a later push.
#
# Usage:
#   approve-guard.sh --repo O/R --pr N --head SHA40 --body FILE
#                    [--replace-own-cr REVIEW_ID]
#   approve-guard.sh --check ...   # evaluate only, never writes (safe probe)
#   approve-guard.sh --merge-check --repo O/R --pr N --head SHA40
#                                  # count only approvals bound to this head
# Exit: 0 approved/skipped/would-approve, 2 refused (reasons on stderr), 1 infra error.
# Env: GUARD_GH overrides the gh binary (tests use a fake).
# Needs only bash + gh: every JSON read uses gh's built-in --jq and the POST uses
# gh -f/-F fields, so a lane without a standalone jq binary can still approve.
# gh_json runs inside $( ); every caller ends with `|| exit 1` so a transport
# error stops the guard with exit 1 instead of turning into false refusals.
set -u
GH="${GUARD_GH:-gh}"
check_only=0; merge_check=0; repo=""; pr=""; head=""; body=""; replace_cr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check_only=1; shift ;;
    --merge-check) merge_check=1; shift ;;
    --repo) repo="${2-}"; shift 2 ;;
    --pr) pr="${2-}"; shift 2 ;;
    --head) head="${2-}"; shift 2 ;;
    --body) body="${2-}"; shift 2 ;;
    --replace-own-cr) replace_cr="${2-}"; shift 2 ;;
    *) echo "approve-guard: unknown argument: $1" >&2; exit 1 ;;
  esac
done

reasons=()
refuse() { reasons+=("$1"); }
finish_refused() {
  echo "REFUSED #${pr} head ${head}" >&2
  for r in "${reasons[@]}"; do echo "  - $r" >&2; done
  exit 2
}
# --paginate follows every Link page, so a PR with more than 100 reviews or
# check-runs is read whole; per_page=100 only sets the page size. The selftest's
# fake gh refuses a GET without --paginate, so dropping it turns the suite red.
gh_json() { # gh_json <endpoint> <jq> ; stdout=result, returns 1 on transport error
  local out
  if ! out="$("$GH" api --paginate "$1" --jq "$2" 2>&1)"; then
    echo "approve-guard: gh api $1 failed: $out" >&2; return 1
  fi
  printf '%s' "$out"
}

# ---- 1. parse inputs (no network) ----
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || refuse "--repo must be owner/name, got '${repo}'"
[[ "$pr" =~ ^[1-9][0-9]*$ ]] || refuse "--pr must be a positive integer, got '${pr}'"
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || refuse "--head must be 40 lowercase hex chars, got ${#head} chars"
if [ -n "$replace_cr" ] && ! [[ "$replace_cr" =~ ^[1-9][0-9]*$ ]]; then
  refuse "--replace-own-cr must be a review id (digits), got '${replace_cr}'"
fi
# The body's first line is the R1 verdict line the merge relies on, so it must
# be literal text naming this head. On #38975 (2026-09-26, review 5325206074)
# the body carried `head: $(gh api ...)` from a quoted heredoc: the substitution
# never ran, the APPROVE landed on the right commit_id, and the PR merged on a
# PASS line that names no head. The run and by: fields are checked in section 5.
v_run=""; v_by=""
if [ "$merge_check" -eq 1 ] && [ "$check_only" -eq 1 ]; then
  refuse "--merge-check and --check are separate read-only modes"
fi
if [ "$check_only" -eq 0 ] && [ "$merge_check" -eq 0 ]; then
  if [ -n "$body" ] && [ -s "$body" ]; then
    vline="$(head -n 1 "$body" | tr -d '\r')"
    vre='^verdict: PASS head: ([0-9a-f]{40}) run: ([1-9][0-9]*) by: ([A-Za-z0-9._-]+)$'
    if [[ "$vline" =~ $vre ]]; then
      [ "${BASH_REMATCH[1]}" = "$head" ] || refuse "verdict line head ${BASH_REMATCH[1]} is not --head ${head}"
      v_run="${BASH_REMATCH[2]}"; v_by="${BASH_REMATCH[3]}"
    else
      refuse "body first line is not a literal verdict line 'verdict: PASS head: <40hex> run: <run id> by: <keeper>' (got: '${vline:0:120}')"
    fi
  else
    refuse "--body file missing or empty"
  fi
fi
[ ${#reasons[@]} -eq 0 ] || finish_refused

# The verdict line and final guard footer bind an approval to one head.
footer_prefix="$(printf 'approve-guard: head \x60%s\x60 · ' "$head")"
approval_head_jq="((.body // \"\" | split(\"\\n\") | first) | startswith(\"verdict: PASS head: ${head} run: \")) and ((.body // \"\" | split(\"\\n\") | map(select(length > 0)) | (last // \"\")) | startswith(\"${footer_prefix}\"))"

# ---- 2. PR state ----
pr_row="$(gh_json "repos/${repo}/pulls/${pr}" '[.state, (.draft|tostring), .base.ref, .head.sha, (.merged|tostring), .head.ref, (.user.login // "")] | @tsv')" || exit 1
IFS=$'\t' read -r st draft base cur merged pr_head_ref author <<<"$pr_row"
[ "$st" = "open" ] || refuse "PR state is '${st}' (merged=${merged})"
[ "$draft" = "false" ] || refuse "PR is Draft"
[ "$base" = "main" ] || refuse "base is '${base}', not main"
[ "$cur" = "$head" ] || refuse "head moved: PR head is ${cur}"
[ ${#reasons[@]} -eq 0 ] || finish_refused

# Read-only merge approval check. A review's commit_id can follow a later push,
# so only its verdict and guard footer can authorize the current head.
if [ "$merge_check" -eq 1 ]; then
  [ -n "$author" ] || { echo "approve-guard: PR author missing from API" >&2; exit 1; }
  review_rows="$(gh_json "repos/$repo/pulls/$pr/reviews?per_page=100" '.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED") | [.user.login, (.id|tostring), .state] | @tsv')" || exit 1
  review_rows="$(printf '%s\n' "$review_rows" | sort -t "$(printf '\t')" -k1,1 -k2,2nr | awk -F '\t' 'NF && !seen[$1]++')"
  approvals=""
  while IFS=$'\t' read -r who rid rstate; do
    [ -n "$who" ] && [ "$rstate" = "APPROVED" ] && [ "$who" != "$author" ] || continue
    bound="$(gh_json "repos/$repo/pulls/$pr/reviews/$rid" "select(.state == \"APPROVED\" and ($approval_head_jq)) | .id")" || exit 1
    [ -z "$bound" ] || approvals="$approvals $bound"
  done <<<"$review_rows"
  [ -n "$approvals" ] || { refuse "no non-author APPROVED review has this head in its verdict and guard footer"; finish_refused; }
  latest_head="$(gh_json "repos/$repo/pulls/$pr" '.head.sha')" || exit 1
  [ "$latest_head" = "$head" ] || { refuse "head moved during merge check: PR head is $latest_head"; finish_refused; }
  echo "MERGE-CHECK PASS #$pr head $head approvals:$approvals"
  exit 0
fi

# ---- 3. workflow runs on this exact SHA (catches queued workflows) ----
# One SHA can carry several runs of one workflow: a run cancelled by a
# concurrency group, or a failed run followed by a reopen or a dispatch that
# passed. Only the newest run of each workflow says what that workflow thinks
# of this SHA now -- the same rule section 4 applies per check name.
# A cancelled run says nothing about the SHA; it lost a concurrency race. On
# #39049 (2026-09-25) runs 14708 (success) and 14709 (cancelled) of one
# workflow started in the same second, so the newest number was the cancelled
# twin. A cancelled run is therefore ranked below every run that is not
# cancelled; it decides only when every run of that workflow was cancelled,
# and then the guard refuses. A newer queued or in-progress run still outranks
# an older finished one.
# sort+awk rather than an associative array: lanes may run bash 3.2.
wf_all="$(gh_json "repos/${repo}/actions/runs?head_sha=${head}&per_page=100" '.workflow_runs[] | [(.workflow_id|tostring), (if .conclusion == "cancelled" then "0" else "1" end), (.run_number|tostring), .name, .status, (.conclusion // "none"), (.id|tostring), ((.check_suite_id // 0)|tostring), (.event // "none"), (.path // ""), (.head_branch // "")] | @tsv')" || exit 1
# A failed manual Release run is ignorable only when the validator itself
# recorded the intended ref refusal. A runner/setup failure on the same ref
# must remain a failed workflow. The four jobs are fixed by release.yml; any
# missing, unexpected, or non-skipped downstream job fails closed.
ignored_release_dispatches=""
release_candidates="$(printf '%s\n' "$wf_all" | awk -F '\t' -v ref="$pr_head_ref" 'NF && $5 == "completed" && $6 != "success" && $9 == "workflow_dispatch" && $10 == ".github/workflows/release.yml" && $11 == ref && ref !~ /^release\/v/ { print $7 "\t" $8 }')"
while IFS=$'\t' read -r release_run release_suite; do
  [ -n "${release_run:-}" ] || continue
  validator_id="$(gh_json "repos/${repo}/actions/runs/${release_run}/jobs?per_page=100" '.jobs as $jobs | if ([$jobs[] | .name] | sort) == (["Validate manual Release ref", "release-body", "build", "release"] | sort) and ([$jobs[] | select(.name == "Validate manual Release ref" and .status == "completed" and .conclusion == "failure" and ([.steps[]? | select(.name == "Refuse unsupported manual ref" and .status == "completed" and .conclusion == "failure")] | length) == 1)] | length) == 1 and ([$jobs[] | select(.name != "Validate manual Release ref" and (.status != "completed" or .conclusion != "skipped"))] | length) == 0 then $jobs[] | select(.name == "Validate manual Release ref") | .id else empty end')" || exit 1
  [ -n "$validator_id" ] || continue
  marker="$(gh_json "repos/${repo}/check-runs/${validator_id}/annotations?per_page=100" '[.[] | select(.annotation_level == "failure" and .title == "MASC_RELEASE_REF_REJECTED" and (.message | startswith("Manual Release is limited to tags and release/v* branches.")))] | length')" || exit 1
  [ "$marker" = "1" ] || continue
  ignored_release_dispatches="${ignored_release_dispatches}${release_run}"$'\t'"${release_suite}"$'\n'
done <<<"$release_candidates"
ignored_release_run_suites="$(printf '%s\n' "$ignored_release_dispatches" | awk -F '\t' 'NF { if (ids != "") ids = ids ","; ids = ids $1 "/" $2 } END { print ids }')"
ignored_release_suites="$(printf '%s\n' "$ignored_release_dispatches" | awk -F '\t' 'NF && $2 != "0" { printf "%s ", $2 }')"
wf_all="$(printf '%s\n' "$wf_all" | awk -F '\t' -v ignored="$ignored_release_run_suites" 'BEGIN { n=split(ignored, a, ","); for (i=1;i<=n;i++) { split(a[i], p, "/"); if (p[1] != "") drop[p[1]]=1 } } NF && !($7 in drop)')"
wf_all="$(printf '%s\n' "$wf_all" | sort -t "$(printf '\t')" -k1,1 -k2,2nr -k3,3nr)"
wf="$(printf '%s\n' "$wf_all" | awk -F '\t' 'NF && !seen[$1]++')"
# Which suite belongs to which event and workflow file: section 4 needs it to
# tell a by-design skipped dispatch job from a skipped one that should have run.
suite_kinds="$(printf '%s\n' "$wf_all" | awk -F '\t' 'NF && $8 + 0 != 0 { print $8 "\t" $9 "\t" $10 }')"
# The check suites of the runs that lost (older, or cancelled twins). Their
# check-runs are dropped in section 4: #39049's cancelled twin run 14709 owned
# the newest suite (97837801954) and all five of its check-runs were skipped.
lost_suites="$(printf '%s\n' "$wf_all" | awk -F '\t' 'NF && seen[$1]++ && $8 != "0" {printf "%s ", $8}')"
wf_ids=()
while IFS=$'\t' read -r _wid _rank _num name status concl id _suite; do
  [ -n "${name:-}" ] || continue
  wf_ids+=("$id")
  if [ "$status" != "completed" ] || [ "$concl" != "success" ]; then
    refuse "workflow '${name}' run ${id} is ${status}/${concl}"
  fi
done <<<"$wf"
[ ${#wf_ids[@]} -gt 0 ] || refuse "no workflow runs for ${head}"

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
runs="$(gh_json "repos/${repo}/commits/${head}/check-runs?per_page=100" '.check_runs[] | [.name, .status, (.conclusion // "none"), (.id|tostring), ((.check_suite.id // 0)|tostring)] | @tsv')" || exit 1
# Rows from a suite whose workflow run lost in section 3 never count.
runs="$(printf '%s\n' "$runs" | awk -F '\t' -v lost="$lost_suites" -v ignored="$ignored_release_suites" 'BEGIN { n = split(lost, l, " "); for (i = 1; i <= n; i++) if (l[i] != "") drop[l[i]] = 1; n = split(ignored, x, " "); for (i = 1; i <= n; i++) if (x[i] != "") drop[x[i]] = 1 } NF && !($5 in drop)')"
runs="$(printf '%s\n' "$runs" | sort -t "$(printf '\t')" -k1,1 -k5,5nr -k4,4nr | awk -F '\t' 'NF && !seen[$1]++')"
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
      wf_file="${GUARD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}/${suite_path:-}"
      if [ -n "$suite_path" ] && [ -f "$wf_file" ] && \
         sed -n "/^  ${name}:$/,/^  [^ ]/p" "$wf_file" 2>/dev/null | grep -q "workflow_dispatch"; then
        dispatch_skips="$dispatch_skips $name"
        continue
      fi
    fi
  fi
  n_runs=$((n_runs+1)); run_ids+=("$id")
  if [ "$status" != "completed" ] || [ "$concl" != "success" ]; then
    refuse "check '${name}' is ${status}/${concl} (check-run ${id})"
  fi
done <<<"$runs"
[ "$n_runs" -gt 0 ] || refuse "no check-runs on ${head} (empty is not green)"
[ ${#reasons[@]} -eq 0 ] || finish_refused

# ---- 5. open change requests ----
me="$(gh_json user '.login')" || exit 1
[ -n "$me" ] || { echo "approve-guard: gh api user returned no login; cannot check for a duplicate approval" >&2; exit 1; }
# GitHub decides each account's stance by that account's newest review in
# APPROVED, CHANGES_REQUESTED or DISMISSED; a later COMMENTED does not lift a
# change request. Another account's open change request blocks the merge, so an
# APPROVE over it is noise that reads like a green light (#38810, 2026-09-24).
# This account's own change request would be replaced by the approval, but the
# account is shared by several lanes and the guard cannot tell which lane wrote
# it (#38168: one lane's approval silently lifted another lane's valid CR). So
# the caller must name that review id with --replace-own-cr; knowing the id is
# the proof the review was read, and the footer records it. A named id that is
# not this account's open CR refuses too: the caller's view is out of date.
revs="$(gh_json "repos/${repo}/pulls/${pr}/reviews?per_page=100" '.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED") | [.user.login, (.id|tostring), .state] | @tsv')" || exit 1
revs="$(printf '%s\n' "$revs" | sort -t "$(printf '\t')" -k1,1 -k2,2nr | awk -F '\t' 'NF && !seen[$1]++')"
replaced=""
while IFS=$'\t' read -r who rid rstate; do
  [ -n "${who:-}" ] && [ "$rstate" = "CHANGES_REQUESTED" ] || continue
  if [ "$who" != "$me" ]; then
    refuse "open CHANGES_REQUESTED from ${who} (review ${rid}); the merge stays blocked until ${who} approves or the review is dismissed"
  elif [ "$rid" = "$replace_cr" ]; then
    replaced="$rid"
  else
    refuse "open CHANGES_REQUESTED from ${me} (review ${rid}) is this account's own, and the account is shared: read it, then pass --replace-own-cr ${rid} to replace it"
  fi
done <<<"$revs"
if [ -n "$replace_cr" ] && [ "$replaced" != "$replace_cr" ]; then
  refuse "--replace-own-cr ${replace_cr} does not name an open CHANGES_REQUESTED from ${me}"
fi
# The verdict's run must be a workflow run on this head (a PASS carried from an
# older head names that head's run), and by: must name the Keeper that judged,
# not the shared account: '${me}' says nothing about which lane read the diff.
if [ "$check_only" -eq 0 ]; then
  case " ${wf_ids[*]} " in
    *" ${v_run} "*) ;;
    *) refuse "verdict line run ${v_run} is not a workflow run on ${head} (runs: ${wf_ids[*]})" ;;
  esac
  [ "$v_by" != "$me" ] || refuse "verdict line by: is the account login '${me}'; name the Keeper that judged"
fi
[ ${#reasons[@]} -eq 0 ] || finish_refused

# ---- 6. idempotence: already approved this SHA? ----
# GitHub can retarget commit_id after a later push; review body is the
# immutable evidence of what this account approved.
dup="$(gh_json "repos/${repo}/pulls/${pr}/reviews?per_page=100" ".[] | select(.user.login == \"${me}\" and .state == \"APPROVED\" and (${approval_head_jq})) | .id")" || exit 1
if [ -n "$dup" ]; then
  echo "SKIP #${pr}: ${me} already APPROVED ${head} (review $(echo "$dup" | head -n1))"
  exit 0
fi

footer="$(printf '\n\n---\napprove-guard: head `%s` · %d check-runs completed+success · workflow runs %s' \
  "$head" "$n_runs" "$(IFS=,; echo "${wf_ids[*]}")")"
[ -z "$replaced" ] || footer="${footer} · replaces own CHANGES_REQUESTED ${replaced}"
[ -z "$(printf '%s' "$dispatch_skips" | tr -d ' ')" ] || footer="${footer} · dispatch-only skipped:${dispatch_skips}"
[ -z "$ignored_release_run_suites" ] || footer="${footer} · ignored refused manual Release dispatch run/suite:${ignored_release_run_suites}"
if [ "$check_only" -eq 1 ]; then
  echo "WOULD APPROVE #${pr} head ${head} (${n_runs} check-runs, workflow runs ${wf_ids[*]})"
  exit 0
fi

# ---- 7. write, then read back ----
if ! resp="$({ cat "$body"; printf '%s' "$footer"; } | "$GH" api -X POST "repos/${repo}/pulls/${pr}/reviews" \
    -f event=APPROVE -f "commit_id=${head}" -F body=@- \
    --jq '[(.id|tostring), .state, .commit_id] | @tsv' 2>&1)"; then
  echo "approve-guard: POST review failed: $resp" >&2; exit 1
fi
IFS=$'\t' read -r rid rstate rcommit <<<"$resp"
back="$(gh_json "repos/${repo}/pulls/${pr}/reviews/${rid}" '[.state, .commit_id] | @tsv')" || exit 1
IFS=$'\t' read -r bstate bcommit <<<"$back"
if [ "$bstate" != "APPROVED" ] || [ "$bcommit" != "$head" ]; then
  echo "approve-guard: posted review ${rid} reads back as ${bstate} on ${bcommit}" >&2; exit 1
fi
echo "APPROVED #${pr} head ${head} review ${rid}"
