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
check_current_ci
check_verdict
GUARD_GH="$GH" bash "$here/approve-guard.sh" --merge-check --repo "$repo" --pr "$pr" --head "$head"
check_current_ci
check_verdict
GUARD_GH="$GH" bash "$here/approve-guard.sh" --merge-check --repo "$repo" --pr "$pr" --head "$head"
# Pin both the current head and the base observed throughout admission.
read_current_pr
if [ "$pr_base" != main ]; then
  echo "WAITING PARENT #$pr base $pr_base: land the parent and retarget to main" >&2
  exit 2
fi
if [ "$check" -eq 1 ]; then echo "WOULD MERGE #$pr head $head policy $review_policy"; exit 0; fi
"$GH" api -X PUT "repos/$repo/pulls/$pr/merge-async" -f merge_method=squash -f "sha=$head"
