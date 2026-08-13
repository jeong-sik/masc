#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git init --bare "$TMP/origin.git" >/dev/null
git init -b main "$TMP/repo" >/dev/null
git -C "$TMP/repo" config user.email test@example.com
git -C "$TMP/repo" config user.name "Test User"
git -C "$TMP/repo" -c core.hooksPath=/dev/null commit --allow-empty -m initial >/dev/null
git -C "$TMP/repo" remote add origin "$TMP/origin.git"
git -C "$TMP/repo" push -u origin main >/dev/null

# Merged cleanup: a live .masc-lock must reach the guard without the historical
# top-level [local] error and must preserve the worktree.
git -C "$TMP/repo" branch merged-lock
git -C "$TMP/repo" worktree add "$TMP/merged-lock" merged-lock >/dev/null
printf 'test-holder %s\n' "$$" > "$TMP/merged-lock/.masc-lock"
merged_output="$(cd "$TMP/repo" && bash "$ROOT/scripts/cleanup-merged-worktrees.sh" --apply)"
grep -E 'LOCKED .*/merged-lock ' <<< "$merged_output" >/dev/null
test -d "$TMP/merged-lock"

# Stale cleanup has the same lock invariant. The old commit date makes this
# branch eligible without sleeping or changing the system clock.
git -C "$TMP/repo" checkout --orphan stale-lock >/dev/null
GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' \
GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
  git -C "$TMP/repo" -c core.hooksPath=/dev/null commit --allow-empty -m stale >/dev/null
git -C "$TMP/repo" checkout main >/dev/null
git -C "$TMP/repo" worktree add "$TMP/stale-lock" stale-lock >/dev/null
printf 'test-holder %s\n' "$$" > "$TMP/stale-lock/.masc-lock"
stale_output="$(cd "$TMP/repo" && bash "$ROOT/scripts/cleanup-stale-worktrees.sh" --days 1 --apply)"
grep -E 'LOCKED  .*/stale-lock ' <<< "$stale_output" >/dev/null
test -d "$TMP/stale-lock"

echo "worktree cleanup live-lock guards: OK"
