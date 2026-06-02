#!/usr/bin/env bash
# no-yojson-3-dead-arms.sh — Block `` `Tuple _ `` and `` `Variant _ ``
# match arms inside `Yojson.Safe.t -> string` (or any) classifier
# helpers.  Yojson 3.0.0 (pinned in masc_mcp.opam.locked) removed
# these two constructors from `Yojson.Safe.t`; an arm matching them
# is dead at best (when the inferred type is broader) and a compile
# error at worst (when unification narrows the input to
# `Yojson.Safe.t`).
#
# Rationale: #16546 (yojson 3.0 cleanup, 22 files) + #16585
# (provenance_stub follow-up) removed all known occurrences.  Without
# this lint, the next received-kind enrich PR or any helper copy
# reintroduces the pattern under a new function name (the name-bound
# lint added in #16578 only catches `let json_kind_name` exactly).
# This script is name-agnostic; it grep's the arm itself.
#
# The pattern is narrow on purpose: `\`Tuple _ -> "tuple"` and
# `\`Variant _ -> "variant"` (with surrounding `|` and indentation
# tolerance).  Other uses of `\`Tuple` or `\`Variant` — e.g., in
# `Yojson.Basic.t` matches where they remain valid, or in unrelated
# polymorphic variants — are unaffected.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ALLOWLIST=(
  # Add files here only when an arm against `Yojson.Basic.t` (which
  # still carries Tuple/Variant) is intentional, with a one-line
  # rationale comment naming the basic-vs-safe distinction.
  #
  # No entries today; every known site uses Yojson.Safe.t.
  ":no-entries:"
)

matches_file=$(mktemp)
errors_file=$(mktemp)
trap 'rm -f "$matches_file" "$errors_file"' EXIT

count=0
scan_status=0

# The pattern is two narrow forms.  We scan each independently and
# concatenate, so the script reports both with line numbers.
scan_one() {
  local pattern="$1"
  if command -v rg >/dev/null 2>&1; then
    rg --line-number --no-heading --type ocaml -e "$pattern" lib/ \
      >>"$matches_file" 2>>"$errors_file" || true
  else
    grep -RInE --include='*.ml' -e "$pattern" lib/ \
      >>"$matches_file" 2>>"$errors_file" || true
  fi
}

scan_one '\| `Tuple _ -> "tuple"'
scan_one '\| `Variant _ -> "variant"'

while IFS= read -r match; do
  [[ -z "$match" ]] && continue
  file=${match%%:*}

  skip=0
  for allowed in "${ALLOWLIST[@]}"; do
    if [[ "$file" == "$allowed" ]]; then
      skip=1
      break
    fi
  done
  [[ $skip -eq 1 ]] && continue

  echo "ERROR: yojson 3.0 dead arm (Tuple/Variant removed from Yojson.Safe.t): $match"
  count=$((count + 1))
done < "$matches_file"

if [[ $count -gt 0 ]]; then
  echo ""
  echo "Found $count yojson 3.0 dead arm(s) outside the allowlist."
  echo ""
  echo "Fix: delete the offending arm(s).  Yojson 3.0.0 removed"
  echo "  | \`Tuple _ -> \"tuple\""
  echo "  | \`Variant _ -> \"variant\""
  echo "from Yojson.Safe.t; the parser never produces these tags, so"
  echo "the arms were already unreachable.  The full match remains"
  echo "exhaustive over the 8 surviving Safe.t tags."
  echo ""
  echo "Background: #16546 (22-file cleanup), #16585 (provenance_stub"
  echo "follow-up) closed the known occurrences.  This lint prevents"
  echo "regression under any helper-function name."
  exit 1
fi

echo "OK: no yojson 3.0 dead arms found"
exit 0
