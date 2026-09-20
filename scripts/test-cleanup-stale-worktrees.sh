#!/usr/bin/env bash
# What a stale-worktree removal is allowed to destroy: the directory, never a
# commit. A branch worktree keeps its commit on the branch. A detached one has
# no branch, so the script tags the commit before the directory goes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

mkdir -p "${fixture}/repo/scripts/lib"
cp "${SCRIPT_DIR}/cleanup-stale-worktrees.sh" "${fixture}/repo/scripts/"
cp "${SCRIPT_DIR}/lib/worktree-cleanup-guards.sh" "${fixture}/repo/scripts/lib/"

cd "${fixture}/repo"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
# Old enough that every worktree below is past the threshold the run uses.
export GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z'

# No global config and no init template: a developer's own hooks must not run
# inside the fixture, and its result must not depend on their git settings.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git init -q -b main --template= .
echo seed > seed.txt
git add seed.txt scripts
git commit -q -m seed

git branch -q feature
git worktree add -q .worktrees/on-a-branch feature
git worktree add -q --detach .worktrees/detached HEAD
(
  cd .worktrees/detached
  echo only-here > only-here.txt
  git add only-here.txt
  git commit -q -m "a commit no branch points at"
)
detached_sha="$(git -C .worktrees/detached rev-parse HEAD)"

if [ -n "$(git for-each-ref --contains "${detached_sha}" --format='%(refname)' \
             refs/heads refs/remotes refs/tags)" ]; then
  echo "fixture is wrong: the detached commit is already on a ref" >&2
  exit 1
fi

output="$(bash scripts/cleanup-stale-worktrees.sh --days 1 --apply 2>&1)"

fail() { echo "$1" >&2; echo "--- script output ---" >&2; echo "${output}" >&2; exit 1; }

[ -d .worktrees/on-a-branch ] && fail "the branch worktree was not removed"
[ -d .worktrees/detached ] && fail "the detached worktree was not removed"

tags="$(git tag -l 'archive/worktree/*')"
[ "$(printf '%s\n' "${tags}" | grep -c .)" = "1" ] \
  || fail "expected exactly one archive tag, got: ${tags}"

git cat-file -e "${detached_sha}" 2>/dev/null \
  || fail "the detached commit is gone"
[ -n "$(git for-each-ref --contains "${detached_sha}" --format='%(refname)' refs/tags)" ] \
  || fail "the detached commit is on no ref, so removal lost it"

# The branch worktree needs no tag: its commit stays on refs/heads/feature.
[ "$(git rev-parse feature)" = "$(git rev-parse main)" ] \
  || fail "the branch moved, which this script must not do"

case "${output}" in
  *"commit kept at archive/worktree/"*) ;;
  *) fail "the run did not report where it kept the detached commit" ;;
esac

echo "cleanup-stale-worktrees: a removal keeps every commit (branch on its branch, detached on a tag)"
