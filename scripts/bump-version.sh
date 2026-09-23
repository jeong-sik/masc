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
# availability" line, which check-doc-truth.sh requires beside every pin,
# moves with them.
for readme in README.md README.ko.md; do
  sedi -E "s#releases/tag/v[0-9]+\.[0-9]+\.[0-9]+#releases/tag/v$NEW_VERSION#g" \
    "$ROOT_DIR/$readme"
  sedi -E "s/^> Installation target: v[^ ]+ /> Installation target: v$NEW_VERSION /" \
    "$ROOT_DIR/$readme"
done
for install_doc in README.md README.ko.md docs/INSTALL.md docs/INSTALL.ko.md; do
  sedi -E "s/^TAG=v[^ ]+$/TAG=v$NEW_VERSION/" "$ROOT_DIR/$install_doc"
done
# The site pages name one version in prose, a heading and the pin, and
# check-doc-truth.sh refuses any other version token on them.
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
