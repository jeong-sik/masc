#!/usr/bin/env bash
# The three words a prompt's source can be, as OCaml writes them and as the
# dashboard's TypeScript reads them, have to be the same three.
#
# They are asserted in test/, which this repo's CI does not run, so a typo in
# prompt_source_to_string (File -> "files") type-checks, passes every other
# lint, and breaks the dashboard's source filter and the TUI's label with no
# CI signal. This is the one gate that sees both sides.
#
# --self-test runs the checker against fixtures instead of the tree.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

ocaml_words() {
  # The arms of prompt_source_to_string, in the order it writes them.
  sed -n '/^let prompt_source_to_string = function$/,/^$/p' "$1" \
    | grep -oE '"[a-z_]+"' | tr -d '"'
}

typescript_words() {
  # The PromptSource union's members.
  grep -E "^export type PromptSource = " "$1" \
    | grep -oE "'[a-z_]+'" | tr -d "'"
}

compare() {
  local ocaml_file="$1" ts_file="$2" label="$3"
  local left right
  left=$(ocaml_words "${ocaml_file}" | sort)
  right=$(typescript_words "${ts_file}" | sort)
  if [ -z "${left}" ]; then
    echo "${label}: found no prompt_source_to_string arms in ${ocaml_file}" >&2
    return 1
  fi
  if [ -z "${right}" ]; then
    echo "${label}: found no PromptSource union in ${ts_file}" >&2
    return 1
  fi
  if [ "${left}" != "${right}" ]; then
    echo "${label}: the two sides do not name the same words" >&2
    echo "  OCaml:      $(echo "${left}" | tr '\n' ' ')" >&2
    echo "  TypeScript: $(echo "${right}" | tr '\n' ' ')" >&2
    return 1
  fi
  return 0
}

if [ "${1:-}" = "--self-test" ]; then
  scratch=$(mktemp -d)
  trap 'rm -rf "${scratch}"' EXIT
  printf 'let prompt_source_to_string = function\n  | A -> "one"\n  | B -> "two"\n\n' \
    > "${scratch}/agree.ml"
  printf "export type PromptSource = 'one' | 'two'\n" > "${scratch}/agree.ts"
  printf 'let prompt_source_to_string = function\n  | A -> "one"\n  | B -> "three"\n\n' \
    > "${scratch}/differ.ml"
  printf "export type PromptSource = 'one' | 'two'\n" > "${scratch}/differ.ts"
  printf 'let something_else = 1\n' > "${scratch}/absent.ml"

  failures=0
  if ! compare "${scratch}/agree.ml" "${scratch}/agree.ts" self-test 2>/dev/null; then
    echo "self-test: matching words were reported as a mismatch" >&2
    failures=$((failures + 1))
  fi
  if compare "${scratch}/differ.ml" "${scratch}/differ.ts" self-test 2>/dev/null; then
    echo "self-test: a renamed word was not caught" >&2
    failures=$((failures + 1))
  fi
  if compare "${scratch}/absent.ml" "${scratch}/agree.ts" self-test 2>/dev/null; then
    echo "self-test: a missing OCaml side was not caught" >&2
    failures=$((failures + 1))
  fi
  if [ "${failures}" -ne 0 ]; then
    echo "prompt source words self-test: ${failures} case(s) wrong" >&2
    exit 1
  fi
  echo "prompt source words self-test: the checker fires on a rename and not otherwise"
  exit 0
fi

compare \
  "${repo_root}/lib/prompt_registry/prompt_registry_types.ml" \
  "${repo_root}/dashboard/src/api/dashboard-tools-prompts.ts" \
  "prompt source words"
echo "prompt source words: OCaml and the dashboard name the same three"
