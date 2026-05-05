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
  git tag --list "v${major}.*" --sort=-v:refname | head -n1
}

package_version_from_tag() {
  local tag_version="${1#v}"
  printf '%s\n' "$tag_version" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)([-+].*)?$/\1/'
}

version_gt() {
  local left="$1"
  local right="$2"
  [[ "$left" != "$right" ]] && [[ "$(printf '%s\n%s\n' "$left" "$right" | sort -V | tail -n1)" == "$left" ]]
}

head_package_version="$(version_from_ref "$head_ref")"
[[ -n "$head_package_version" ]] || fail "missing package version in $head_ref:dune-project"
head_major="$(major_from_version "$head_package_version")"

if [[ -z "$base_ref" ]]; then
  latest_tag="$(latest_tag_for_major "$head_major")"
  if [[ -z "$latest_tag" ]]; then
    printf 'Release train guard OK: no release tags found for major=%s, head=%s\n' \
      "$head_major" "$head_package_version"
    exit 0
  fi

  latest_tag_version="$(package_version_from_tag "$latest_tag")"
  printf 'Release train guard OK: no base ref provided, head=%s latest_tag=%s\n' \
    "$head_package_version" "$latest_tag_version"
  exit 0
fi

base_package_version="$(version_from_ref "$base_ref")"
[[ -n "$base_package_version" ]] || fail "missing package version in $base_ref:dune-project"
base_major="$(major_from_version "$base_package_version")"
latest_tag="$(latest_tag_for_major "$base_major")"

if [[ "$head_major" != "$base_major" ]]; then
  head_latest_tag="$(latest_tag_for_major "$head_major")"
  if [[ -n "$head_latest_tag" ]]; then
    head_latest_tag_version="$(package_version_from_tag "$head_latest_tag")"
    if version_gt "$head_latest_tag_version" "$head_package_version"; then
      fail "head ref $head_ref uses package version $head_package_version, which is older than latest tag v$head_latest_tag_version in major $head_major; pick a newer version before crossing release lines"
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

if [[ "$base_package_version" == "$latest_tag_version" ]]; then
  printf 'Release train guard OK: base=%s head=%s latest_tag=%s\n' \
    "$base_package_version" "$head_package_version" "$latest_tag_version"
  exit 0
fi

if version_gt "$base_package_version" "$latest_tag_version"; then
  if [[ "$head_package_version" == "$base_package_version" ]]; then
    # PR does not change the package version — allow it through with a warning.
    # The pending release tag is a repo-level concern, not this PR's responsibility.
    printf '::warning::Release train: base %s is ahead of latest tag v%s. Tag v%s when ready.\n' \
      "$base_package_version" "$latest_tag_version" "$base_package_version"
    printf 'Release train guard OK (warn): base=%s head=%s latest_tag=%s (pending release)\n' \
      "$base_package_version" "$head_package_version" "$latest_tag_version"
    exit 0
  fi
  fail "base ref $base_ref advertises unreleased package version $base_package_version while latest tag is v$latest_tag_version, and head changes package version to $head_package_version; publish/tag v$base_package_version before widening the release train"
fi

fail "base ref $base_ref has package version $base_package_version, which is older than latest tag v$latest_tag_version; sync version truth before merging"
