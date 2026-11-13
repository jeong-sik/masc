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
  if grep -q GNU <<<"$(sed --version 2>/dev/null)"; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

echo "Bumping release version to $NEW_VERSION"

# A malformed changelog fragment stops the bump before any file changes.
python3 "$ROOT_DIR/scripts/changelog-fragments.py" check --dir "$ROOT_DIR/changelog.d"

# Before folding, list the pull requests merged since the last release whose
# changes carry no fragment (#39079, #39095: nine entries had to be backfilled
# after their releases). With --strict it refuses the bump when a merged
# pull request still lacks a fragment. A broken report
# (bad base, crash) announces itself instead of passing as an empty list.
# The base cannot come from `git describe --tags --abbrev=0`, which only sees
# tags that are ancestors of HEAD: release branches land back on main as
# squash commits (#42169), so the latest tags v0.49.0 and v0.50.0 are not
# ancestors of main and describe either picks v0.48.0 — making the report
# rescan everything v0.49.0/v0.50.0 already folded — or, on a shallow
# checkout, fails and silently skips the report. Pick the newest v*.*.* tag
# by version instead, and start the scan where that release's fold stopped
# seeing this branch.
last_tag="$(git for-each-ref refs/tags --format='%(refname:short)' --sort=-v:refname 2>/dev/null \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
base_ref=""
if [ -n "$last_tag" ]; then
  # Two commits bound what the last release folded, and git names both.
  #   fold: the first-parent commit that set dune-project's version to the
  #         tag's. The fold and the version bump are one commit (this script
  #         writes both), and nothing merged after it was folded.
  #   cut:  the merge base of the tag and HEAD, the last commit of this
  #         branch the release branch saw.
  # The scan starts at whichever is the ancestor of the other. v0.70.0 was
  # folded on its release branch and reached main 95 pull requests after the
  # cut, with none of their fragments folded: the cut is the base. v0.71.0
  # was folded on main and its release branch merged main 23 commits later:
  # the fold is the base, and the tag would leave those 23 unscanned.
  # The fold's subject says nothing reliable. These releases reached main as
  # "Backport v0.70.0 release fold ..." and "chore(release): bump version to
  # ...", a subject search for "merge <tag> back into main" matched none of
  # them, and the tag stood in as the base for every one (#51334).
  # -S lists the commits where the count of the version line changes — the
  # one that writes it and the later one that replaces it — so the file is
  # read at each candidate and only a commit that carries the line counts.
  last_version_line="(version ${last_tag#v})"
  fold_ref=""
  fold_candidates="$(git log --first-parent --format=%H -S"$last_version_line" -- dune-project)"
  for candidate in $fold_candidates; do
    if grep -Fxq -- "$last_version_line" <<<"$(git show "$candidate:dune-project")"; then
      fold_ref="$candidate"
      break
    fi
  done
  if [ -z "$fold_ref" ]; then
    # Nothing on this branch folded the last release: it is not folded back
    # here yet, or the checkout is too shallow to reach the fold. Any base
    # picked now would be a guess that widens or narrows the report unseen,
    # so the bump stops before it changes a file.
    echo "error: no first-parent commit of HEAD sets dune-project to" \
      "'$last_version_line', so the commit that folded $last_tag cannot be" \
      "identified and the missing-fragment report has no base." \
      "Fold $last_tag back onto this branch (or fetch the full history) and rerun." >&2
    exit 1
  fi
  if ! cut_ref="$(git merge-base "$last_tag" HEAD)"; then
    echo "error: $last_tag and HEAD share no commit, so the point where the" \
      "release left this branch is unknown and the missing-fragment report" \
      "has no base." >&2
    exit 1
  fi
  if git merge-base --is-ancestor "$fold_ref" "$cut_ref"; then
    base_ref="$fold_ref"
  elif git merge-base --is-ancestor "$cut_ref" "$fold_ref"; then
    base_ref="$cut_ref"
  else
    echo "error: the commit that folded $last_tag ($fold_ref) and the commit" \
      "where $last_tag left this branch ($cut_ref) are on separate lines of" \
      "history, so neither bounds the other and the missing-fragment report" \
      "has no base." >&2
    exit 1
  fi
fi
if [ -n "$base_ref" ]; then
  missing_err="$(mktemp)"
  missing_out="$(mktemp)"
  missing_status=0
  python3 "$ROOT_DIR/scripts/changelog-fragments.py" missing \
    --base "$base_ref" --dir "$ROOT_DIR/changelog.d" --strict \
    >"$missing_out" 2>"$missing_err" || missing_status=$?
  if [ "$missing_status" -eq 3 ]; then
    # Exit 3 is the strict gate's "findings" verdict: the report listed
    # non-exempt pull requests without fragments. Refuse the bump — write
    # or backfill the fragments first. (Exempt-only output exits 0 and is
    # echoed below, so the operator still sees every omission.)
    cat "$missing_out" >&2
    echo "error: merged pull requests above lack changelog fragments; refusing to bump" >&2
    rm -f "$missing_err" "$missing_out"
    exit 1
  fi
  if [ "$missing_status" -ne 0 ]; then
    # An empty list means "nothing missing"; a crash must not look like one.
    echo "warning: missing-fragment list failed (exit $missing_status)" >&2
    sed 's/^/  /' "$missing_err" >&2
  fi
  if [ "$missing_status" -eq 0 ] && [ -s "$missing_out" ]; then
    # Exempt-only findings still exit 0; echo them so the operator sees
    # every omission, not just the blocking ones.
    cat "$missing_out" >&2
  fi
  rm -f "$missing_err" "$missing_out"
fi


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
