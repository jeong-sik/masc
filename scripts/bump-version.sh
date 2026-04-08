#!/usr/bin/env bash
# Usage: ./scripts/bump-version.sh 2.77.0

set -euo pipefail

NEW_VERSION="${1:-}"
if [ -z "$NEW_VERSION" ]; then
  echo "Usage: $0 <new-version>" >&2
  echo "Example: $0 2.77.0" >&2
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

# 1) SSOT: dune-project
sedi -E "s/^\(version [^)]+\)$/\(version $NEW_VERSION\)/" \
  "$ROOT_DIR/dune-project"
echo "  dune-project updated"

# 2) README badge
sedi -E "s/version-[0-9]+\.[0-9]+\.[0-9]+-blue/version-$NEW_VERSION-blue/" \
  "$ROOT_DIR/README.md"
echo "  README.md badge updated"

# 3) opam metadata (if tracked)
if [ -f "$ROOT_DIR/masc_mcp.opam" ]; then
  dune build masc_mcp.opam --root "$ROOT_DIR"
  echo "  masc_mcp.opam updated (via dune build)"
fi

# 4) CHANGELOG stub (prepend if missing)
if ! grep -q "^## \[$NEW_VERSION\]" "$ROOT_DIR/CHANGELOG.md"; then
  tmp_file="$(mktemp)"
  awk -v ver="$NEW_VERSION" -v d="$TODAY" '
    NR == 1 { print; next }
    NR == 2 {
      print;
      print "";
      print "## [" ver "] - " d;
      print "";
      print "### Changed";
      print "- TBD";
      print "";
      print "### Deprecated";
      print "- TBD";
      next
    }
    { print }
  ' "$ROOT_DIR/CHANGELOG.md" > "$tmp_file"
  mv "$tmp_file" "$ROOT_DIR/CHANGELOG.md"
  echo "  CHANGELOG.md stub added"
else
  echo "  CHANGELOG already has $NEW_VERSION entry"
fi

# 5) ROADMAP.md — current package version + latest release
sedi -E "s/^> Current package version: v[^ ]*/> Current package version: v$NEW_VERSION/" \
  "$ROOT_DIR/ROADMAP.md"
sedi -E "s/^> Latest release: v[^ ]*/> Latest release: v$NEW_VERSION/" \
  "$ROOT_DIR/ROADMAP.md"
echo "  ROADMAP.md updated"

# 6) docs/PRODUCT-OPERATING-PLAN.md — current package version + latest release
sedi -E "s/^> Current package version: v[^ ]*/> Current package version: v$NEW_VERSION/" \
  "$ROOT_DIR/docs/PRODUCT-OPERATING-PLAN.md"
sedi -E "s/^> Latest release: v[^ ]*/> Latest release: v$NEW_VERSION/" \
  "$ROOT_DIR/docs/PRODUCT-OPERATING-PLAN.md"
echo "  PRODUCT-OPERATING-PLAN.md updated"

# 7) docs/spec/SPEC-INDEX.md — snapshot baseline + release baseline table
sedi -E "s/version \`[0-9]+\.[0-9]+\.[0-9]+\`/version \`$NEW_VERSION\`/" \
  "$ROOT_DIR/docs/spec/SPEC-INDEX.md"
sedi -E "s/Release baseline \| [0-9]+\.[0-9]+\.[0-9]+/Release baseline | $NEW_VERSION/" \
  "$ROOT_DIR/docs/spec/SPEC-INDEX.md"
echo "  SPEC-INDEX.md updated"

echo ""
echo "Release version layers:"
echo "  1) release SemVer: $NEW_VERSION"
echo "  2) protocol matrix: see /health.protocol + mcp-protocol-version"
echo "  3) artifact schema: report/proof JSON schema_version"
echo ""
echo "Next:"
echo "  dune build --root ."
echo "  git add dune-project README.md CHANGELOG.md masc_mcp.opam ROADMAP.md docs/PRODUCT-OPERATING-PLAN.md docs/spec/SPEC-INDEX.md"
echo "  git commit -m \"chore(release): bump version to $NEW_VERSION\""
