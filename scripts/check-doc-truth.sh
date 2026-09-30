#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-doc-truth.sh

Checks minimal front-door documentation truth against current repo state.
EOF
}

if (($# > 0)); then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'doc truth check failed: %s\n' "$1" >&2
  exit 1
}

# rg exits 1 when it finds nothing, which is a normal outcome for these scans;
# exit 2 means the scan itself broke (bad regex, unreadable path). `|| true`
# would erase both and let a broken scan report success, so tolerate only 1.
# The result lands in RG_OUT: callers must not pipe this function, or `fail`
# would end only the pipeline's subshell instead of the script.
RG_OUT=""
rg_or_empty() {
  local pattern="$1"
  shift
  local status=0
  RG_OUT="$(rg -o "$pattern" "$@")" || status=$?
  ((status <= 1)) || fail "rg exited $status scanning $*"
}

# Keep the consumer open through EOF so pipefail still reports real scan errors.
extract_single() {
  local pattern="$1"
  local file="$2"
  sed -n "s/$pattern/\\1/p" "$file" | sed -n '1p'
}

scripts/check-version-truth.sh

package_version="$(extract_single '^> Current package version: v\([^ ]*\).*$' ROADMAP.md)"
roadmap_published_release="$(extract_single '^> Latest published GitHub release: v\([^ ]*\).*$' ROADMAP.md)"
product_package_version="$(extract_single '^> Current package version: v\([^ ]*\).*$' docs/PRODUCT-OPERATING-PLAN.md)"
product_changelog_entry="$(extract_single '^> Latest changelog entry: v\([^ ]*\).*$' docs/PRODUCT-OPERATING-PLAN.md)"
product_published_release="$(extract_single '^> Latest published GitHub release: v\([^ ]*\).*$' docs/PRODUCT-OPERATING-PLAN.md)"
spec_baseline="$(extract_single '^> Snapshot baseline: `dune-project` version `\([^`]*\)`$' docs/spec/SPEC-INDEX.md)"
# The copy-paste install block. Nothing checked it, so it kept the previous
# release across two of them: v0.33.0 stood while v0.34.0 was Latest, and a
# reader following the README installed the version before the one the same
# page announced two paragraphs earlier.
readme_tag="$(extract_single '^TAG=v\([^ ]*\)$' README.md)"
readme_ko_tag="$(extract_single '^TAG=v\([^ ]*\)$' README.ko.md)"
changelog_latest_release="$(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' CHANGELOG.md | sed -n '1p')"

[[ -n "$product_package_version" ]] || fail "missing current package version in docs/PRODUCT-OPERATING-PLAN.md"
[[ -n "$product_changelog_entry" ]] || fail "missing latest changelog entry in docs/PRODUCT-OPERATING-PLAN.md"
[[ -n "$roadmap_published_release" ]] || fail "missing latest published GitHub release in ROADMAP.md"
[[ -n "$product_published_release" ]] || fail "missing latest published GitHub release in docs/PRODUCT-OPERATING-PLAN.md"
[[ -n "$spec_baseline" ]] || fail "missing snapshot baseline in docs/spec/SPEC-INDEX.md"

[[ "$package_version" == "$product_package_version" ]] || \
  fail "ROADMAP current package version ($package_version) != PRODUCT-OPERATING-PLAN current package version ($product_package_version)"
[[ "$product_changelog_entry" == "$changelog_latest_release" ]] || \
  fail "PRODUCT-OPERATING-PLAN latest changelog entry ($product_changelog_entry) != CHANGELOG latest release ($changelog_latest_release)"
[[ "$product_published_release" == "$roadmap_published_release" ]] || \
  fail "PRODUCT-OPERATING-PLAN latest published release ($product_published_release) != ROADMAP latest published release ($roadmap_published_release)"
[[ "$spec_baseline" == "$package_version" ]] || \
  fail "SPEC-INDEX snapshot baseline ($spec_baseline) != current package version ($package_version)"

[[ -n "$readme_tag" ]] || fail "missing TAG= install pin in README.md"
[[ -n "$readme_ko_tag" ]] || fail "missing TAG= install pin in README.ko.md"
# Installation pins name the published release or the current package.
[[ "$readme_tag" == "$roadmap_published_release" || "$readme_tag" == "$package_version" ]] || \
  fail "README install TAG ($readme_tag) is neither the published release nor the current package"
[[ "$readme_ko_tag" == "$readme_tag" ]] || \
  fail "README.ko install TAG ($readme_ko_tag) != README install TAG ($readme_tag)"

# The same copy-paste block, in the guide the README sends installers to three
# times over. It was left out when the pin above was added, so the lesson in
# the comment there -- a block naming the release before the one the page
# announces -- still had somewhere to happen. Both files are checked against
# README rather than each other: a pair that agrees on a tag nobody published
# still hands the reader a 404.
for install_doc in docs/INSTALL.md docs/INSTALL.ko.md; do
  install_tag="$(extract_single '^TAG=v\([^ ]*\)$' "$install_doc")"
  [[ -n "$install_tag" ]] || fail "missing TAG= install pin in $install_doc"
  [[ "$install_tag" == "$readme_tag" ]] || \
    fail "$install_doc install TAG ($install_tag) != README install TAG ($readme_tag)"
done

# The same block a third time, on the documentation site the project publishes.
# It was left out when each guard above was added, so it kept the tag it was
# born with: v0.35.1 stood while thirteen releases went out, and the page told
# readers to install a version the project had moved past twice over. Here the
# install pin must match the README installation target.
for site_doc in \
  docs-site/src/content/docs/getting-started/quickstart.md \
  docs-site/src/content/docs/ko/getting-started/quickstart.md; do
  site_tag="$(extract_single '^TAG=v\([^ ]*\)$' "$site_doc")"
  [[ -n "$site_tag" ]] || fail "missing TAG= install pin in $site_doc"
  [[ "$site_tag" == "$readme_tag" ]] || \
    fail "$site_doc install TAG ($site_tag) != README install TAG ($readme_tag)"

done

# PR checks compare checked-in documents only. Repository-global tags can
# change after this commit without changing its documentation. The release
# workflow validates its explicit tag with check-version-truth.sh --tag.

# Every local path these docs name must still exist. The glossary is here
# because its `→` coordinates are the term-to-code SSOT: when a file is
# renamed, the entry keeps pointing at the old path and reads as current.
docs_to_scan=(
  README.md
  README.ko.md
  ROADMAP.md
  docs/PRODUCT-OPERATING-PLAN.md
  docs/MCP-TEMPLATE.md
  docs/TUI-GUIDE.md
  docs/spec/SPEC-INDEX.md
  docs/spec/00-glossary.md
  docs/spec/01-system-overview.md
  docs/spec/09-server-transport.md
  docs/spec/10-dashboard.md
  docs/KEEPER-USER-MANUAL.md
  docs/RELEASE-EVIDENCE.md
)

missing_refs=()
for file in "${docs_to_scan[@]}"; do
  rg_or_empty '\((docs/[^)# ]+|ROADMAP\.md|CHANGELOG\.md)\)' "$file"
  links="$(printf '%s\n' "$RG_OUT" | sed 's/^('// | sed 's/)$//')"
  # Leftmost match wins, so [packages/...] comes first: a path such as
  # packages/agent_core/lib/llm_provider/types.mli is one reference, not the
  # lib/... it contains. [mli] is listed before [ml] because alternation takes
  # the first branch that matches and [ml] is a prefix of [mli].
  rg_or_empty '(packages/[A-Za-z0-9._/-]+\.(md|mli|ml|sh|toml)|docs/[A-Za-z0-9._/-]+\.md|lib/[A-Za-z0-9._/-]+\.(mli|ml)|scripts/[A-Za-z0-9._/-]+\.sh|test/[A-Za-z0-9._/-]+\.(mli|ml)|dune-project|[A-Za-z0-9._-]+\.opam|ROADMAP\.md|CHANGELOG\.md)' "$file"
  refs="$(printf '%s\n%s\n' "$links" "$RG_OUT" | sort -u)"
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    [[ "$ref" == *"*"* ]] && continue
    [[ "$ref" == *"..."* ]] && continue
    [[ -e "$ref" ]] || missing_refs+=("$file -> $ref")
  done <<< "$refs"
done

if ((${#missing_refs[@]} > 0)); then
  printf 'doc truth check failed: missing local references detected\n' >&2
  printf '  %s\n' "${missing_refs[@]}" >&2
  exit 1
fi

printf 'Doc truth OK: version, install pins and local references are valid\n'
