#!/usr/bin/env bash
# Usage: ./scripts/bump-version.sh 0.2.0

set -euo pipefail

NEW_VERSION="${1:-}"
if [ -z "$NEW_VERSION" ]; then
  echo "Usage: $0 <new-version>" >&2
  echo "Example: $0 0.2.0" >&2
  exit 1
fi

if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be SemVer (x.y.z)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TODAY="$(date +%Y-%m-%d)"

# Cross-platform sed -i: macOS uses sed -i '', GNU uses sed -i
sedi() {
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

echo "Bumping release version to $NEW_VERSION"

# A malformed changelog fragment stops the bump before any file changes.
python3 "$ROOT_DIR/scripts/changelog-fragments.py" check --dir "$ROOT_DIR/changelog.d"

# 1) SSOT: dune-project
sedi -E "s/^\(version [^)]+\)$/\(version $NEW_VERSION\)/" \
  "$ROOT_DIR/dune-project"
echo "  dune-project updated"

# 2) README badge, if the README still carries one
if grep -Eq 'version-[0-9]+\.[0-9]+\.[0-9]+-blue' "$ROOT_DIR/README.md"; then
  sedi -E "s/version-[0-9]+\.[0-9]+\.[0-9]+-blue/version-$NEW_VERSION-blue/" \
    "$ROOT_DIR/README.md"
  echo "  README.md badge updated"
else
  echo "  README.md has no version badge — nothing to update"
fi

# 3) opam metadata (if tracked)
if [ -f "$ROOT_DIR/masc.opam" ]; then
  sedi -E "s/^version: \"[^\"]*\"$/version: \"$NEW_VERSION\"/" "$ROOT_DIR/masc.opam"
  echo "  masc.opam version synchronized (CI verifies generated metadata)"
fi

# 4) CHANGELOG: fold the per-PR fragments (changelog.d/<PR>.md) into
# [Unreleased], then add the version stub if missing. The release author moves
# the [Unreleased] entries into the version section before tagging.
# Before folding, list the pull requests merged since the last release whose
# changes carry no fragment (#39079, #39095: nine entries had to be backfilled
# after their releases). It reports; it does not refuse. A broken report
# (bad base, crash) announces itself instead of passing as an empty list.
# The base cannot come from `git describe --tags --abbrev=0`, which only sees
# tags that are ancestors of HEAD: release branches land back on main as
# squash commits (#42169), so the latest tags v0.49.0 and v0.50.0 are not
# ancestors of main and describe either picks v0.48.0 — making the report
# rescan everything v0.49.0/v0.50.0 already folded — or, on a shallow
# checkout, fails and silently skips the report. Pick the newest v*.*.* tag
# by version instead, and use that release's main-reflection commit as the
# base so the scan covers only main commits after the release.
last_tag="$(git for-each-ref refs/tags --format='%(refname:short)' --sort=-v:refname 2>/dev/null \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
base_ref=""
if [ -n "$last_tag" ]; then
  # The release branch is folded back onto main by a single squash whose
  # subject names the tag; on the first-parent chain the newest match is
  # that release's reflection commit.
  base_ref="$(git log --first-parent -F -1 --format=%H \
    --grep="chore(release): merge $last_tag back into main" 2>/dev/null || true)"
  if [ -z "$base_ref" ] && git merge-base --is-ancestor "$last_tag" HEAD 2>/dev/null; then
    # No squash reflection found; fall back to the tag itself when the repo
    # still tags directly on main, which is what describe used to do.
    base_ref="$last_tag"
  fi
  if [ -z "$base_ref" ]; then
    # Between tagging and folding the branch back onto main the reflection
    # commit does not exist yet and the tag is not an ancestor of HEAD, so
    # no base can be found. Say so instead of silently skipping the report
    # ("A broken report announces itself" — an empty report must not look
    # like one).
    echo "warning: cannot determine missing-fragment base for $last_tag:" \
      "no 'chore(release): merge $last_tag back into main' commit on main" \
      "first-parent and $last_tag is not an ancestor of HEAD;" \
      "skipping the missing-fragment report" >&2
  fi
fi
if [ -n "$base_ref" ]; then
  missing_err="$(mktemp)"
  missing_status=0
  python3 "$ROOT_DIR/scripts/changelog-fragments.py" missing \
    --base "$base_ref" --dir "$ROOT_DIR/changelog.d" \
    2>"$missing_err" || missing_status=$?
  if [ "$missing_status" -ne 0 ]; then
    # An empty list means "nothing missing"; a crash must not look like one.
    echo "warning: missing-fragment list failed (exit $missing_status)" >&2
    sed 's/^/  /' "$missing_err" >&2
  fi
  rm -f "$missing_err"
fi
python3 "$ROOT_DIR/scripts/changelog-fragments.py" assemble \
  --dir "$ROOT_DIR/changelog.d" --changelog "$ROOT_DIR/CHANGELOG.md"
if ! grep -q "^## \[$NEW_VERSION\]" "$ROOT_DIR/CHANGELOG.md"; then
  tmp_file="$(mktemp)"
  # The stub goes under [Unreleased], above the newest release, so
  # [Unreleased] stays the first section changelog-fragments.py reads.
  awk -v ver="$NEW_VERSION" -v d="$TODAY" '
    !done && /^## \[[0-9]/ {
      print "## [" ver "] - " d;
      print "";
      print "### Changed";
      print "- TBD";
      print "";
      print "### Deprecated";
      print "- TBD";
      print "";
      done = 1
    }
    { print }
  ' "$ROOT_DIR/CHANGELOG.md" > "$tmp_file"
  mv "$tmp_file" "$ROOT_DIR/CHANGELOG.md"
  echo "  CHANGELOG.md stub added"
