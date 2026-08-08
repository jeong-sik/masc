#!/usr/bin/env bash
# check-tag-drift.sh — verify release metadata stays coherent: the current
# dune-project version must have a CHANGELOG entry, and released CHANGELOG
# entries should have matching git tags.
#
# Relationship to peers:
#   release.sh             — one-shot "cut this release + push tag". Operator tool.
#   sync-version-truth.sh  — sync 3 in-repo surfaces (dune / opam / sdk_version.ml).
#   check-tag-drift.sh     — audit CHANGELOG currentness plus released
#                            CHANGELOG entries ↔ git tags.
#
# Motivation: dune-project / agent_sdk.opam / lib/sdk_version.ml can be bumped,
# a CHANGELOG entry added, and the release PR merged, all without anyone ever
# running `release.sh --tag`. The drift is invisible until someone needs to pin
# by tag (e.g. downstream masc-mcp `oas-agent-sdk-pin.sh BASE=v0.169.0`). Scanning
# the repo on 2026-04-21 found v0.169.0, v0.164.0, v0.163.0, v0.161.0 (and more)
# documented as released in CHANGELOG but never tagged.
#
# Usage:
#   scripts/check-tag-drift.sh           # warn-only: list drift, always exit 0
#   scripts/check-tag-drift.sh --strict  # fail (exit 1) if current version has
#                                        # no CHANGELOG entry, or if any scanned
#                                        # CHANGELOG version is missing a tag
#   scripts/check-tag-drift.sh --allow-current-untagged
#                                        # permit the current version's missing
#                                        # tag during the release-entry PR
#   scripts/check-tag-drift.sh --limit N # only consider the N most recent tag
#                                        # checks (default: 10)
#
# Exit codes:
#   0   no drift, or drift present in warn-only mode
#   1   drift present in --strict mode
#   2   usage error / repo state error

set -euo pipefail

strict=false
allow_current_untagged=false
limit=10

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while (($# > 0)); do
  case "$1" in
    --strict) strict=true ;;
    --allow-current-untagged) allow_current_untagged=true ;;
    --limit) shift; limit="${1:-}" ;;
    --limit=*) limit="${1#--limit=}" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if ! [[ "$limit" =~ ^[0-9]+$ ]] || (( limit <= 0 )); then
  echo "check-tag-drift: --limit must be a positive integer" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ ! -f CHANGELOG.md ]]; then
  echo "check-tag-drift: CHANGELOG.md not found in $repo_root" >&2
  exit 2
fi

current_version="$(sed -n 's/^(version \([^)]*\)).*/\1/p' dune-project | head -n1)"
if [[ -z "${current_version}" ]]; then
  echo "check-tag-drift: no current version found in dune-project" >&2
  exit 2
fi

# Extract CHANGELOG versions in document order (newest first, by convention).
# Two header shapes are accepted:
#   manual:         `## [0.169.0] - 2026-04-21`
#   release-please: `## [0.193.4](https://.../compare/v0.193.3...v0.193.4) (2026-05-11)`
# The character class `[ (]` right after `\]` admits both — a space (manual
# style) or `(` (release-please style). Unreleased / placeholder headers like
# `## [Unreleased]` are skipped because they have no version digits.
all_versions=()
while IFS= read -r line; do
  all_versions+=("$line")
done < <(
  sed -n 's/^## \[\([0-9][0-9]*\(\.[0-9][0-9]*\)\{1,2\}\)\][ (].*/\1/p' CHANGELOG.md
)

if (( ${#all_versions[@]} == 0 )); then
  echo "check-tag-drift: no CHANGELOG versions found (regex: ^## \\[X.Y(.Z)\\][ (]...)" >&2
  exit 2
fi

versions=()
while IFS= read -r line; do
  versions+=("$line")
done < <(
  printf '%s\n' "${all_versions[@]}" | head -n "$limit"
)

missing=()
pending_current=()
present=()
current_has_changelog=0

for v in "${all_versions[@]}"; do
  if [[ "${v}" == "${current_version}" ]]; then
    current_has_changelog=1
    break
  fi
done

for v in "${versions[@]}"; do
  if git tag -l "v${v}" | grep -qx "v${v}"; then
    present+=("v${v}")
  elif [[ "${allow_current_untagged}" == true && "${v}" == "${current_version}" ]]; then
    pending_current+=("v${v}")
  else
    missing+=("v${v}")
  fi
done

echo "check-tag-drift: current version ${current_version}"
echo "check-tag-drift: scanned ${#versions[@]} most recent CHANGELOG entries (limit=${limit})"
echo "  tagged:  ${#present[@]}"
echo "  missing: ${#missing[@]}"
if (( ${#pending_current[@]} > 0 )); then
  echo "  pending current release tag: ${#pending_current[@]}"
fi

if (( current_has_changelog == 0 )); then
  echo ""
  echo "Current version lacks a CHANGELOG entry:"
  echo "  - dune-project version: ${current_version}"
  echo "  - expected header (either form is accepted):"
  echo "      ## [${current_version}] - YYYY-MM-DD"
  echo "      ## [${current_version}](URL) (YYYY-MM-DD)   # release-please"
  echo ""
  echo "This blocks scripts/release.sh and should be fixed before cutting a tag."

  if $strict; then
    exit 1
  fi
fi

if (( ${#pending_current[@]} > 0 )); then
  echo ""
  echo "Pending current release tag allowed by --allow-current-untagged:"
  for t in "${pending_current[@]}"; do
    echo "  - ${t}"
  done
  echo ""
  echo "After the release-entry PR lands on main, run:"
  echo "  scripts/release.sh --tag"
fi

if (( ${#missing[@]} > 0 )); then
  echo ""
  echo "Missing tags (CHANGELOG says released, git has no tag):"
  for t in "${missing[@]}"; do
    echo "  - ${t}"
  done
  echo ""
  echo "To fix for a specific version v<X>:"
  echo "  # find the release-cut commit (PR that edited dune-project to <X>)"
  echo "  git log --oneline --grep='cut <X>' -- dune-project"
  echo "  git tag -a v<X> <SHA> -m 'Release v<X>'"
  echo "  git push origin v<X>"

  if $strict; then
    exit 1
  fi
fi

exit 0
