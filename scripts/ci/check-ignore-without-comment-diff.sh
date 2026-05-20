#!/usr/bin/env bash
# Fail PRs that add a new `ignore (...)` call without an accepted
# justification comment. Existing debt remains visible through
# scripts/lint-ignore-without-comment.sh and scripts/audit-code-smell.sh.

set -euo pipefail

BASE="${BASE:-}"
HEAD="${HEAD:-HEAD}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --head) HEAD="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$BASE" ]]; then
  BASE="origin/main"
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) is required" >&2
  exit 2
fi

tmp_added="$(mktemp)"
tmp_unjust="$(mktemp)"
tmp_unjust_sites="$(mktemp)"
tmp_fail="$(mktemp)"
trap 'rm -f "$tmp_added" "$tmp_unjust" "$tmp_unjust_sites" "$tmp_fail"' EXIT

git diff --unified=0 --diff-filter=ACMR "$BASE" "$HEAD" -- '*.ml' '*.mli' \
  | perl -ne '
      if (/^\+\+\+ b\/(.+)$/) {
        $file = $1;
        next;
      }
      if (/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/) {
        $line = $1 - 1;
        next;
      }
      next unless defined $file;
      if (/^\+/ && !/^\+\+\+/) {
        $line++;
        $body = substr($_, 1);
        if ($body =~ /^\s*ignore\s+\(/) {
          print "$file:$line\n";
        }
        next;
      }
      if (!/^\-/ && !/^diff --git/ && !/^index / && !/^--- /) {
        $line++;
      }
    ' > "$tmp_added"

if [[ ! -s "$tmp_added" ]]; then
  echo "No new ignore() sites in PR diff."
  exit 0
fi

cut -d: -f1 "$tmp_added" | sort -u \
  | while IFS= read -r file; do
      if [[ -f "$file" ]]; then
        bash scripts/lint-ignore-without-comment.sh --target "$file" || true
      fi
    done > "$tmp_unjust"

awk -F: '{ print $1 ":" $2 }' "$tmp_unjust" | sort -u > "$tmp_unjust_sites"
sort -u "$tmp_added" | grep -Fxf - "$tmp_unjust_sites" > "$tmp_fail" || true

if [[ -s "$tmp_fail" ]]; then
  echo "New ignore() calls require a justification comment:"
  while IFS= read -r site; do
    grep -F "${site}:" "$tmp_unjust" || true
  done < "$tmp_fail"
  echo
  echo "Accepted shapes: WORKAROUND, HACK, fire-and-forget, RFC-XXXX, TODO, See/see."
  exit 1
fi

echo "New ignore() sites are justified."
