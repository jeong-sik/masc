#!/usr/bin/env bash
# Approve source-reviewed stack heads; release heads also require full CI.
set -euo pipefail
GH="${GUARD_GH:-gh}"
here="$(cd "$(dirname "$0")" && pwd)"
repo=""; pr=""; head=""; body=""; run=""; replace_cr=""
review_base=""; review_diff=""
check_only=0; merge_check=0; receipt_json=0; print_footer=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--pr|--head|--body|--run|--replace-own-cr|--review-base|--review-diff)
      [ $# -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || { echo "$1 requires a value" >&2; exit 1; };;
  esac
  case "$1" in
    --repo) repo="$2"; shift 2;; --pr) pr="$2"; shift 2;;
    --head) head="$2"; shift 2;; --body) body="$2"; shift 2;;
    --run) run="$2"; shift 2;; --replace-own-cr) replace_cr="$2"; shift 2;;
    --review-base) review_base="$2"; shift 2;; --review-diff) review_diff="$2"; shift 2;;
    --check) check_only=1; shift;; --merge-check) merge_check=1; shift;;
    --receipt-json) receipt_json=1; shift;; --print-footer) print_footer=1; shift;;
    *) echo "approve-guard: unknown argument $1" >&2; exit 1;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$pr" =~ ^[1-9][0-9]*$ && "$head" =~ ^[0-9a-f]{40}$ ]] || exit 2
[ -z "$run" ] || [[ "$run" =~ ^[1-9][0-9]*$ ]] || exit 2
[ -z "$replace_cr" ] || [[ "$replace_cr" =~ ^[1-9][0-9]*$ ]] || exit 2
[ "$check_only" -eq 0 ] || [ "$merge_check" -eq 0 ] || exit 2
[ "$receipt_json" -eq 0 ] || [ "$merge_check" -eq 1 ] || exit 2
# Read-only helper mode: print the exact footer tail a reviewer should append,
# computed from the PR's live base/head. Mutually exclusive with every mode.
[ "$print_footer" -eq 0 ] || { [ "$check_only" -eq 0 ] && [ "$merge_check" -eq 0 ] && [ -z "$body" ] && [ -z "$run" ] && [ -z "$replace_cr" ] && [ -z "$review_base" ] && [ -z "$review_diff" ]; } || exit 2
source "$here/ci-checks.sh"
source "$here/review-verdict.sh"
# Read-only helper: print the exact footer line a reviewer should append,
# computed from the PR's live base/head. Posts nothing and approves nothing.
if [ "$print_footer" -eq 1 ]; then
  read_current_pr || exit $?
  current_diff=$(python3 "$here/review-diff.py" --repo "$repo" --base "$pr_base_sha" --head "$head") || exit 1
  printf 'approve-guard: head `%s` · %s review · reviewed base `%s` · diff sha256 `%s`\n' \
    "$head" "$review_policy" "$pr_base_sha" "$current_diff"
  exit 0
fi
refuse() { echo "REFUSED #$pr head $head: $*" >&2; exit 2; }
# Diagnostic detail for refusals: one line per failed test, never consulted for admission.
refusal_detail=""
refused_scope_reviews=""
check_review_scope() {
  printf '%s' "$1" |
    python3 "$here/review-scope.py" --repo "$repo" --head "$head" \
      --base-ref "$pr_base" --base-sha "$pr_base_sha" --stack "$pr_stack" --gh "$GH"
}
emit_refusal_detail() {
  local review_json scope_status rid who
  [ -z "$refusal_detail" ] || printf '%s' "$refusal_detail" >&2
  # A malformed footer cannot authorize a review, but it must not hide an
  # independent scope failure. Defer any scope comparison API calls until
  # admission actually refuses, and reuse the review JSON already read.
  while IFS= read -r review_json; do
    [ -n "$review_json" ] || continue
    scope_status=0
    check_review_scope "$review_json" || scope_status=$?
    [ "$scope_status" -ne 0 ] || continue
    rid=$(printf '%s' "$review_json" | jq -r '.id')
    who=$(printf '%s' "$review_json" | jq -r '.user.login')
    if [ "$scope_status" -eq 2 ]; then
      printf '  review %s by %s: review-scope stamp does not match this PR base/stack (expected review-scope: %s)\n' "$rid" "$who" "$(compute_scope)" >&2
    else
      printf '  review %s by %s: review-scope could not be verified\n' "$rid" "$who" >&2
    fi
  done <<<"$refused_scope_reviews"
}
refuse_detail() {
  echo "REFUSED #$pr head $head: $*" >&2
  emit_refusal_detail
  exit 2
}
compute_scope() {
  python3 -c 'import json,sys; s=json.loads(sys.argv[3]); print(json.dumps({"base_ref":sys.argv[1],"base_sha":sys.argv[2],"stack":None if s is None else {"number":s["number"],"position":s["position"],"base_ref":s["base"]["ref"]}},separators=(",",":")))' "$pr_base" "$pr_base_sha" "$pr_stack"
}
read_current_pr
current_diff=$(python3 "$here/review-diff.py" --repo "$repo" --base "$pr_base_sha" --head "$head") || refuse "complete review diff unavailable"
# Merge admission must establish the policy-specific CI identity before
# review verdicts are parsed. Release verdicts are bound to this selected run;
# checking reviews first would leave release_run empty and admit another run.
if [ "$merge_check" -eq 1 ]; then
  check_current_ci
