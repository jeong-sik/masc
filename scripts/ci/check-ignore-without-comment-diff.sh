#!/usr/bin/env bash
# Fail PRs that add an `ignore` call without an accepted justification
# comment. Existing debt stays visible through
# scripts/lint-ignore-without-comment.py and scripts/audit-code-smell.sh.
#
# This script deliberately does NOT know what an `ignore` site looks like.
# It used to, with its own `^\s*ignore\s+\(` regex beside the lint's, and the
# two drifted in the same direction: both saw the flat one-line shape and
# neither saw the folded one ocamlformat writes for long arguments. So a
# folded site added by a PR passed the gate while the lint reported the file
# as clean.
#
# The split here is: this script decides which lines a PR added, the lint
# decides which lines are sites. One definition, in one place.

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

tmp_added="$(mktemp)"
tmp_files="$(mktemp)"
tmp_unjust="$(mktemp)"
tmp_fail="$(mktemp)"
trap 'rm -f "$tmp_added" "$tmp_files" "$tmp_unjust" "$tmp_fail"' EXIT

# Every line this PR added, as file:line. No filtering by content.
git diff --unified=0 --diff-filter=ACMR "$BASE" "$HEAD" -- '*.ml' '*.mli' \
  | perl -ne '
      if (/^\+\+\+ b\/(.+)$/) { $file = $1; next; }
      if (/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/) { $line = $1 - 1; next; }
      next unless defined $file;
      if (/^\+/ && !/^\+\+\+/) { $line++; print "$file:$line\n"; next; }
      if (!/^\-/ && !/^diff --git/ && !/^index / && !/^--- /) { $line++; }
    ' > "$tmp_added"

# Keep this aligned with the lint: test files are fixture-heavy and are
# excluded from the baseline scan by default.
grep -Ev '(^test/|/test/)' "$tmp_added" > "$tmp_added.notest" || true
mv "$tmp_added.notest" "$tmp_added"

if [[ ! -s "$tmp_added" ]]; then
  echo "No OCaml lines added in PR diff."
  exit 0
fi

cut -d: -f1 "$tmp_added" | sort -u | while IFS= read -r f; do
  [[ -f "$f" ]] && printf '%s\n' "$f"
done > "$tmp_files"

if [[ ! -s "$tmp_files" ]]; then
  echo "No changed OCaml files present in the working tree."
  exit 0
fi

# shellcheck disable=SC2046
python3 scripts/lint-ignore-without-comment.py --include-tests \
  --target $(tr '\n' ' ' < "$tmp_files") > "$tmp_unjust" || true

awk -F: '{ print $1 ":" $2 }' "$tmp_unjust" | sort -u \
  | grep -Fxf "$tmp_added" - > "$tmp_fail" || true

if [[ -s "$tmp_fail" ]]; then
  echo "New ignore calls require a justification comment:"
  while IFS= read -r site; do
    grep -F "${site}:" "$tmp_unjust" || true
  done < "$tmp_fail"
  echo
  echo "Accepted shapes: WORKAROUND, HACK, fire-and-forget, RFC-XXXX, TODO, See/see."
  echo "The comment goes on the same line or the line directly above."
  exit 1
fi

echo "New ignore sites are justified."
