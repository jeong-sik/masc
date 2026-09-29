#!/usr/bin/env bash
# approve-guard.sh — the only way a review lane posts APPROVE on jeong-sik/masc.
#
# Refuses unless ALL of these hold at call time (task-1718, goal-1790241464021):
#   1. --head is a 40-hex SHA
#   2. the PR is open, not draft, base == main, and its head is still that SHA
#   3. the newest run of every GitHub Actions workflow/event for that SHA that
#      is not a cancelled twin is completed+success; PR runs belong to this PR
#      (a queued workflow has no check-runs yet; this catches it)
#   4. every check from each admitted workflow/event suite is completed+success,
#      ignoring unrelated PR suites and runs that lost in 3 (none -> refuse)
#   5. the body file is non-empty (no evidence-free approvals), and its first
#      line is a literal R1 verdict line for this head:
#        verdict: PASS head: <--head> run: <workflow run id on --head> by: <keeper>
#      where <keeper> is not this account's login (#38975, 2026-09-26)
#   6. ci-freshness.py admits the exact PR-check against live main
#   7. no account has an open CHANGES_REQUESTED on the PR -- except this
#      account's own one when --replace-own-cr names exactly that review id
# Skips (exit 0, no write) only if this account's APPROVED review body
# names this SHA in both its verdict and approve-guard footer. GitHub may
# rewrite a review's REST commit_id after a later push.
#
# Usage:
#   approve-guard.sh --repo O/R --pr N --head SHA40 --body FILE
#                    [--replace-own-cr REVIEW_ID] [--git-dir DIR]
#   approve-guard.sh --check --run PR_CHECK_ID ...
#   approve-guard.sh --check ...   # evaluate only, never writes (safe probe)
#   approve-guard.sh --merge-check --receipt-json ...  # verified approval IDs
#   approve-guard.sh --merge-check --repo O/R --pr N --head SHA40
#                                  # trusted non-author approvals bound to this head
# Exit: 0 approved/skipped/would-approve, 2 refused (reasons on stderr), 1 infra error.
# Env: GUARD_GH overrides the gh binary (tests use a fake).
# Needs bash + gh + git + Python 3. JSON uses gh --jq or the Python standard
# library; POST uses gh -f/-F, so no standalone jq is required.
# gh_json runs inside $( ); every caller ends with `|| exit 1` so a transport
# error stops the guard with exit 1 instead of turning into false refusals.
set -u
GH="${GUARD_GH:-gh}"
here="$(cd "$(dirname "$0")" && pwd)"
check_only=0; merge_check=0; receipt_json=0; repo=""; pr=""; head=""; body=""; replace_cr=""; cited_run=""; batch=""
gitdir="${GUARD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
while [ $# -gt 0 ]; do
  case "$1" in
    --run|--git-dir|--repo|--pr|--head|--body|--replace-own-cr|--batch)
      if [ $# -lt 2 ] || [ -z "${2-}" ] || [[ "${2-}" == --* ]]; then
        echo "approve-guard: $1 requires a value" >&2
        exit 1
      fi ;;
  esac
  case "$1" in
    --check) check_only=1; shift ;;
    --merge-check) merge_check=1; shift ;;
    --receipt-json) receipt_json=1; shift ;;
    --run) cited_run="${2-}"; shift 2 ;;
    --git-dir) gitdir="${2-}"; shift 2 ;;
    --repo) repo="${2-}"; shift 2 ;;
    --pr) pr="${2-}"; shift 2 ;;
    --head) head="${2-}"; shift 2 ;;
    --body) body="${2-}"; shift 2 ;;
    --replace-own-cr) replace_cr="${2-}"; shift 2 ;;
    --batch) batch="${2-}"; shift 2 ;;
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
if [ "$receipt_json" -eq 1 ] && [ "$merge_check" -ne 1 ]; then
  refuse "--receipt-json requires --merge-check"
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

# Freeze the caller's file so reads and the approval body use the same line.
batch_args=(); batch_line=""
if [ -n "$batch" ]; then
  batch_line=$(python3 -c 'import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); from batch_evidence import parse; print(parse(Path(sys.argv[2]).read_text()).line)' "$here" "$batch") || exit 1
  batch_copy=$(mktemp) || exit 1
  trap 'rm -f "$batch_copy"' EXIT
  printf '%s\n' "$batch_line" > "$batch_copy"
  batch_args=(--batch "$batch_copy")
