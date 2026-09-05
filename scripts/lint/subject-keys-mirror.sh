#!/usr/bin/env bash
# One rule, two implementations: the key order that names a tool call by one of
# its arguments lives in OCaml (for the terminal UI and the Discord trail) and
# in TypeScript (for the dashboard). The OCaml interface says a third copy "is
# how the three surfaces would start naming the same call differently" -- and
# the two that exist had already drifted before anything checked:
#
#   - the TypeScript list was missing goal_id, agent_name and keeper_name
#   - it had no whole-object fallback, so it answered null where OCaml named
#     the row by its arguments
#   - each side's own tests pinned the opposite answer for the same input
#
# Nothing caught that, because nothing compared them. This does. It is a
# comparison, not a forbidden pattern, so it does not belong in
# check-boundary-guard.sh with the rest.
set -euo pipefail

ocaml_file="lib/keeper/keeper_chat_tool_trail.ml"
ts_file="dashboard/src/components/tool-call-shared.ts"

for f in "$ocaml_file" "$ts_file"; do
  if [ ! -f "$f" ]; then
    echo "subject-keys-mirror: $f is missing; the rule moved and this did not"
    exit 1
  fi
done

# Both lists are string literals between the binding and its closing bracket.
extract_ocaml() {
  awk '/^let '"$2"' =/{inside=1} inside{print} inside && /\]/{exit}' "$1" \
    | grep -o '"[a-z_]*"' | tr -d '"'
}

# Comments come off before the bracket scan, not after: a key's trailing
# comment holds example values ("// Execute: ['git', 'fetch', 'origin']") and
# the ] inside it would end the list early.
extract_ts() {
  sed 's|//.*||' "$1" \
    | { awk '/^const '"$2"' = \[/{inside=1} inside{print} inside && /\]/{exit}'; cat > /dev/null; } \
    | grep -o "'[a-z_]*'" | tr -d "'"
}

status=0

compare() {
  local label="$1" ocaml_name="$2" ts_name="$3"
  local left right
  left="$(extract_ocaml "$ocaml_file" "$ocaml_name")"
  right="$(extract_ts "$ts_file" "$ts_name")"

  if [ -z "$left" ] || [ -z "$right" ]; then
    echo "subject-keys-mirror: could not read $label from one of the two files"
    echo "  ocaml binding: $ocaml_name   ts binding: $ts_name"
    status=1
    return
  fi

  # Order matters as much as membership: the first key that matches wins, so
  # two lists holding the same keys in a different order name the same call
  # differently.
  if [ "$left" != "$right" ]; then
    echo "subject-keys-mirror: $label differs between the two implementations"
    diff <(echo "$left") <(echo "$right") | sed 's/^/    /' || true
    echo "    < $ocaml_file ($ocaml_name)"
    echo "    > $ts_file ($ts_name)"
    status=1
  fi
}

compare "the subject key order" "subject_keys" "SUBJECT_KEYS"
compare "the nested-object keys" "nested_subject_keys" "NESTED_SUBJECT_KEYS"
compare "the nested-first keys" "nested_first_keys" "NESTED_FIRST_KEYS"

if [ "$status" -eq 0 ]; then
  echo "subject-keys-mirror: OK — the three lists match in membership and order"
fi

exit "$status"