else
  echo "  CHANGELOG already has $NEW_VERSION entry"
fi

# 5) ROADMAP.md — current package version + latest changelog entry
sedi -E "s/^> Current package version: v[^ ]*/> Current package version: v$NEW_VERSION/" \
  "$ROOT_DIR/ROADMAP.md"
sedi -E "s/^> Latest changelog entry: v[^ ]+ \([0-9]{4}-[0-9]{2}-[0-9]{2}\)$/> Latest changelog entry: v$NEW_VERSION ($TODAY)/" \
  "$ROOT_DIR/ROADMAP.md"
sedi -E "s/^> Updated: [0-9]{4}-[0-9]{2}-[0-9]{2}$/> Updated: $TODAY/" \
  "$ROOT_DIR/ROADMAP.md"
echo "  ROADMAP.md updated"

# 6) docs/PRODUCT-OPERATING-PLAN.md — current package version + latest changelog entry
sedi -E "s/^> Current package version: v[^ ]*/> Current package version: v$NEW_VERSION/" \
  "$ROOT_DIR/docs/PRODUCT-OPERATING-PLAN.md"
sedi -E "s/^> Latest changelog entry: v[^ ]+ \([0-9]{4}-[0-9]{2}-[0-9]{2}\)$/> Latest changelog entry: v$NEW_VERSION ($TODAY)/" \
  "$ROOT_DIR/docs/PRODUCT-OPERATING-PLAN.md"
sedi -E "s/^> Updated: [0-9]{4}-[0-9]{2}-[0-9]{2}$/> Updated: $TODAY/" \
  "$ROOT_DIR/docs/PRODUCT-OPERATING-PLAN.md"
echo "  PRODUCT-OPERATING-PLAN.md updated"

# 7) docs/spec/SPEC-INDEX.md — snapshot baseline + release baseline table
sedi -E "s/version \`[0-9]+\.[0-9]+\.[0-9]+\`/version \`$NEW_VERSION\`/" \
  "$ROOT_DIR/docs/spec/SPEC-INDEX.md"
sedi -E "s/Release baseline \| [0-9]+\.[0-9]+\.[0-9]+/Release baseline | $NEW_VERSION/" \
  "$ROOT_DIR/docs/spec/SPEC-INDEX.md"
echo "  SPEC-INDEX.md updated"

# 8) Install pins — the copy-paste block in README, INSTALL and the site
# quickstart names the release being cut. Nothing else moves them, and they
# sat on v0.35.14 while five later releases went out. Until the tag exists
# the pins name a release readers cannot download yet; the README's "check tag
# availability" line moves with them.
for readme in README.md README.ko.md; do
  sedi -E "s#releases/tag/v[0-9]+\.[0-9]+\.[0-9]+#releases/tag/v$NEW_VERSION#g" \
    "$ROOT_DIR/$readme"
  sedi -E "s/^> Installation target: v[^ ]+ /> Installation target: v$NEW_VERSION /" \
    "$ROOT_DIR/$readme"
done
for install_doc in README.md README.ko.md docs/INSTALL.md docs/INSTALL.ko.md; do
  sedi -E "s/^TAG=v[^ ]+$/TAG=v$NEW_VERSION/" "$ROOT_DIR/$install_doc"
done
# The site pages name the release version in prose, a heading and the pin.
for site_doc in \
  docs-site/src/content/docs/getting-started/quickstart.md \
  docs-site/src/content/docs/ko/getting-started/quickstart.md; do
  sedi -E "s/[0-9]+\.[0-9]+\.[0-9]+/$NEW_VERSION/g" "$ROOT_DIR/$site_doc"
done
echo "  install pins updated"

echo ""
echo "Release version layers:"
echo "  1) release SemVer: $NEW_VERSION"
echo "  2) protocol matrix: see /health.protocol + mcp-protocol-version"
echo "  3) artifact schema: report/proof JSON schema_version"
echo "  4) pre-1.0 lane: use 0.y.0 for promise trains, 0.y.z for stabilization"
echo ""
echo "Next:"
echo "  scripts/check-version-truth.sh"
echo "  # Build and installed-release smoke run in CI."
echo "  git add dune-project README.md README.ko.md CHANGELOG.md changelog.d masc.opam ROADMAP.md docs/PRODUCT-OPERATING-PLAN.md docs/spec/SPEC-INDEX.md docs/INSTALL.md docs/INSTALL.ko.md docs-site/src/content/docs/getting-started/quickstart.md docs-site/src/content/docs/ko/getting-started/quickstart.md"
echo "  git commit -m \"chore(release): bump version to $NEW_VERSION\""
