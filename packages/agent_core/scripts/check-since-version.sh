#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/scripts/release-version-lib.sh"

release_version="${1:-$(release_extract_dune_project_version "${repo_root}/dune-project")}"
scan_root="${2:-${repo_root}/lib}"

if [[ ! "$release_version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
  echo "ERROR: release version is not strict SemVer: ${release_version}" >&2
  exit 1
fi

version_gt() {
  local lhs="$1"
  local rhs="$2"
  local lhs_major lhs_minor lhs_patch
  local rhs_major rhs_minor rhs_patch

  IFS=. read -r lhs_major lhs_minor lhs_patch <<< "$lhs"
  IFS=. read -r rhs_major rhs_minor rhs_patch <<< "$rhs"

  (( 10#$lhs_major > 10#$rhs_major )) && return 0
  (( 10#$lhs_major < 10#$rhs_major )) && return 1
  (( 10#$lhs_minor > 10#$rhs_minor )) && return 0
  (( 10#$lhs_minor < 10#$rhs_minor )) && return 1
  (( 10#$lhs_patch > 10#$rhs_patch ))
}

annotations=0
violations=0
while IFS=: read -r path line annotation; do
  [[ -n "$annotation" ]] || continue
  read -r _ since <<< "$annotation"
  annotations=$((annotations + 1))

  if [[ ! "$since" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    echo "ERROR: ${path}:${line}: invalid @since version '${since}'" >&2
    violations=$((violations + 1))
  elif version_gt "$since" "$release_version"; then
    echo "ERROR: ${path}:${line}: @since ${since} exceeds release ${release_version}" >&2
    violations=$((violations + 1))
  fi
done < <(
  rg --with-filename --line-number --only-matching \
    '@since[[:space:]]+[^[:space:]*]+' "$scan_root" -g '*.mli' || true
)

if (( annotations == 0 )); then
  echo "ERROR: no @since annotations found under ${scan_root}" >&2
  exit 1
fi

if (( violations > 0 )); then
  echo "Release availability check failed with ${violations} violation(s)." >&2
  exit 1
fi

echo "Release availability check passed: ${annotations} @since annotation(s) <= ${release_version}"
