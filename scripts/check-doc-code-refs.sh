#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/check-doc-code-refs.sh [--apply-stamp-day YYYY-MM-DD]

Walks every docs/ markdown with YAML frontmatter containing a `code_refs:`
block and verifies each listed path exists in the repo. Fails with exit 1
if any listed code_refs path is missing.

Rationale: `last_verified` + `code_refs` is a machine-readable claim that
"this doc has been checked against these repo paths on this date". If the
path does not exist, the claim is false and the doc must either update
the ref or drop it. See the Gen33-39 drift sweep history for precedent.

Options:
  --apply-stamp-day YYYY-MM-DD
      Restrict the audit to docs whose `last_verified:` equals this date.
      Useful when a batch frontmatter PR lands and you want to verify only
      that batch without auditing the whole docs tree.

  -h, --help
      Show this help.
EOF
}

stamp_filter=""
while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --apply-stamp-day)
      shift
      [[ $# -gt 0 ]] || { usage >&2; exit 1; }
      stamp_filter="$1"
      shift
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

missing=()

extract_code_refs() {
  local file="$1"
  LC_ALL=C awk -v stamp="$stamp_filter" '
    BEGIN { fm = 0; in_refs = 0; stamp_ok = (stamp == "") ? 1 : 0 }
    /^---[[:space:]]*$/ {
      fm++
      if (fm > 2) exit
      next
    }
    fm == 1 && /^last_verified:[[:space:]]*/ {
      if (stamp != "") {
        split($0, parts, /[[:space:]]+/)
        if (parts[2] == stamp) stamp_ok = 1
      }
      next
    }
    fm == 1 && /^code_refs:[[:space:]]*$/ { in_refs = 1; next }
    fm == 1 && /^[a-zA-Z_][a-zA-Z0-9_]*:/ { in_refs = 0; next }
    fm == 1 && in_refs && /^[[:space:]]+-[[:space:]]+/ {
      sub(/^[[:space:]]+-[[:space:]]+/, "")
      sub(/[[:space:]]*#.*$/, "")
      sub(/[[:space:]]+$/, "")
      if ($0 != "" && stamp_ok) print $0
    }
  ' "$file"
}

while IFS= read -r doc; do
  [[ -z "$doc" ]] && continue
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    # Skip placeholders and glob patterns — they are not meant to be real paths.
    [[ "$ref" == *"<"* ]] && continue
    [[ "$ref" == *"*"* ]] && continue
    if [[ ! -e "$ref" ]]; then
      missing+=("$doc → $ref")
    fi
  done < <(extract_code_refs "$doc")
done < <(find docs -type f -name '*.md' | sort)

if ((${#missing[@]} > 0)); then
  printf 'doc code_refs check failed: %d missing path(s)\n' "${#missing[@]}" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

printf 'Doc code_refs OK: every frontmatter code_refs path exists in the repo\n'
