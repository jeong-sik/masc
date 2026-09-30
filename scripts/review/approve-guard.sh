#!/usr/bin/env bash
# Review-only approval entry. CI and freshness belong to --integration-check
# and merge-guard, never to a reviewer's source judgment.
# --check evaluates the same body/identity/head/own-CR rules without a write.
# --merge-check requires a trusted independent head-bound formal approval and
# refuses any open CR. --integration-check is the merge-only CI preflight.
# Shared accounts must explicitly name their own CR to replace it.
# Exit 0 success, 2 refused, 1 transport/input failure; no polling or retries.
set -u
GH="${GUARD_GH:-gh}"
here="$(cd "$(dirname "$0")" && pwd)"
check_only=0; merge_check=0; integration_check=0; receipt_json=0; batch=""; repo=""; pr=""; head=""; body=""; replace_cr=""; cited_run=""
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
    --integration-check) integration_check=1; shift ;;
    --receipt-json) receipt_json=1; shift ;;
    --batch) batch="${2-}"; shift 2 ;;
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
v_by=""
[ "$receipt_json" -eq 0 ] || [ "$merge_check" -eq 1 ] || refuse "--receipt-json requires --merge-check"
[ $((check_only + merge_check + integration_check)) -le 1 ] || refuse "--check, --merge-check and --integration-check are separate modes"
if [ "$merge_check" -eq 0 ] && [ "$integration_check" -eq 0 ]; then
  if [ -n "$body" ] && [ -s "$body" ]; then
    vline="$(head -n 1 "$body" | tr -d '\r')"
    vre='^review: APPROVE head: ([0-9a-f]{40}) by: ([A-Za-z0-9._-]+)$'
    if [[ "$vline" =~ $vre ]]; then
      [ "${BASH_REMATCH[1]}" = "$head" ] || refuse "review line head ${BASH_REMATCH[1]} is not --head ${head}"
      v_by="${BASH_REMATCH[2]}"
    else
      refuse "body first line is not a literal review line 'review: APPROVE head: <40hex> by: <keeper>' (got: '${vline:0:120}')"
    fi
  else
    refuse "--body file missing or empty"
  fi
