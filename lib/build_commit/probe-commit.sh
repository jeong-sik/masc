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

# The working tree's change set against HEAD: the tracked diff, untracked
# regular files (paths and raw blob ids), untracked symlinks (paths and link
# targets), and untracked nested repositories (paths and recursive state),
# hashed as one blob. Prefixes, renames and colour are pinned so the user's
# diff configuration cannot change the bytes. Untracked symlinks (including
# directory and broken links, e.g. pnpm node_modules) are read with readlink
# instead of being followed by git hash-object, which would fail with
# "Unable to hash" or hang on non-regular targets. Any failing step gives no
# state rather than a partial one.
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
script_path="$script_dir/$(basename -- "$0")"

probe_tree_digest() (
  repo_top=$1
  base_ref=$2
  existing_untracked=${3:-}
  workdir=$(mktemp -d) || exit 1
  workdir=$(cd -- "$workdir" && pwd -P) || { rm -rf -- "$workdir"; exit 1; }
  trap 'rm -rf -- "$workdir"' EXIT
  trap 'rm -rf -- "$workdir"; exit 1' HUP INT TERM
  if [ -n "$existing_untracked" ]; then
    untracked="$existing_untracked"
  else
    untracked="$workdir/untracked"
    git -C "$repo_top" ls-files -z --others --exclude-standard >"$untracked" || exit 1
  fi
  diff_file="$workdir/diff"
  regfiles="$workdir/regfiles"
  reghashes="$workdir/reghashes"
  links="$workdir/links"
  dirs="$workdir/dirs"
  dirhashes="$workdir/dirhashes"
  changes="$workdir/changes"
  : >"$regfiles" || exit 1
  : >"$reghashes" || exit 1
  : >"$links" || exit 1
  : >"$dirs" || exit 1
  : >"$dirhashes" || exit 1
  git -C "$repo_top" diff --binary --no-color --no-ext-diff --no-textconv \
    --no-renames --src-prefix=a/ --dst-prefix=b/ "$base_ref" -- >"$diff_file" || exit 1
  diff_digest=$(git -C "$repo_top" hash-object --no-filters -- "$diff_file") || exit 1
  if [ -s "$untracked" ]; then
    (
      cd -- "$repo_top" || exit 1
      xargs -0 sh -c '
        reg=$1 links=$2 dirs=$3
        shift 3
        exec 3>>"$reg" 4>>"$links" 5>>"$dirs"
        for p do
          if [ -L "./$p" ]; then
            printf "L\000%s\000" "$p" >&4 || exit 255
            readlink -n "./$p" >&4 || exit 255
            printf "\000" >&4 || exit 255
          elif [ -f "./$p" ]; then
            printf "%s\000" "$p" >&3 || exit 255
          elif [ -d "./$p" ]; then
            printf "%s\000" "$p" >&5 || exit 255
          else
            exit 255
          fi
        done
      ' _ "$regfiles" "$links" "$dirs" <"$untracked"
    ) || exit 1
    if [ -s "$regfiles" ]; then
      (cd -- "$repo_top" && xargs -0 git hash-object --no-filters -- <"$regfiles") >"$reghashes" || exit 1
    fi
    if [ -s "$dirs" ]; then
      xargs -0 sh "$script_path" --probe-nested "$repo_top" <"$dirs" >"$dirhashes" || exit 1
    fi
  fi
  regfiles_digest=$(git -C "$repo_top" hash-object --no-filters -- "$regfiles") || exit 1
  reghashes_digest=$(git -C "$repo_top" hash-object --no-filters -- "$reghashes") || exit 1
  links_digest=$(git -C "$repo_top" hash-object --no-filters -- "$links") || exit 1
  dirhashes_digest=$(git -C "$repo_top" hash-object --no-filters -- "$dirhashes") || exit 1
  printf 'diff %s\nreg-paths %s\nreg-blobs %s\nlinks %s\ndirs %s\n' \
    "$diff_digest" "$regfiles_digest" "$reghashes_digest" "$links_digest" "$dirhashes_digest" >"$changes" || exit 1
  git -C "$repo_top" hash-object --no-filters -- "$changes"
)

if [ "${1:-}" = "--probe-nested" ]; then
  [ "$#" -ge 2 ] || exit 255
  parent_top=$2
  shift 2
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
        GIT_NAMESPACE GIT_GRAFT_FILE GIT_SHALLOW_FILE \
        GIT_PREFIX GIT_IMPLICIT_WORK_TREE GIT_SUPER_PREFIX \
        GIT_DIFF_OPTS GIT_EXTERNAL_DIFF GIT_EXTERNAL_DIFF_TRUST_EXIT_CODE
  export GIT_OPTIONAL_LOCKS=0
  for p do
    nested_top=$(GIT_CEILING_DIRECTORIES="$parent_top" git -C "$parent_top/$p" rev-parse --show-toplevel 2>/dev/null) || exit 255
    nested_top=$(cd -- "$nested_top" && pwd -P) || exit 255
    [ -n "$nested_top" ] && [ "$nested_top" != "$parent_top" ] || exit 255
    if nested_head=$(GIT_CEILING_DIRECTORIES="$parent_top" git -C "$nested_top" rev-parse --verify HEAD 2>/dev/null); then
      nested_digest=$(probe_tree_digest "$nested_top" "$nested_head") || exit 255
      printf 'D\000%s\000H\000%s\000%s\000' "$p" "$nested_head" "$nested_digest" || exit 255
    else
      GIT_CEILING_DIRECTORIES="$parent_top" git -C "$nested_top" symbolic-ref -q HEAD >/dev/null 2>&1 || exit 255
      nested_empty=$(GIT_CEILING_DIRECTORIES="$parent_top" git -C "$nested_top" hash-object -t tree /dev/null) || exit 255
      nested_digest=$(probe_tree_digest "$nested_top" "$nested_empty") || exit 255
      printf 'D\000%s\000U\000%s\000' "$p" "$nested_digest" || exit 255
    fi
  done
  exit 0
fi

probe_source_state() (
  unset GIT_DIFF_OPTS GIT_EXTERNAL_DIFF GIT_EXTERNAL_DIFF_TRUST_EXIT_CODE
  export GIT_OPTIONAL_LOCKS=0
  top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 1
  top=$(cd -- "$top" && pwd -P) || exit 1
  git -C "$top" diff --quiet --no-ext-diff --no-textconv HEAD -- >/dev/null 2>&1
  tracked=$?
  [ "$tracked" -le 1 ] || exit 1
  workdir=$(mktemp -d) || exit 1
  workdir=$(cd -- "$workdir" && pwd -P) || { rm -rf -- "$workdir"; exit 1; }
  trap 'rm -rf -- "$workdir"' EXIT
  trap 'rm -rf -- "$workdir"; exit 1' HUP INT TERM
  untracked="$workdir/untracked"
  git -C "$top" ls-files -z --others --exclude-standard >"$untracked" || exit 1
  if [ "$tracked" -eq 0 ] && [ ! -s "$untracked" ]; then
    printf 'clean'
    exit 0
  fi
  digest=$(probe_tree_digest "$top" HEAD "$untracked") || exit 1
  printf 'modified:%s' "$digest"
)

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