fi
# Read-only candidate admission uses repository review evidence; Actions
# installation tokens cannot query /user. Review/check paths still require
# the caller identity for self-approval and owned change-request rules.
me=""
if [ "$merge_check" -eq 0 ]; then
  me=$(ci_gh_json user '.login')
  [ -n "$me" ] || exit 1
fi
# Neither GitHub commit_id nor a footer alone supplies immutable head binding.
# review-refusal.py is the single admission test; it prints the review id when
# admitted and the failed tests otherwise (exit 1).
admit_review() {
  printf '%s' "$1" | python3 "$here/review-refusal.py" --head "$head" --policy "$review_policy" \
    --base-sha "$pr_base_sha" --current-diff "$current_diff" --release-run "${release_run:-}"
}
review_rows() {
  ci_gh_json "repos/$repo/pulls/$pr/reviews?per_page=100" '.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED") | [.user.login, (.id|tostring), .state] | @tsv' |
    sort -t "$(printf '\t')" -k1,1 -k2,2nr | awk -F '\t' 'NF && !seen[$1]++'
}
check_reviews() {
  local rows who rid state bound scope_status review_json admit_status
  rows=$(review_rows) || return 1
  approvals=""; replaced=""; own_approval=""; refusal_detail=""; refused_scope_reviews=""
  while IFS=$'\t' read -r who rid state; do
    [ -n "$who" ] || continue
    if [ "$state" = CHANGES_REQUESTED ]; then
      if [ "$merge_check" -eq 0 ] && [ "$who" = "$me" ] && [ "$rid" = "$replace_cr" ]; then replaced="$rid"
      else refuse "open CHANGES_REQUESTED from $who (review $rid)"; fi
    fi
    if [ "$state" = APPROVED ] && [ "$who" != "$pr_author" ]; then
      review_json=$(ci_gh_json "repos/$repo/pulls/$pr/reviews/$rid" '.') || return 1
      admit_status=0
      bound=$(admit_review "$review_json") || admit_status=$?
      [ "$admit_status" -le 1 ] || return 1
      if [ "$admit_status" -eq 1 ]; then
        refusal_detail="$refusal_detail  review $rid by $who: not admitted
$(printf '%s\n' "$bound" | sed 's/^/    - /')
"
        bound=""
        refused_scope_reviews="$refused_scope_reviews$(printf '%s' "$review_json" | jq -c .)
"
      fi
      if [ -n "$bound" ]; then
        scope_status=0
        check_review_scope "$review_json" || scope_status=$?
        if [ "$scope_status" -eq 2 ]; then
          refusal_detail="$refusal_detail  review $rid by $who: footer is bound, but its review-scope stamp does not match this PR base/stack (expected review-scope: $(compute_scope))
"
          continue
        fi
        [ "$scope_status" -eq 0 ] || return 1
        approvals="$approvals $bound"
        [ "$who" != "$me" ] || own_approval="$bound"
      fi
    fi
  done <<<"$rows"
  [ -z "$replace_cr" ] || [ "$replaced" = "$replace_cr" ] || refuse "--replace-own-cr does not name this account's open request"
}
check_verdict() {
  local value state cited by
  value=$(verdict_for "$pr" "$head") || return 1
  read -r state cited by <<<"$value"
  if [ -n "$state" ] && [ "$state" != PASS ]; then
    [ -n "$approvals" ] || emit_refusal_detail
    refuse "latest structured verdict is $state"
  fi
  if [ "$state" = PASS ] && [ "$review_policy" = source ] && [ "$cited" != - ]; then
    [ -n "$approvals" ] || emit_refusal_detail
    refuse "source verdict must not cite a CI run (cited $cited)"
  fi
  if [ "$state" = PASS ] && [ "$review_policy" = release ] && [ "$cited" != "$release_run" ]; then
    [ -n "$approvals" ] || emit_refusal_detail
    refuse "release verdict cites run $cited, admitted run is $release_run"
  fi
}
check_reviews
check_verdict
if [ "$merge_check" -eq 1 ]; then
  [ -n "$approvals" ] || refuse_detail "no trusted non-author approval bound to this head and complete diff"
  read_current_pr
  check_reviews
  [ -n "$approvals" ] || refuse "approval changed during merge check"
  check_verdict
  final_diff=$(python3 "$here/review-diff.py" --repo "$repo" --base "$pr_base_sha" --head "$head") ||
    refuse "complete diff unavailable at consumption"
  [ "$current_diff" = "$final_diff" ] || refuse "complete diff moved during consumption"
  read_current_pr
  check_reviews
  [ -n "$approvals" ] || refuse "approval changed after final diff read"
  check_verdict
  if [ "$receipt_json" -eq 1 ]; then
    python3 -c 'import json,sys; print(json.dumps({"pr":int(sys.argv[1]),"head":sys.argv[2],"approval_ids":[int(x) for x in sys.argv[3].split()]}))' "$pr" "$head" "$approvals"
  else echo "MERGE-CHECK PASS #$pr head $head approvals:$approvals"; fi
  exit 0
