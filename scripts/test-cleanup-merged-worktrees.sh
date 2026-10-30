#!/usr/bin/env bash
# Three things a merged-worktree cleanup pass must do. It finds a branch that
# is merged by fast-forward even while a worktree has it checked out, which
# `git branch` marks with `+`. And one locked worktree costs the pass only
# itself: the pass skips it and still removes the merged worktrees after it.
# A lock whose holder pid is already dead is stale, not held: the pass drops
# the lock file and removes that worktree instead of skipping it forever.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

mkdir -p "${fixture}/repo/scripts/lib" "${fixture}/bin"
cp "${SCRIPT_DIR}/cleanup-merged-worktrees.sh" "${fixture}/repo/scripts/"
cp "${SCRIPT_DIR}/lib/worktree-cleanup-guards.sh" "${fixture}/repo/scripts/lib/"

# The script asks GitHub for squash-merged branches and tolerates a failure.
# A stub keeps this test off the network and off the developer's gh login.
printf '#!/bin/sh\nexit 1\n' > "${fixture}/bin/gh"
chmod +x "${fixture}/bin/gh"
export PATH="${fixture}/bin:${PATH}"

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
# No global config and no init template: a developer's own hooks must not run
# inside the fixture, and its result must not depend on their git settings.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

git init -q --bare -b main "${fixture}/origin.git"
cd "${fixture}/repo"
git init -q -b main --template= .
git remote add origin "${fixture}/origin.git"
echo seed > seed.txt
git add seed.txt scripts
git commit -q -m seed
git push -q origin main

# All branches sit on main's commit, so all count as merged. The script
# visits merged branches in name order, so the locked one comes first.
git branch a-locked
git branch b-free
git branch c-stale
git worktree add -q .worktrees/a-locked a-locked
git worktree add -q .worktrees/b-free b-free
git worktree add -q .worktrees/c-stale c-stale
echo "held-by-test $$" > .worktrees/a-locked/.masc-lock

# A stale lock: this pid is reaped before the script runs, so the lock guard
# reports unlocked while the lock file still blocks `git worktree remove`.
# The loop guards against immediate pid reuse.
dead_pid=""
for _try in 1 2 3 4 5; do
  (exit 0) & dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  kill -0 "$dead_pid" 2>/dev/null || break
  dead_pid=""
done
[ -n "$dead_pid" ] || { echo "could not mint a dead pid" >&2; exit 1; }
echo "held-by-test $dead_pid" > .worktrees/c-stale/.masc-lock

fail() { echo "$1" >&2; echo "--- script output ---" >&2; echo "${output}" >&2; exit 1; }

output="$(bash scripts/cleanup-merged-worktrees.sh 2>&1)" \
  || fail "the dry run stopped with a non-zero status"
case "${output}" in
  *"LOCKED"*"a-locked"*) ;;
  *) fail "the dry run did not find a merged branch checked out in a worktree" ;;
esac
case "${output}" in
  *"CANDID"*"b-free"*) ;;
  *) fail "the dry run did not go on to the worktree after the locked one" ;;
esac
case "${output}" in
  *"CANDID"*"c-stale"*) ;;
  *) fail "the dry run did not list the stale-lock worktree as a candidate" ;;
esac
[ -d .worktrees/a-locked ] && [ -d .worktrees/b-free ] && [ -d .worktrees/c-stale ] \
  || fail "the dry run removed a worktree"

output="$(bash scripts/cleanup-merged-worktrees.sh --apply 2>&1)" \
  || fail "the apply run stopped with a non-zero status"
[ -d .worktrees/a-locked ] || fail "the locked worktree was removed"
[ -d .worktrees/b-free ] && fail "the worktree after the locked one was not removed"
[ -d .worktrees/c-stale ] && fail "the stale-lock worktree was not removed"
case "${output}" in
  *"stale lock dropped"*) ;;
  *) fail "the apply run did not report dropping the stale lock" ;;
esac
git rev-parse -q --verify refs/heads/a-locked >/dev/null \
  || fail "the locked worktree's branch is gone"

echo "cleanup-merged-worktrees: finds worktree branches, a locked worktree is skipped while the pass continues, and a stale lock is dropped and retried"
