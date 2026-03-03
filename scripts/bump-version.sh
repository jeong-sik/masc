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

echo "🔄 Bumping release version to $NEW_VERSION"

# 1) SSOT: dune-project
sed -i '' -E "s/^\(version [^)]+\)$/\(version $NEW_VERSION\)/" \
  "$ROOT_DIR/dune-project"
echo "✅ dune-project"

# 2) README badge
sed -i '' -E "s/version-[0-9]+\.[0-9]+\.[0-9]+-blue/version-$NEW_VERSION-blue/" \
  "$ROOT_DIR/README.md"
echo "✅ README.md badge"

# 3) opam metadata (if tracked)
if [ -f "$ROOT_DIR/masc_mcp.opam" ]; then
  sed -i '' -E "s/^version: \".*\"/version: \"$NEW_VERSION\"/" \
    "$ROOT_DIR/masc_mcp.opam"
  echo "✅ masc_mcp.opam"
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
  echo "✅ CHANGELOG.md stub added"
else
  echo "ℹ️ CHANGELOG already has $NEW_VERSION entry"
fi

echo ""
echo "Release version layers:"
echo "  1) release SemVer: $NEW_VERSION"
echo "  2) protocol matrix: see /health.protocol + mcp-protocol-version"
echo "  3) artifact schema: report/proof JSON schema_version"
echo ""
echo "Next:"
echo "  dune build --root ."
echo "  git add dune-project README.md CHANGELOG.md masc_mcp.opam"
echo "  git commit -m \"chore(release): bump version to $NEW_VERSION\""
