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
git worktree add -q --detach .worktrees/retry-detached HEAD
(
  cd .worktrees/detached
  echo only-here > only-here.txt
  git add only-here.txt
  git commit -q -m "a commit no branch points at"
)
detached_sha="$(git -C .worktrees/detached rev-parse HEAD)"
(
  cd .worktrees/retry-detached
  echo retry-only-here > retry-only-here.txt
  git add retry-only-here.txt
  git commit -q -m "a detached commit whose first removal is locked"
)
retry_sha="$(git -C .worktrees/retry-detached rev-parse HEAD)"

if [ -n "$(git for-each-ref --contains "${detached_sha}" --format='%(refname)' \
             refs/heads refs/remotes refs/tags)" ] \
   || [ -n "$(git for-each-ref --contains "${retry_sha}" --format='%(refname)' \
                  refs/heads refs/remotes refs/tags)" ]; then
  echo "fixture is wrong: the detached commit is already on a ref" >&2
  exit 1
fi

fail() { echo "$1" >&2; echo "--- script output ---" >&2; echo "${output}" >&2; exit 1; }

output="$(bash scripts/cleanup-stale-worktrees.sh --days 1 2>&1)"
[ -d .worktrees/detached ] || fail "dry-run removed the detached worktree"
[ -d .worktrees/retry-detached ] || fail "dry-run removed the retry worktree"
[ -z "$(git tag -l 'archive/worktree/*')" ] || fail "dry-run created an archive tag"
case "${output}" in
  *"would_archive=2"*) ;;
  *) fail "dry-run summary did not count the two commits it would archive" ;;
esac

git worktree lock .worktrees/retry-detached
output="$(bash scripts/cleanup-stale-worktrees.sh --days 1 --apply 2>&1)"

[ -d .worktrees/on-a-branch ] && fail "the branch worktree was not removed"
[ -d .worktrees/detached ] && fail "the detached worktree was not removed"
[ -d .worktrees/retry-detached ] || fail "the locked worktree should survive its first removal"

tags="$(git tag -l 'archive/worktree/*')"
[ "$(printf '%s\n' "${tags}" | grep -c .)" = "2" ] \
  || fail "expected exactly two archive tags, got: ${tags}"

git worktree unlock .worktrees/retry-detached
retry_output="$(bash scripts/cleanup-stale-worktrees.sh --days 1 --apply 2>&1)"
output="${output}
${retry_output}"
[ -d .worktrees/retry-detached ] && fail "the second run did not retry the archived worktree"

git cat-file -e "${detached_sha}" 2>/dev/null \
  || fail "the detached commit is gone"
[ -n "$(git for-each-ref --contains "${detached_sha}" --format='%(refname)' refs/tags)" ] \
  || fail "the detached commit is on no ref, so removal lost it"
git cat-file -e "${retry_sha}" 2>/dev/null \
  || fail "the retried detached commit is gone"
[ -n "$(git for-each-ref --contains "${retry_sha}" --format='%(refname)' refs/tags)" ] \
  || fail "the retried commit is on no ref, so removal lost it"

# The branch worktree needs no tag: its commit stays on refs/heads/feature.
[ "$(git rev-parse feature)" = "$(git rev-parse main)" ] \
  || fail "the branch moved, which this script must not do"

case "${output}" in
  *"commit kept at archive/worktree/"*) ;;
  *) fail "the run did not report where it kept the detached commit" ;;
esac

echo "cleanup-stale-worktrees: dry-run counts archives and removal retries an existing tag"
