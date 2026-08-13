#!/usr/bin/env bash
# no-model-prose-substring-tests.sh — Block tests that pin a phrase from the
# runtime contract's guidance prose.
#
# Those fields hold sentences written for a model to read. Their wording is a
# prompt-engineering choice and must stay free to change. A test that asserts
# a substring of one converts every rewording into a red build with no change
# in behaviour.
#
# Rationale: #28533 changed "do not repeat the repo prefix" to "...the cwd
# prefix" in keeper_runtime_contract.ml and touched no test. The stale
# substring in test_keeper_tool_call_log.ml turned main red, and because the
# CI Regression Gate aggregates strictly, every open PR was blocked until
# #28540 swapped one string for another -- a fix that leaves the next
# rewording free to do it again.
#
# What a test may assert about these fields: that they are present and carry
# non-empty text. That is the wiring regression worth catching; the sentence
# itself is not a contract.
#
# The guarded field list is READ FROM THE SOURCE, not copied here, so adding a
# guidance field extends the guard automatically.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
contract="${repo_root}/lib/keeper/keeper_runtime_contract.ml"

if [[ ! -f "$contract" ]]; then
  echo "ERROR: cannot find ${contract}" >&2
  exit 1
fi

# Guidance fields are the `( "name"` entries in the path-resolution block:
# each pairs a field name with a `String` sentence on the following lines.
# Read with a while-loop rather than mapfile: this script runs on developer
# macOS too, where the default bash is 3.2 and has no mapfile.
fields=()
while IFS= read -r field; do
  [[ -n "$field" ]] && fields+=("$field")
done < <(grep -oE '\( "[a-z_]+"$' "$contract" | grep -oE '[a-z_]{4,}' | sort -u)

if [[ ${#fields[@]} -eq 0 ]]; then
  echo "ERROR: no guidance fields parsed from ${contract}" >&2
  echo "  The block shape changed; update this lint's extraction." >&2
  exit 1
fi

# A violation is a contains_substring call whose haystack is one of those
# fields. The haystack follows the call, as in
#
#   (String_util.contains_substring
#      Yojson.Safe.Util.(member "execute_path_basis" ... |> to_string)
#      "some phrase")
#
# so the window is the lines AFTER the call, not before. Using -B here is how
# the first draft of this lint passed against a deliberately reintroduced
# violation; the two-way check below the fix is what caught that.
violations=""
for field in "${fields[@]}"; do
  hits="$(grep -rn --include='*.ml' -A4 'contains_substring' "${repo_root}/test" 2>/dev/null \
          | grep -F "\"${field}\"" || true)"
  [[ -n "$hits" ]] && violations+="${hits}"$'\n'
done

if [[ -n "${violations//[[:space:]]/}" ]]; then
  echo "FAIL: a test pins wording from the runtime contract's guidance prose"
  echo ""
  echo "$violations"
  echo "Those fields are sentences written for a model. Rewording them is not a"
  echo "behaviour change, so a substring assertion on one only makes prompt edits"
  echo "expensive -- see #28533 -> #28540."
  echo ""
  echo "Assert the wiring instead:"
  echo "  match Yojson.Safe.Util.member \"<field>\" path_resolution with"
  echo "  | \`String text -> String.trim text <> \"\""
  echo "  | _ -> false"
  exit 1
fi

echo "OK: no test pins runtime-contract guidance wording (${#fields[@]} fields guarded)"
exit 0
