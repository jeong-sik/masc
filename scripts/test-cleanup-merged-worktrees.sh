#!/usr/bin/env bash
# Two things a merged-worktree cleanup pass must do. It finds a branch that
# is merged by fast-forward even while a worktree has it checked out, which
# `git branch` marks with `+`. And one locked worktree costs the pass only
# itself: the pass skips it and still removes the merged worktrees after it.
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

# Both branches sit on main's commit, so both count as merged. The script
# visits merged branches in name order, so the locked one comes first.
git branch a-locked
git branch b-free
git worktree add -q .worktrees/a-locked a-locked
git worktree add -q .worktrees/b-free b-free
echo "held-by-test $$" > .worktrees/a-locked/.masc-lock

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
[ -d .worktrees/a-locked ] && [ -d .worktrees/b-free ] \
  || fail "the dry run removed a worktree"

output="$(bash scripts/cleanup-merged-worktrees.sh --apply 2>&1)" \
  || fail "the apply run stopped with a non-zero status"
[ -d .worktrees/a-locked ] || fail "the locked worktree was removed"
[ -d .worktrees/b-free ] && fail "the worktree after the locked one was not removed"
git rev-parse -q --verify refs/heads/a-locked >/dev/null \
  || fail "the locked worktree's branch is gone"

echo "cleanup-merged-worktrees: finds worktree branches, and a locked worktree is skipped while the pass continues"
