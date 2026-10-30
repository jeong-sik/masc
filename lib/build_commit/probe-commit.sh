#!/usr/bin/env bash
# Emit build_commit_generated.ml: the commit this binary was built from, and
# when that commit was authored, or None for both when neither is knowable.
#
# RFC-0382 follow-up, "binary unknown" root fix: a copied binary (e.g. the
# launchd deploy at <base>/bin) must testify to its own origin. The dune rule
# that runs this disables sandboxing so git can ascend to the checkout being
# built -- in a worktree that is the worktree HEAD, which is the truth we want.
#
# The environment is the fallback, not the preference: git is asked first, so
# a stale MASC_BUILD_COMMIT in someone's shell cannot relabel a real checkout.
# It exists because scripts/build-linux-release.sh copies only the repo's
# tracked files into its container (`git ls-files`), so /src has no .git at
# all and git there answers nothing. Without this the Linux release binaries
# would embed None and scripts/release-dashboard-bundle.py would refuse to
# package them -- which is what "binary unknown" meant in the first place.
set -uo pipefail

commit="$(git rev-parse HEAD 2>/dev/null || true)"
commit_unix_ts=""

if [ -n "$commit" ]; then
  commit_unix_ts="$(git show -s --format=%ct "$commit" 2>/dev/null || true)"
else
  commit="${MASC_BUILD_COMMIT:-}"
  commit_unix_ts="${MASC_BUILD_COMMIT_UNIX_TS:-}"
  # Accept only a full object name. git's own output is trusted above; an
  # injected value is not, and a half-written one embedded here would reach
  # the dashboard as this binary's identity.
  case "$commit" in
    *[!0-9a-f]*) commit="" ;;
    *) [ "${#commit}" -eq 40 ] || commit="" ;;
  esac
  [ -n "$commit" ] || commit_unix_ts=""
fi

if [ -z "$commit" ]; then
  printf 'let commit : string option = None\n'
  printf 'let commit_unix_ts : int64 option = None\n'
  exit 0
fi

printf 'let commit : string option = Some "%s"\n' "$commit"
case "$commit_unix_ts" in
  '' | *[!0-9]*) printf 'let commit_unix_ts : int64 option = None\n' ;;
  *) printf 'let commit_unix_ts : int64 option = Some %sL\n' "$commit_unix_ts" ;;
esac