fi

# The verdict line and final guard footer bind an approval to one head.
footer_prefix="$(printf 'approve-guard: head \x60%s\x60 · ' "$head")"
approval_head_jq="((.body // \"\" | split(\"\\n\") | first) | startswith(\"verdict: PASS head: ${head} run: \")) and ((.body // \"\" | split(\"\\n\") | map(select(length > 0)) | (last // \"\")) | startswith(\"${footer_prefix}\"))"

# Read-only merge approval check. A review's commit_id can follow a later push,
# so only its verdict and guard footer can authorize the current head.
# The approval/write path below revalidates PR identity inside ci-checks.sh.
if [ "$merge_check" -eq 1 ]; then
  pr_row="$(gh_json "repos/${repo}/pulls/${pr}" '[.state, (.draft|tostring), .base.ref, .head.sha, (.merged|tostring), .head.ref, (.user.login // "")] | @tsv')" || exit 1
  IFS=$'\t' read -r st draft base cur merged pr_head_ref author <<<"$pr_row"
  [ "$st" = "open" ] || refuse "PR state is '${st}' (merged=${merged})"
  [ "$draft" = "false" ] || refuse "PR is Draft"
  [ "$base" = "main" ] || refuse "base is '${base}', not main"
  [ "$cur" = "$head" ] || refuse "head moved: PR head is ${cur}"
  [ ${#reasons[@]} -eq 0 ] || finish_refused
  [ -n "$author" ] || { echo "approve-guard: PR author missing from API" >&2; exit 1; }
  review_rows="$(gh_json "repos/$repo/pulls/$pr/reviews?per_page=100" '.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED") | [.user.login, (.id|tostring), .state] | @tsv')" || exit 1
  review_rows="$(printf '%s\n' "$review_rows" | sort -t "$(printf '\t')" -k1,1 -k2,2nr | awk -F '\t' 'NF && !seen[$1]++')"
  while IFS=$'\t' read -r who rid rstate; do
    [ -n "${who:-}" ] && [ "$rstate" = "CHANGES_REQUESTED" ] || continue
    refuse "open CHANGES_REQUESTED from ${who} (review ${rid}) takes precedence over counted approvals"
  done <<<"$review_rows"
  [ ${#reasons[@]} -eq 0 ] || finish_refused
  approvals=""
  while IFS=$'\t' read -r who rid rstate; do
    [ -n "$who" ] && [ "$rstate" = "APPROVED" ] && [ "$who" != "$author" ] || continue
    # Authority and head binding must belong to this same latest review. A
    # trusted footerless review cannot lend authority to an outsider's body.
    bound="$(gh_json "repos/$repo/pulls/$pr/reviews/$rid" "select(.state == \"APPROVED\" and
      (.author_association == \"OWNER\" or .author_association == \"MEMBER\" or .author_association == \"COLLABORATOR\") and
      ($approval_head_jq)) | .id")" || exit 1
    [ -z "$bound" ] || approvals="$approvals $bound"
  done <<<"$review_rows"
  [ -n "$approvals" ] || { refuse "no non-author APPROVED review has this head in its verdict and guard footer with trusted repository authority"; finish_refused; }
  latest_head="$(gh_json "repos/$repo/pulls/$pr" '.head.sha')" || exit 1
  [ "$latest_head" = "$head" ] || { refuse "head moved during merge check: PR head is $latest_head"; finish_refused; }
  if [ "$receipt_json" -eq 1 ]; then
    python3 -c 'import json, sys; print(json.dumps({"pr": int(sys.argv[1]), "head": sys.argv[2], "approval_ids": [int(value) for value in sys.argv[3].split()]}))' \
      "$pr" "$head" "$approvals" || exit 1
  else
    echo "MERGE-CHECK PASS #$pr head $head approvals:$approvals"
  fi
  exit 0
fi

# ---- 2–4. PR state and current CI ----
# Both write entry points revalidate the same live PR and workflow/check state.
source "$here/ci-checks.sh"
check_current_ci || exit $?

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
check_open_change_requests() {
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
}
check_open_change_requests
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

# A successful head is insufficient after main changes its build inputs.
# --check callers may name a run; otherwise use the current PR-check run.
if [ "$check_only" -eq 1 ]; then
  v_run="$cited_run"
  if [ -z "$v_run" ]; then
    v_run="$(printf '%s\n' "$wf" | awk -F '\t' '$9=="pull_request" && $10==".github/workflows/pr-check.yml" { print $7; exit }')"
  fi
fi
[[ "$v_run" =~ ^[1-9][0-9]*$ ]] || refuse "no explicit successful PR-check run for freshness"
[ ${#reasons[@]} -eq 0 ] || finish_refused
freshness=$(GUARD_GH="$GH" python3 "$here/ci-freshness.py" --repo "$repo" --pr "$pr" \
  --head "$head" --run "$v_run" --git-dir "$gitdir" ${batch_args[@]+"${batch_args[@]}"})
fresh_rc=$?
if [ "$fresh_rc" -ne 0 ]; then
  if [ -n "$batch" ]; then
    # Preserve the batch CLI's typed refusal through merge-guard to land-batch.
    printf '%s\n' "$freshness" >&2
    exit "$fresh_rc"
  fi
  refuse "CI freshness: $freshness"
  finish_refused
fi

check_structured_verdict() {
source "$here/review-verdict.sh"
latest_verdict=$(verdict_for "$pr" "$head") || exit 1
read -r latest_state _latest_run _latest_by <<<"$latest_verdict"
if [ -n "$latest_state" ] && [ "$latest_state" != PASS ]; then
  refuse "latest structured verdict is ${latest_state}; publish an explicit trusted review response before approval"
fi
}
check_structured_verdict
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
footer="${footer} · freshness ${freshness}"
[ -z "$replaced" ] || footer="${footer} · replaces own CHANGES_REQUESTED ${replaced}"
[ -z "$(printf '%s' "$dispatch_skips" | tr -d ' ')" ] || footer="${footer} · dispatch-only skipped:${dispatch_skips}"
[ -z "$ignored_release_run_suites" ] || footer="${footer} · ignored refused manual Release dispatch run/suite:${ignored_release_run_suites}"
# ---- 7. revalidate shared-account CR authority before return or write ----
check_open_change_requests
check_structured_verdict
[ ${#reasons[@]} -eq 0 ] || finish_refused
# Freshness and review reads can race a same-head reopen/rerun, just as merge
# reads can. Re-read decisions after that final CI gate as well: a HOLD/FAIL
# may arrive while its workflow/check requests are in flight. These sequential
# reads narrow the race; they cannot provide a server-side atomic decision.
check_current_ci || exit $?
check_structured_verdict
# Formal requests may have plain bodies. Re-read them after the final CI read
# too; the structured-verdict reader cannot enforce shared-account CR consent.
check_open_change_requests
[ ${#reasons[@]} -eq 0 ] || finish_refused
if [ -n "$batch" ]; then
  # Revalidate all batch members and live main after the last ordinary gate.
  GUARD_GH="$GH" python3 "$here/ci-freshness.py" --repo "$repo" --pr "$pr" \
    --head "$head" --run "$v_run" --git-dir "$gitdir" ${batch_args[@]+"${batch_args[@]}"} >/dev/null || exit $?
  check_open_change_requests
  check_structured_verdict
  [ ${#reasons[@]} -eq 0 ] || finish_refused
fi
[ -z "$PR_CHECK_DRAFT_RUNS" ] || footer="${footer} · verified Draft snapshot runs:${PR_CHECK_DRAFT_RUNS}"
[ -z "$PR_CHECK_CANCELLED_RUNS" ] || footer="${footer} · cancelled Draft snapshot twins:${PR_CHECK_CANCELLED_RUNS}"
if [ "$check_only" -eq 1 ]; then
  echo "WOULD APPROVE #${pr} head ${head} (${n_runs} check-runs, workflow runs ${wf_ids[*]})"
  exit 0
fi
if ! resp="$({ cat "$body"; [ -z "$batch_line" ] || printf '\n\n%s\n' "$batch_line"; printf '%s' "$footer"; } | "$GH" api -X POST "repos/${repo}/pulls/${pr}/reviews" \
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
