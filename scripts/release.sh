#!/usr/bin/env bash
set -euo pipefail

# release.sh -- Verify version consistency and create a release tag.
#
# Usage:
#   ./scripts/release.sh          # dry-run (verify only)
#   ./scripts/release.sh --tag    # verify + create tag + push
#
# IMPORTANT: Must run on the post-merge `main` branch.
# `git tag -a vX.Y.Z` places the tag on the current HEAD. Running this
# from a feature branch (before the release PR is merged) leaves the
# tag on a commit that is no longer on `main` after GitHub's rebase
# merge rewrites the SHA (#1135, #1136). The checks below refuse to
# run unless `main` is checked out and synced with origin/main.

TAG_MODE=false
if [[ "${1:-}" == "--tag" ]]; then
  TAG_MODE=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/release-version-lib.sh"

# Check -1: running on `main` synced with origin/main.
# Rationale: tag lands on HEAD, so a non-main HEAD (or a stale main)
# produces an orphaned tag after PR merge rebases the SHA.
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "ERROR: release.sh must run on 'main', current branch is '$CURRENT_BRANCH'."
  echo ""
  echo "PR rebase merge rewrites the release-cut commit SHA. Tagging before"
  echo "merge leaves the tag on a commit that no longer exists on main."
  echo ""
  echo "Fix:"
  echo "  git checkout main && git pull --ff-only"
  echo "  scripts/release.sh --tag"
  exit 1
fi

git fetch origin main --quiet
LOCAL_MAIN=$(git rev-parse HEAD)
ORIGIN_MAIN=$(git rev-parse origin/main)
if [[ "$LOCAL_MAIN" != "$ORIGIN_MAIN" ]]; then
  echo "ERROR: local main ($LOCAL_MAIN) is not in sync with origin/main ($ORIGIN_MAIN)."
  echo "Tag would land on a stale commit."
  echo ""
  echo "Fix: git pull --ff-only"
  exit 1
fi

# Extract versions from canonical sources
DUNE_VER=$(release_extract_dune_project_version dune-project)
SDK_VER=$(release_extract_sdk_version lib/sdk_version.ml)
OPAM_VER=$(release_extract_opam_version agent_sdk.opam)
LATEST_TAG=$(git tag -l 'v*' --sort=-v:refname | head -1)

echo "dune-project version: $DUNE_VER"
echo "sdk_version.ml version: $SDK_VER"
echo "agent_sdk.opam version: $OPAM_VER"
echo "Latest git tag:       $LATEST_TAG"
echo ""

# Check 0: version extraction succeeded
if [[ -z "$DUNE_VER" || -z "$SDK_VER" || -z "$OPAM_VER" ]]; then
  echo "ERROR: Failed to extract one or more version strings."
  exit 1
fi

for parsed_version in "$DUNE_VER" "$SDK_VER" "$OPAM_VER"; do
  if ! release_is_supported_version "$parsed_version"; then
    echo "ERROR: Extracted invalid release version string: $parsed_version"
    exit 1
  fi
done

# Check 1: dune-project == sdk_version.ml == agent_sdk.opam
if [[ "$DUNE_VER" != "$SDK_VER" ]]; then
  echo "ERROR: dune-project ($DUNE_VER) != sdk_version.ml ($SDK_VER)"
  exit 1
fi

if [[ "$DUNE_VER" != "$OPAM_VER" ]]; then
  echo "ERROR: dune-project ($DUNE_VER) != agent_sdk.opam ($OPAM_VER)"
  exit 1
fi

VERSION="$DUNE_VER"

# Check 2: tag doesn't already exist
if git tag -l "v${VERSION}" | grep -q .; then
  echo "ERROR: Tag v${VERSION} already exists."
  exit 1
fi

# Check 3: CHANGELOG has an entry for this version
if ! grep -q "\[${VERSION}\]" CHANGELOG.md; then
  echo "ERROR: No CHANGELOG.md entry found for [${VERSION}]."
  exit 1
fi

# Check 4: working tree is clean
if [[ -n "$(git status --porcelain)" ]]; then
  echo "WARNING: Working tree has uncommitted changes."
  if $TAG_MODE; then
    echo "ERROR: Cannot tag with dirty working tree."
    exit 1
  fi
fi

echo "All checks passed for v${VERSION}."

if $TAG_MODE; then
  echo ""
  echo "Creating tag v${VERSION}..."
  git tag -a "v${VERSION}" -m "v${VERSION}"
  echo "Pushing tag..."
  git push origin "v${VERSION}"
  echo "Released v${VERSION}."
else
  echo ""
  echo "Dry run complete. Run with --tag to create and push the tag."
fi
