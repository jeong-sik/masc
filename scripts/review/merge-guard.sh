#!/usr/bin/env bash
# Keeper-only merge entry. Coding-agent sessions may use --check, never merge.
# No retries, polling, admin bypass or fallback path. GitHub pins the PR head,
# but its merge API has no expected-main CAS: a main change after our last read
# remains a server-side race until repository enforcement supports that check.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
GH="${GUARD_GH:-gh}"
repo=""; pr=""; head=""; run=""; check=0
gitdir="${GUARD_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2;;
    --pr) pr="$2"; shift 2;;
    --head) head="$2"; shift 2;;
    --run) run="$2"; shift 2;;
    --git-dir) gitdir="$2"; shift 2;;
    --check) check=1; shift;;
    *) echo "merge-guard: unknown argument $1" >&2; exit 1;;
  esac
done
if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$pr" =~ ^[1-9][0-9]*$ &&
        "$head" =~ ^[0-9a-f]{40}$ && "$run" =~ ^[1-9][0-9]*$ ]] || [ ! -d "$gitdir" ]; then
  echo "merge-guard: require --repo owner/name --pr N --head SHA40 --run ID --git-dir DIR" >&2
  exit 2
fi
source "$here/review-verdict.sh"
check_verdict() {
  local verdict state cited by
  verdict=$(verdict_for "$pr" "$head") || return 1
  read -r state cited by <<<"$verdict"
  if [ "$state" != PASS ] || [ "$cited" != "$run" ]; then
    echo "merge-guard: current structured decision is not PASS on the cited run" >&2
    return 2
  fi
}
# Includes current open/head/base, all workflow/checks and open CR checks.
bash "$here/approve-guard.sh" --check --repo "$repo" --pr "$pr" --head "$head" \
  --run "$run" --git-dir "$gitdir"
# Read both comments and reviews after the expensive checks; a later HOLD/FAIL
# or malformed decision cannot inherit an earlier approval.
check_verdict
# Re-read live head/main immediately before the only write below.
python3 "$here/ci-freshness.py" --repo "$repo" --pr "$pr" --head "$head" \
  --run "$run" --git-dir "$gitdir"
# A verdict/CR can arrive while the graph is being read. Refresh these at the
# finishing boundary too; separate reads cannot provide a server-side CAS.
check_verdict
review_state=$("$GH" api --paginate "repos/$repo/pulls/$pr/reviews?per_page=100" \
  --jq "[.[] | select(.state == \"APPROVED\" or .state == \"CHANGES_REQUESTED\" or .state == \"DISMISSED\")] |
    group_by(.user.login) | map(max_by(.id)) |
    if any(.[]; .state == \"CHANGES_REQUESTED\") then \"blocked\"
    elif any(.[]; .state == \"APPROVED\" and .commit_id == \"$head\") then \"approved\"
    else \"unapproved\" end")
if [ "$review_state" != approved ]; then
  echo "merge-guard: current review state is $review_state" >&2
  exit 2
fi
if [ "$check" -eq 1 ]; then
  echo "WOULD MERGE #$pr head $head run $run"
  exit 0
fi
"$GH" api -X PUT "repos/$repo/pulls/$pr/merge-async" \
  -f merge_method=squash -f "sha=$head"
