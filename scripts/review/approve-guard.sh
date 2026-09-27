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
# Skips (exit 0, no write) if this account already APPROVED that exact SHA.
#
# Usage:
#   approve-guard.sh --repo O/R --pr N --head SHA40 --body FILE
#                    [--replace-own-cr REVIEW_ID] [--git-dir DIR]
#   approve-guard.sh --check --run PR_CHECK_ID ...
#   approve-guard.sh --check ...   # evaluate only, never writes (safe probe)
# Exit: 0 approved/skipped/would-approve, 2 refused (reasons on stderr), 1 infra error.
# Env: GUARD_GH overrides the gh binary (tests use a fake).
# Needs bash + gh + git + Python 3. JSON uses gh --jq or the Python standard
# library; POST uses gh -f/-F, so no standalone jq is required.
# gh_json runs inside $( ); every caller ends with `|| exit 1` so a transport
# error stops the guard with exit 1 instead of turning into false refusals.
set -u
GH="${GUARD_GH:-gh}"
here="$(cd "$(dirname "$0")" && pwd)"
check_only=0; repo=""; pr=""; head=""; body=""; replace_cr=""; cited_run=""
gitdir="${GUARD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
while [ $# -gt 0 ]; do
  case "$1" in
    --run|--git-dir|--repo|--pr|--head|--body|--replace-own-cr)
      if [ $# -lt 2 ] || [ -z "${2-}" ] || [[ "${2-}" == --* ]]; then
        echo "approve-guard: $1 requires a value" >&2
        exit 1
      fi ;;
  esac
  case "$1" in
    --check) check_only=1; shift ;;
    --run) cited_run="${2-}"; shift 2 ;;
    --git-dir) gitdir="${2-}"; shift 2 ;;
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
if [ "$check_only" -eq 0 ]; then
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
  --head "$head" --run "$v_run" --git-dir "$gitdir")
fresh_rc=$?
if [ "$fresh_rc" -ne 0 ]; then
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
dup="$(gh_json "repos/${repo}/pulls/${pr}/reviews?per_page=100" ".[] | select(.user.login == \"${me}\" and .state == \"APPROVED\" and .commit_id == \"${head}\") | .id")" || exit 1
if [ -n "$dup" ]; then
  echo "SKIP #${pr}: ${me} already APPROVED ${head} (review $(echo "$dup" | head -n1))"
  exit 0
fi

footer="$(printf '\n\n---\napprove-guard: head `%s` · %d check-runs completed+success · workflow runs %s' \
  "$head" "$n_runs" "$(IFS=,; echo "${wf_ids[*]}")")"
footer="${footer} · freshness ${freshness}"
[ -z "$replaced" ] || footer="${footer} · replaces own CHANGES_REQUESTED ${replaced}"
[ -z "$(printf '%s' "$dispatch_skips" | tr -d ' ')" ] || footer="${footer} · dispatch-only skipped:${dispatch_skips}"
if [ "$check_only" -eq 1 ]; then
  echo "WOULD APPROVE #${pr} head ${head} (${n_runs} check-runs, workflow runs ${wf_ids[*]})"
  exit 0
fi

# ---- 7. revalidate shared-account CR authority after freshness, then write ----
check_open_change_requests
check_structured_verdict
[ ${#reasons[@]} -eq 0 ] || finish_refused
# Freshness and review reads can race a same-head reopen/rerun, just as merge
# reads can. Both writes must observe the latest workflow/check state.
check_current_ci || exit $?
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
