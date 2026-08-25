#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-release-train-guard.sh [--base REF] [--head REF]
EOF
}

base_ref=""
head_ref="HEAD"

while (($# > 0)); do
  case "$1" in
    --base)
      shift
      (($# > 0)) || { usage >&2; exit 1; }
      base_ref="$1"
      ;;
    --head)
      shift
      (($# > 0)) || { usage >&2; exit 1; }
      head_ref="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'release train guard failed: %s\n' "$1" >&2
  exit 1
}

version_from_stream() {
  sed -n 's/^(version \([^)]*\)).*/\1/p' | head -n1
}

version_from_ref() {
  git show "$1:dune-project" 2>/dev/null | version_from_stream
}

major_from_version() {
  printf '%s\n' "${1%%.*}"
}

latest_tag_for_major() {
  local major="$1"
  local tag
  while IFS= read -r tag; do
    if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]]; then
      printf '%s\n' "$tag"
      return 0
    fi
  done < <(git tag --list "v${major}.*" --sort=-v:refname)
}

package_version_from_tag() {
  local tag_version="${1#v}"
  printf '%s\n' "$tag_version" \
    | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)(-[0-9]+)?$/\1/'
}

version_gt() {
  local left="$1"
  local right="$2"
  [[ "$left" != "$right" ]] && [[ "$(printf '%s\n%s\n' "$left" "$right" | sort -V | tail -n1)" == "$left" ]]
}

head_package_version="$(version_from_ref "$head_ref")"
[[ -n "$head_package_version" ]] || fail "missing package version in $head_ref:dune-project"
[[ "$head_package_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "head ref $head_ref uses non-canonical package version $head_package_version; expected X.Y.Z"
head_major="$(major_from_version "$head_package_version")"

if [[ -z "$base_ref" ]]; then
  latest_tag="$(latest_tag_for_major "$head_major")"
  if [[ -z "$latest_tag" ]]; then
    printf 'Release train guard OK: no release tags found for major=%s, head=%s\n' \
      "$head_major" "$head_package_version"
    exit 0
  fi

  latest_tag_version="$(package_version_from_tag "$latest_tag")"
  printf 'Release train guard OK: no base ref provided, head=%s latest_tag_ref=%s latest_tag_version=%s\n' \
    "$head_package_version" "$latest_tag" "$latest_tag_version"
  exit 0
fi

base_package_version="$(version_from_ref "$base_ref")"
[[ -n "$base_package_version" ]] || fail "missing package version in $base_ref:dune-project"
[[ "$base_package_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "base ref $base_ref uses non-canonical package version $base_package_version; expected X.Y.Z"
base_major="$(major_from_version "$base_package_version")"
latest_tag="$(latest_tag_for_major "$base_major")"

if [[ "$head_major" != "$base_major" ]]; then
  if [[ "$base_major" == "0" || "$head_major" != "0" ]]; then
    fail "head ref $head_ref crosses from active package major $base_major to unsupported major $head_major; only a legacy-to-0.x reset is allowed"
  fi
  head_latest_tag="$(latest_tag_for_major "$head_major")"
  if [[ -n "$head_latest_tag" ]]; then
    head_latest_tag_version="$(package_version_from_tag "$head_latest_tag")"
    if version_gt "$head_latest_tag_version" "$head_package_version"; then
      fail "head ref $head_ref uses package version $head_package_version, which is older than latest tag $head_latest_tag in major $head_major (package version $head_latest_tag_version); pick a newer version before crossing release lines"
    fi
  fi
fi

if [[ -z "$latest_tag" ]]; then
  if [[ "$head_package_version" == "$base_package_version" ]]; then
    printf '::warning::Release train: major %s has no published tags yet. Tag v%s when ready.\n' \
      "$base_major" "$base_package_version"
    printf 'Release train guard OK (warn): base=%s head=%s latest_tag=none (bootstrap series)\n' \
      "$base_package_version" "$head_package_version"
    exit 0
  fi

  fail "base ref $base_ref starts bootstrap release line $base_package_version with no published v${base_major}.* tag, and head changes package version to $head_package_version; publish/tag v$base_package_version before widening the release line"
fi

latest_tag_version="$(package_version_from_tag "$latest_tag")"

if [[ "$head_major" == "$base_major" ]] \
  && version_gt "$base_package_version" "$head_package_version"
then
  fail "head ref $head_ref downgrades package version from base $base_package_version to $head_package_version in major $base_major"
fi

if [[ "$base_package_version" == "$latest_tag_version" ]]; then
  printf 'Release train guard OK: base=%s head=%s latest_tag_ref=%s latest_tag_version=%s\n' \
    "$base_package_version" "$head_package_version" "$latest_tag" "$latest_tag_version"
  exit 0
fi

if version_gt "$base_package_version" "$latest_tag_version"; then
  if [[ "$head_package_version" == "$base_package_version" ]]; then
    # PR does not change the package version — allow it through with a warning.
    # The pending release tag is a repo-level concern, not this PR's responsibility.
    printf '::warning::Release train: base %s is ahead of latest tag %s (package version %s). Tag v%s when ready.\n' \
      "$base_package_version" "$latest_tag" "$latest_tag_version" "$base_package_version"
    printf 'Release train guard OK (warn): base=%s head=%s latest_tag_ref=%s latest_tag_version=%s (pending release)\n' \
      "$base_package_version" "$head_package_version" "$latest_tag" "$latest_tag_version"
    exit 0
  fi
  fail "base ref $base_ref advertises unreleased package version $base_package_version while latest tag is $latest_tag (package version $latest_tag_version), and head changes package version to $head_package_version; publish/tag v$base_package_version before widening the release train"
fi

if [[ "$head_package_version" == "$latest_tag_version" ]]; then
  printf 'Release train guard OK (repair): base=%s head=%s latest_tag_ref=%s latest_tag_version=%s\n' \
    "$base_package_version" "$head_package_version" "$latest_tag" "$latest_tag_version"
  exit 0
fi

fail "base ref $base_ref has package version $base_package_version, which is older than latest tag $latest_tag (package version $latest_tag_version); sync version truth before merging"
