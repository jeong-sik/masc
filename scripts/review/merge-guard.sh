#!/usr/bin/env bash
# Keeper-only merge entry. Coding-agent sessions may use --check, never merge.
# No retries, polling, admin bypass or fallback path. GitHub pins the PR head,
# but its merge API has no expected-main CAS: a main change after our last read
# remains a server-side race until repository enforcement supports that check.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
GH="${GUARD_GH:-gh}"
repo=""; pr=""; head=""; run=""; check=0
gitdir="${GUARD_REPO_ROOT:-}"
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
# An explicit --git-dir works when the caller is outside any worktree.
if [ -z "$gitdir" ]; then
  gitdir="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
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
# Includes current open/head/base and all workflow/checks; review state is separate.
bash "$here/approve-guard.sh" --integration-check --repo "$repo" --pr "$pr" --head "$head" \
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
check_formal_review_state() {
  # Preserve the shared immutable verdict/footer binding and non-author rule;
  # a mutable REST commit_id cannot authorize a later head.
  bash "$here/approve-guard.sh" --merge-check --repo "$repo" --pr "$pr" \
    --head "$head" --git-dir "$gitdir"
}
check_formal_review_state
# A same-head reopen/rerun can register while freshness/reviews are read.
# Repeat the shared workflow AND check gate after those reads. A comment can
# arrive during that gate too, so read the structured decision last. GitHub
# still offers no atomic checks/reviews/main CAS.
source "$here/ci-checks.sh"
check_current_ci
check_verdict
# Formal reviews can change while the final workflow/check API reads run.
check_formal_review_state
if [ "$check" -eq 1 ]; then
  echo "WOULD MERGE #$pr head $head run $run"
  exit 0
fi
"$GH" api -X PUT "repos/$repo/pulls/$pr/merge-async" \
  -f merge_method=squash -f "sha=$head"
