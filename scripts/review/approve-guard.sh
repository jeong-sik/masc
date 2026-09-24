#!/usr/bin/env bash
# approve-guard.sh — the only way a review lane posts APPROVE on jeong-sik/masc.
#
# Refuses unless ALL of these hold at call time (task-1718, goal-1790241464021):
#   1. --head is a 40-hex SHA and --slot is exactly "SLOT: #<pr> head <same sha>"
#   2. the PR is open, not draft, base == main, and its head is still that SHA
#   3. every check-run on that SHA is completed+success (none -> refuse)
#   4. every GitHub Actions workflow run for that SHA is completed+success
#      (a queued workflow has no check-runs yet; this catches it)
#   5. the body file is non-empty (no evidence-free approvals)
# Skips (exit 0, no write) if this account already APPROVED that exact SHA.
#
# The caller passes the SLOT line because a lane shell cannot read the Board.
# The guard proves the line names this PR+head; the caller proves the line is
# the current open SLOT on p-9505908f9a31ba600f4126bf0d31a37e.
#
# Usage:
#   approve-guard.sh --repo O/R --pr N --head SHA40 --slot 'SLOT: #N head SHA40' --body FILE
#   approve-guard.sh --check ...   # evaluate only, never writes (safe probe)
# Exit: 0 approved/skipped/would-approve, 2 refused (reasons on stderr), 1 infra error.
# Env: GUARD_GH overrides the gh binary (tests use a fake).
set -u
GH="${GUARD_GH:-gh}"
check_only=0; repo=""; pr=""; head=""; slot=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check_only=1; shift ;;
    --repo) repo="${2-}"; shift 2 ;;
    --pr) pr="${2-}"; shift 2 ;;
    --head) head="${2-}"; shift 2 ;;
    --slot) slot="${2-}"; shift 2 ;;
    --body) body="${2-}"; shift 2 ;;
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
gh_json() { # gh_json <endpoint> <jq> ; stdout=result, exit 1 on transport error
  local out
  if ! out="$("$GH" api --paginate "$1" --jq "$2" 2>&1)"; then
    echo "approve-guard: gh api $1 failed: $out" >&2; exit 1
  fi
  printf '%s' "$out"
}

# ---- 1. parse inputs (no network) ----
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || refuse "--repo must be owner/name, got '${repo}'"
[[ "$pr" =~ ^[1-9][0-9]*$ ]] || refuse "--pr must be a positive integer, got '${pr}'"
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || refuse "--head must be 40 lowercase hex chars, got ${#head} chars"
if [[ "$slot" =~ ^SLOT:\ \#([0-9]+)\ head\ ([0-9a-f]{40})$ ]]; then
  [ "${BASH_REMATCH[1]}" = "$pr" ] || refuse "SLOT names #${BASH_REMATCH[1]}, not #${pr}"
  [ "${BASH_REMATCH[2]}" = "$head" ] || refuse "SLOT head ${BASH_REMATCH[2]} != --head"
else
  refuse "--slot is not exactly 'SLOT: #<n> head <40-hex>'"
fi
if [ "$check_only" -eq 0 ]; then
  [ -n "$body" ] && [ -s "$body" ] || refuse "--body file missing or empty"
fi
[ ${#reasons[@]} -eq 0 ] || finish_refused

# ---- 2. PR state ----
pr_row="$(gh_json "repos/${repo}/pulls/${pr}" '[.state, (.draft|tostring), .base.ref, .head.sha, (.merged|tostring)] | @tsv')"
IFS=$'\t' read -r st draft base cur merged <<<"$pr_row"
[ "$st" = "open" ] || refuse "PR state is '${st}' (merged=${merged})"
[ "$draft" = "false" ] || refuse "PR is Draft"
[ "$base" = "main" ] || refuse "base is '${base}', not main"
[ "$cur" = "$head" ] || refuse "head moved: PR head is ${cur}"

# ---- 3. check-runs on this exact SHA ----
runs="$(gh_json "repos/${repo}/commits/${head}/check-runs?per_page=100" '.check_runs[] | [.name, .status, (.conclusion // "none"), (.id|tostring)] | @tsv')"
n_runs=0; run_ids=()
while IFS=$'\t' read -r name status concl id; do
  [ -n "${name:-}" ] || continue
  n_runs=$((n_runs+1)); run_ids+=("$id")
  if [ "$status" != "completed" ] || [ "$concl" != "success" ]; then
    refuse "check '${name}' is ${status}/${concl} (check-run ${id})"
  fi
done <<<"$runs"
[ "$n_runs" -gt 0 ] || refuse "no check-runs on ${head} (empty is not green)"

# ---- 4. workflow runs on this exact SHA (catches queued workflows) ----
wf="$(gh_json "repos/${repo}/actions/runs?head_sha=${head}&per_page=100" '.workflow_runs[] | [.name, .status, (.conclusion // "none"), (.id|tostring)] | @tsv')"
wf_ids=()
while IFS=$'\t' read -r name status concl id; do
  [ -n "${name:-}" ] || continue
  wf_ids+=("$id")
  if [ "$status" != "completed" ] || [ "$concl" != "success" ]; then
    refuse "workflow '${name}' run ${id} is ${status}/${concl}"
  fi
done <<<"$wf"
[ ${#wf_ids[@]} -gt 0 ] || refuse "no workflow runs for ${head}"
[ ${#reasons[@]} -eq 0 ] || finish_refused

# ---- 5. idempotence: already approved this SHA? ----
me="$(gh_json user '.login')"
dup="$(gh_json "repos/${repo}/pulls/${pr}/reviews?per_page=100" ".[] | select(.user.login == \"${me}\" and .state == \"APPROVED\" and .commit_id == \"${head}\") | .id")"
if [ -n "$dup" ]; then
  echo "SKIP #${pr}: ${me} already APPROVED ${head} (review $(echo "$dup" | head -n1))"
  exit 0
fi

footer="$(printf '\n\n---\napprove-guard: head `%s` · `%s` · %d check-runs completed+success · workflow runs %s' \
  "$head" "$slot" "$n_runs" "$(IFS=,; echo "${wf_ids[*]}")")"
if [ "$check_only" -eq 1 ]; then
  echo "WOULD APPROVE #${pr} head ${head} (${n_runs} check-runs, workflow runs ${wf_ids[*]})"
  exit 0
fi

# ---- 6. write, then read back ----
payload="$(jq -n --rawfile b "$body" --arg f "$footer" --arg c "$head" \
  '{event:"APPROVE", commit_id:$c, body:($b + $f)}')" || { echo "approve-guard: jq failed" >&2; exit 1; }
if ! resp="$(printf '%s' "$payload" | "$GH" api -X POST "repos/${repo}/pulls/${pr}/reviews" --input - --jq '[(.id|tostring), .state, .commit_id] | @tsv' 2>&1)"; then
  echo "approve-guard: POST review failed: $resp" >&2; exit 1
fi
IFS=$'\t' read -r rid rstate rcommit <<<"$resp"
back="$(gh_json "repos/${repo}/pulls/${pr}/reviews/${rid}" '[.state, .commit_id] | @tsv')"
IFS=$'\t' read -r bstate bcommit <<<"$back"
if [ "$bstate" != "APPROVED" ] || [ "$bcommit" != "$head" ]; then
  echo "approve-guard: posted review ${rid} reads back as ${bstate} on ${bcommit}" >&2; exit 1
fi
echo "APPROVED #${pr} head ${head} review ${rid}"
