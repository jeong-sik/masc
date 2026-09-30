#!/usr/bin/env bash
# Keeper merge entry; external coding sessions use --check only.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
GH="${GUARD_GH:-gh}"
repo=""; pr=""; head=""; run=""; check=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--pr|--head|--run) [ $# -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || exit 1;;
  esac
  case "$1" in
    --repo) repo="$2"; shift 2;; --pr) pr="$2"; shift 2;;
    --head) head="$2"; shift 2;; --run) run="$2"; shift 2;;
    --check) check=1; shift;; *) echo "merge-guard: unknown argument $1" >&2; exit 1;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$pr" =~ ^[1-9][0-9]*$ && "$head" =~ ^[0-9a-f]{40}$ ]] || exit 2
[ -z "$run" ] || [[ "$run" =~ ^[1-9][0-9]*$ ]] || exit 2
source "$here/ci-checks.sh"
source "$here/review-verdict.sh"
check_verdict() {
  local value state cited by
  value=$(verdict_for "$pr" "$head") || return 1
  read -r state cited by <<<"$value"
  if [ "$state" != PASS ] || { [ "$review_policy" = source ] && [ "$cited" != - ]; } ||
     { [ "$review_policy" = release ] && [ "$cited" != "$release_run" ]; }; then
    echo "REFUSED #$pr: latest decision is not PASS for this head and review policy" >&2
    return 2
  fi
}
selected_pr="$pr"; selected_head="$head"; selected_run="$run"
snapshot_scope() {
  GUARD_GH="$GH" python3 "$here/stack-scope.py" "$repo" "$selected_pr" "$selected_head"
}
scope=$(snapshot_scope)
native=$(printf '%s' "$scope" | jq -r '.stack != null')
if [ "$native" = false ] && [ "$(printf '%s' "$scope" | jq -r '.scope[0].identity.base.ref')" != main ]; then
  echo "WAITING PARENT #$pr: non-native branch chain; land the parent and retarget to main" >&2
  exit 2
fi
admit_scope() {
  local members
  members=$(printf '%s' "$scope" | jq -r '.scope[] | select(.identity.state == "open") | [.number, .identity.head.sha] | @tsv')
  [ -n "$members" ] || { echo "REFUSED: no open PRs in merge scope" >&2; return 2; }
  while IFS=$'\t' read -r pr head; do
    review_identity=""; run=""
    [ "$pr" != "$selected_pr" ] || run="$selected_run"
    check_current_ci || return $?
    check_verdict || return $?
    GUARD_GH="$GH" bash "$here/approve-guard.sh" --merge-check --repo "$repo" --pr "$pr" --head "$head" || return $?
  done <<<"$members"
}
# Revalidate every included PR, then freeze the same membership and identities.
admit_scope
admit_scope
current_scope=$(snapshot_scope)
if [ "$scope" != "$current_scope" ]; then
  echo "REFUSED: stack membership, PR head, base or identity moved during admission" >&2
  exit 2
fi
members=$(printf '%s' "$scope" | jq -r '[.scope[] | select(.identity.state == "open") | "#" + (.number|tostring)] | join(", ")')
if [ "$check" -eq 1 ]; then
  echo "WOULD MERGE $members through #$selected_pr head $selected_head native_stack=$native"
  exit 0
fi
# GitHub exposes a SHA precondition only for the selected PR, not an all-head
# compare-and-swap. The snapshot is admission evidence, not an atomic guarantee.
response=$("$GH" api -X PUT "repos/$repo/pulls/$selected_pr/merge-async" -f merge_method=squash -f "sha=$selected_head")
printf 'ASYNC MERGE RECEIPT for %s (acceptance is not completion):\n%s\n' "$members" "$response"