fi
check_current_ci
if [ "$check_only" -eq 0 ]; then
  [[ "$review_base" =~ ^[0-9a-f]{40}$ && "$review_diff" =~ ^[0-9a-f]{64}$ ]] ||
    refuse "supply the base and complete diff identity captured during source review (--review-base/--review-diff)"
  declared_diff=$(python3 "$here/review-diff.py" --repo "$repo" --base "$review_base" --head "$head") ||
    refuse "reviewed base diff unavailable"
  [ "$declared_diff" = "$review_diff" ] && [ "$current_diff" = "$review_diff" ] ||
    refuse "current complete diff differs from the reviewed change"
  [ "$me" != "$pr_author" ] || refuse "the PR author cannot approve their own change"
  [ -s "$body" ] || refuse "review body missing or empty"
  review_body=$(cat "$body")
  vline=${review_body%%$'\n'*}
  vline=${vline//$'\r'/}
  if [ "$review_policy" = source ]; then
    pattern='^verdict: PASS head: ([0-9a-f]{40}) by: ([A-Za-z0-9._-]+)$'
    [[ "$vline" =~ $pattern ]] || refuse "source review requires a runless exact-head verdict"
    [ "${BASH_REMATCH[1]}" = "$head" ] || refuse "verdict names another head"
    keeper="${BASH_REMATCH[2]}"
  else
    pattern='^verdict: PASS head: ([0-9a-f]{40}) run: ([1-9][0-9]*) by: ([A-Za-z0-9._-]+)$'
    [[ "$vline" =~ $pattern ]] || refuse "release verdict requires exact-head CI evidence"
    [ "${BASH_REMATCH[1]}" = "$head" ] && [ "${BASH_REMATCH[2]}" = "$release_run" ] || refuse "release verdict names another head or run"
    keeper="${BASH_REMATCH[3]}"
    # The final release snapshot must admit the same run the frozen body cites.
    run="${BASH_REMATCH[2]}"
  fi
  [ "$keeper" != "$me" ] || refuse "by must name the reviewing Keeper"
fi
check_current_ci
check_reviews
check_verdict
read_current_pr
final_diff=$(python3 "$here/review-diff.py" --repo "$repo" --base "$pr_base_sha" --head "$head") ||
  refuse "complete diff unavailable at approval"
[ "$current_diff" = "$final_diff" ] || refuse "complete diff moved during approval"
# The compare/fetch above can block while the PR is retargeted. Revalidate the
# producer identity after all network-dependent diff work, before any POST.
read_current_pr
check_reviews
check_verdict
if [ "$check_only" -eq 1 ]; then echo "WOULD APPROVE #$pr head $head policy $review_policy"; exit 0; fi
# Bind the reviewed base and native stack position to the approval itself.
# Main may advance later when the reviewed diff base remains identical.
scope=$(compute_scope)
footer=$(printf '\n\n---\nreview-scope: %s\napprove-guard: head `%s` · %s review' "$scope" "$head" "$review_policy")
if [ -n "$own_approval" ]; then
  previous_scope=$(ci_gh_json "repos/$repo/pulls/$pr/reviews/$own_approval" '.body | split("\n") | map(select(startswith("review-scope: "))) | if length == 1 then .[0] else "" end')
  if [ "$previous_scope" = "review-scope: $scope" ]; then
    echo "SKIP #$pr: $me already APPROVED this head and scope (review $own_approval)"
    exit 0
  fi
fi
[ -z "$release_run" ] || footer="$footer · release run $release_run"
[ -z "$replaced" ] || footer="$footer · replaces own CHANGES_REQUESTED $replaced"
footer="$footer$(printf ' · reviewed base `%s` · diff sha256 `%s`' "$review_base" "$review_diff")"
response=$( { printf '%s' "$review_body"; printf '%s' "$footer"; } | "$GH" api -X POST "repos/$repo/pulls/$pr/reviews" -f event=APPROVE -f "commit_id=$head" -F body=@- --jq '[(.id|tostring), .state, .commit_id] | @tsv')
IFS=$'\t' read -r rid state commit <<<"$response"
back_json=$(ci_gh_json "repos/$repo/pulls/$pr/reviews/$rid" '.')
admit_review "$back_json" >/dev/null || { echo "approval readback is not admitted for this head" >&2; exit 1; }
back=$(printf '%s' "$back_json" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["state"]+"\t"+r["commit_id"])')
[ "$back" = "$(printf 'APPROVED\t%s' "$head")" ] || { echo "approval readback differs from submitted head" >&2; exit 1; }
echo "APPROVED #$pr head $head review $rid"
