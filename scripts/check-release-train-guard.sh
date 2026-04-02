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

version_gt() {
  local left="$1"
  local right="$2"
  [[ "$left" != "$right" ]] && [[ "$(printf '%s\n%s\n' "$left" "$right" | sort -V | tail -n1)" == "$left" ]]
}

head_package_version="$(version_from_ref "$head_ref")"
[[ -n "$head_package_version" ]] || fail "missing package version in $head_ref:dune-project"

latest_tag="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -n1)"
if [[ -z "$latest_tag" ]]; then
  printf 'Release train guard OK: no release tags found, head=%s\n' "$head_package_version"
  exit 0
fi
latest_tag_version="${latest_tag#v}"

if [[ -z "$base_ref" ]]; then
  printf 'Release train guard OK: no base ref provided, head=%s latest_tag=%s\n' \
    "$head_package_version" "$latest_tag_version"
  exit 0
fi

base_package_version="$(version_from_ref "$base_ref")"
[[ -n "$base_package_version" ]] || fail "missing package version in $base_ref:dune-project"

if [[ "$base_package_version" == "$latest_tag_version" ]]; then
  printf 'Release train guard OK: base=%s head=%s latest_tag=%s\n' \
    "$base_package_version" "$head_package_version" "$latest_tag_version"
  exit 0
fi

if version_gt "$base_package_version" "$latest_tag_version"; then
  if [[ "$head_package_version" == "$base_package_version" ]]; then
    fail "base ref $base_ref advertises unreleased package version $base_package_version while latest tag is v$latest_tag_version; publish/tag v$base_package_version before merging further PRs into main"
  fi
  fail "base ref $base_ref advertises unreleased package version $base_package_version while latest tag is v$latest_tag_version, and head changes package version to $head_package_version; publish/tag v$base_package_version before widening the release train"
fi

fail "base ref $base_ref has package version $base_package_version, which is older than latest tag v$latest_tag_version; sync version truth before merging"
