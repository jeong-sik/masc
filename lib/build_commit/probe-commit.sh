#!/bin/sh
# Emit build_commit_generated.ml: the commit this binary was built from, when
# that commit was authored, and the source identity declaration, or None for
# each value that is not knowable.
#
# "binary unknown" root fix: a copied binary (e.g. the
# launchd deploy at <base>/bin) must testify to its own origin. The dune rule
# that runs this disables sandboxing so git can ascend to the checkout being
# built -- in a worktree that is the worktree HEAD, which is the truth we want.
#
# RFC host-and-shim-share-one-build-identity: the server and the exec shim
# link the module this script generates, and the server runs only a shim whose
# declaration equals its own. The declaration is one string literal, so it sits
# verbatim in every binary that links it and a host that cannot run a Linux
# shim can still read it out of the shim's bytes. A commit alone would call two
# builds of one HEAD with different uncommitted edits the same; the state names
# the working tree's change set, or "clean" when there is none.
#
# The environment is the fallback, not the preference: git is asked first, so
# a stale MASC_BUILD_COMMIT in someone's shell cannot relabel a real checkout.
# It exists because the container builds see no checkout:
# scripts/build-linux-release.sh copies only the tracked files (`git ls-files`),
# and scripts/remote-ssh/build-shim.sh builds in a directory outside the
# mounted source. Both compute the values on the host with --print-env and pass
# them in. A commit without a source state gives no identity: an unknown state
# is not "clean".
#
# POSIX sh, not bash: the shim's builder image is Alpine, where this runs
# under the dune rule too.
#
# Usage: probe-commit.sh            the OCaml module, on stdout
#        probe-commit.sh --print-env the MASC_BUILD_* assignments a build
#                                    without git needs; exit 2 when no full
#                                    identity is known
set -u

identity_prefix='MASC_SOURCE_IDENTITY='

# A full git object name: 40 lowercase hex digits (SHA-1) or 64 (SHA-256).
is_object_id() {
  case "$1" in
    '' | *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

is_source_state() {
  case "$1" in
    clean) return 0 ;;
    modified:*) is_object_id "${1#modified:}" ;;
    *) return 1 ;;
  esac
}

# The working tree's change set against HEAD: the tracked diff, the untracked
# paths, and the object ids of those paths, hashed as one blob. Prefixes,
# renames and colour are pinned so the user's diff configuration cannot change
# the bytes. Any failing step gives no state rather than a partial one.
probe_source_state() {
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  git -C "$top" diff --quiet HEAD -- 2>/dev/null
  tracked=$?
  [ "$tracked" -le 1 ] || return 1
  untracked=$(git -C "$top" ls-files --others --exclude-standard) || return 1
  if [ "$tracked" -eq 0 ] && [ -z "$untracked" ]; then
    printf 'clean'
    return 0
  fi
  changes=$(mktemp) || return 1
  if git -C "$top" diff --binary --no-color --no-ext-diff --no-textconv \
       --no-renames --src-prefix=a/ --dst-prefix=b/ HEAD -- >"$changes" \
     && git -C "$top" ls-files -z --others --exclude-standard >>"$changes" \
     && (cd "$top" && git ls-files -z --others --exclude-standard \
           | xargs -0 git hash-object --) >>"$changes" \
     && digest=$(git hash-object --no-filters -- "$changes")
  then
    rm -f "$changes"
    printf 'modified:%s' "$digest"
  else
    rm -f "$changes"
    return 1
  fi
}

commit=$(git rev-parse HEAD 2>/dev/null || true)
commit_unix_ts=""
source_state=""

if [ -n "$commit" ]; then
  commit_unix_ts=$(git show -s --format=%ct "$commit" 2>/dev/null || true)
  source_state=$(probe_source_state || true)
else
  commit="${MASC_BUILD_COMMIT:-}"
  commit_unix_ts="${MASC_BUILD_COMMIT_UNIX_TS:-}"
  source_state="${MASC_BUILD_SOURCE_STATE:-}"
fi

# Accept only a full object name. git's own output is held to the same
# grammar as an injected value: a half-written one embedded here would reach
# the dashboard as this binary's identity.
is_object_id "$commit" || commit=""
[ -n "$commit" ] || commit_unix_ts=""
case "$commit_unix_ts" in
  '' | *[!0-9]*) commit_unix_ts="" ;;
esac
{ [ -n "$commit" ] && is_source_state "$source_state"; } || source_state=""

if [ "${1:-}" = "--print-env" ]; then
  [ -n "$source_state" ] || {
    echo "probe-commit: no source identity: neither git nor MASC_BUILD_COMMIT with MASC_BUILD_SOURCE_STATE names one" >&2
    exit 2
  }
  printf 'MASC_BUILD_COMMIT=%s\n' "$commit"
  printf 'MASC_BUILD_COMMIT_UNIX_TS=%s\n' "$commit_unix_ts"
  printf 'MASC_BUILD_SOURCE_STATE=%s\n' "$source_state"
  exit 0
fi

if [ -n "$commit" ]; then
  printf 'let commit : string option = Some "%s"\n' "$commit"
else
  printf 'let commit : string option = None\n'
fi
if [ -n "$commit_unix_ts" ]; then
  printf 'let commit_unix_ts : int64 option = Some %sL\n' "$commit_unix_ts"
else
  printf 'let commit_unix_ts : int64 option = None\n'
fi
if [ -n "$source_state" ]; then
  printf 'let source_identity_declaration : string option = Some "%s%s/%s;"\n' \
    "$identity_prefix" "$commit" "$source_state"
else
  printf 'let source_identity_declaration : string option = None\n'
fi