fi
[ ${#reasons[@]} -eq 0 ] || finish_refused

# Freeze caller batch evidence once. Review writes can record this line;
# validation against CI/main/member state belongs to integration and landing.
batch_args=(); batch_line=""
if [ -n "$batch" ]; then
  batch_line=$(python3 -c 'import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); from batch_evidence import parse; print(parse(Path(sys.argv[2]).read_text()).line)' "$here" "$batch") || exit 1
  batch_copy=$(mktemp) || exit 1
  trap 'rm -f "$batch_copy"' EXIT
  printf '%s\n' "$batch_line" > "$batch_copy"
  batch_args=(--batch "$batch_copy")
fi

# Immutable body and final receipt identify the approved head. Existing posted
# integration verdict approvals remain review evidence only; new writes use
# review: APPROVE and cannot mint an integration PASS.
footer_prefix="$(printf 'approve-guard: head \x60%s\x60 · ' "$head")"
approval_head_jq="((.body // \"\" | split(\"\\n\") | (first // \"\")) | test(\"^(review: APPROVE head: ${head} by: [A-Za-z0-9._-]+|verdict: PASS head: ${head} run: [1-9][0-9]* by: [A-Za-z0-9._-]+)\\r?$\")) and ((.body // \"\" | split(\"\\n\") | map(select(length > 0)) | (last // \"\")) | startswith(\"${footer_prefix}\"))"

# Read-only merge approval check. A review's commit_id can follow a later push,
# so only its immutable review body and guard footer authorize this head.
if [ "$merge_check" -eq 1 ]; then
  pr_row="$(gh_json "repos/${repo}/pulls/${pr}" '[.state, (.draft|tostring), .base.ref, .head.sha, (.merged|tostring), .head.ref, (.user.login // "")] | @tsv')" || exit 1
  IFS=$'\t' read -r st draft base cur merged pr_head_ref author <<<"$pr_row"
  [ "$st" = "open" ] && [ "$merged" = false ] || refuse "PR state is '${st}' (merged=${merged})"
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
  [ -n "$approvals" ] || { refuse "no non-author APPROVED review has this head in its review body and guard footer with trusted repository authority"; finish_refused; }
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

# CI preflight is explicitly separate from approval. Merge calls this mode,
# then requires a current integration PASS and a formal independent approval.
if [ "$integration_check" -eq 1 ]; then
  source "$here/ci-checks.sh"
  check_current_ci || exit $?
  v_run="$cited_run"
  if [ -z "$v_run" ]; then
    v_run="$(printf '%s\n' "$wf" | awk -F '\t' '$9=="pull_request" && $10==".github/workflows/pr-check.yml" { print $7; exit }')"
  fi
  [[ "$v_run" =~ ^[1-9][0-9]*$ ]] || refuse "no explicit successful PR-check run for freshness"
  [ ${#reasons[@]} -eq 0 ] || finish_refused
  freshness=$(GUARD_GH="$GH" python3 "$here/ci-freshness.py" --repo "$repo" --pr "$pr" \
    --head "$head" --run "$v_run" --git-dir "$gitdir" ${batch_args[@]+"${batch_args[@]}"})
  fresh_rc=$?
  if [ "$fresh_rc" -ne 0 ]; then
    if [ -n "$batch" ]; then
      printf '%s\n' "$freshness" >&2
      exit "$fresh_rc"
    fi
    [ "$fresh_rc" -ne 1 ] || exit 1
    refuse "CI freshness: $freshness"; finish_refused
  fi
  check_current_ci || exit $?
  if [ -n "$batch" ]; then
    # Live main and all members may change during the final ordinary CI read.
    GUARD_GH="$GH" python3 "$here/ci-freshness.py" --repo "$repo" --pr "$pr" \
      --head "$head" --run "$v_run" --git-dir "$gitdir" ${batch_args[@]+"${batch_args[@]}"} >/dev/null || exit $?
  fi
  echo "INTEGRATION-CHECK PASS #${pr} head ${head} run ${v_run} · dispatch-only skipped:${dispatch_skips} · ignored refused manual Release dispatch run/suite:${ignored_release_run_suites}"
  exit 0
fi

check_review_pr() {
  local row state draft base current merged author
  row="$(gh_json "repos/${repo}/pulls/${pr}" '[.state, (.draft|tostring), .base.ref, .head.sha, (.merged|tostring), (.user.login // "")] | @tsv')" || exit 1
  IFS=$'\t' read -r state draft base current merged author <<<"$row"
  [ "$state" = open ] && [ "$merged" = false ] || refuse "PR state is '${state}' (merged=${merged})"
  [ "$draft" = false ] || refuse "PR is Draft"
  [ "$current" = "$head" ] || refuse "head moved: PR head is ${current}"
  [ -n "$author" ] || { echo "approve-guard: PR author missing from API" >&2; exit 1; }
  [ "$author" != "$me" ] || refuse "PR author ${me} cannot approve their own PR"
}
me="$(gh_json user '.login')" || exit 1
[ -n "$me" ] || { echo "approve-guard: gh api user returned no login" >&2; exit 1; }
[ "$v_by" != "$me" ] || refuse "review line by: is the account login '${me}'; name the Keeper that judged"
check_review_pr

# Only our own shared-account CR can be silently replaced by this APPROVE.
# Other reviewers retain their independent stance; merge refuses their CRs.
check_open_change_requests() {
  local revs who rid rstate
  revs="$(gh_json "repos/${repo}/pulls/${pr}/reviews?per_page=100" '.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED") | [.user.login, (.id|tostring), .state] | @tsv')" || exit 1
  revs="$(printf '%s\n' "$revs" | sort -t "$(printf '\t')" -k1,1 -k2,2nr | awk -F '\t' 'NF && !seen[$1]++')"
  replaced=""
  while IFS=$'\t' read -r who rid rstate; do
    [ "$who" = "$me" ] && [ "$rstate" = CHANGES_REQUESTED ] || continue
    if [ "$rid" = "$replace_cr" ]; then replaced="$rid"
    else refuse "open CHANGES_REQUESTED from ${me} (review ${rid}) is this account's own, and the account is shared: read it, then pass --replace-own-cr ${rid} to replace it"; fi
  done <<<"$revs"
  if [ -n "$replace_cr" ] && [ "$replaced" != "$replace_cr" ]; then
    refuse "--replace-own-cr ${replace_cr} does not name an open CHANGES_REQUESTED from ${me}"
  fi
}
check_open_change_requests
[ ${#reasons[@]} -eq 0 ] || finish_refused
# Latest decisive review only: an older approval cannot hide a later dismissal.
dup_rows="$(gh_json "repos/${repo}/pulls/${pr}/reviews?per_page=100" ".[] | select(.user.login == \"${me}\" and (.state == \"APPROVED\" or .state == \"CHANGES_REQUESTED\" or .state == \"DISMISSED\")) | [(.id|tostring), .state, (($approval_head_jq)|tostring)] | @tsv")" || exit 1
dup="$(printf '%s\n' "$dup_rows" | sort -t "$(printf '\t')" -k1,1nr | awk -F '\t' 'NF { if ($2=="APPROVED" && $3=="true") print $1; exit }')"
# Re-read the live head and shared CR after review reads, including dry runs.
check_review_pr
check_open_change_requests
[ ${#reasons[@]} -eq 0 ] || finish_refused
if [ -n "$dup" ]; then echo "SKIP #${pr}: ${me} already APPROVED ${head} (review ${dup})"; exit 0; fi
if [ "$check_only" -eq 1 ]; then echo "WOULD APPROVE #${pr} head ${head} (source review; CI evaluated at merge)"; exit 0; fi
footer="$(printf '\n\n---\napprove-guard: head `%s` · source review by %s · CI evaluated at merge' "$head" "$v_by")"
[ -z "$replaced" ] || footer="${footer} · replaces own CHANGES_REQUESTED ${replaced}"
if ! resp="$({ cat "$body"; [ -z "$batch_line" ] || printf '\n\n%s\n' "$batch_line"; printf '%s' "$footer"; } | "$GH" api -X POST "repos/${repo}/pulls/${pr}/reviews" \
    -f event=APPROVE -f "commit_id=${head}" -F body=@- \
    --jq '[(.id|tostring), .state, .commit_id] | @tsv' 2>&1)"; then
  echo "approve-guard: POST review failed: $resp" >&2; exit 1
fi
IFS=$'\t' read -r rid rstate rcommit <<<"$resp"
back="$(gh_json "repos/${repo}/pulls/${pr}/reviews/${rid}" '[.state, .commit_id] | @tsv')" || exit 1
IFS=$'\t' read -r bstate bcommit <<<"$back"
if [ "$bstate" != APPROVED ] || [ "$bcommit" != "$head" ]; then
  echo "approve-guard: posted review ${rid} reads back as ${bstate} on ${bcommit}" >&2; exit 1
fi
echo "APPROVED #${pr} head ${head} review ${rid}"
