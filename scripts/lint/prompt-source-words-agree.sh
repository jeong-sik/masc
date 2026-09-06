#!/usr/bin/env bash
# The three words a prompt's source can be have to be the same three
# everywhere they are written out by hand:
#
#   the producer   lib/prompt_registry/prompt_registry_types.ml
#   the dashboard  dashboard/src/api/dashboard-tools-prompts.ts
#   the TUI        lib/tui_decode.ml
#
# They are asserted in test/, which this repo's CI does not run, so a typo in
# prompt_source_to_string (File -> "files") type-checks, passes every other
# lint, and breaks all three readers with no CI signal. This is the one gate
# that sees every side.
#
# The TUI side arrived later, and closing its string into a variant made a
# rename worse rather than better: the dashboard would mislabel one row, the
# TUI now refuses the whole snapshot. So it is checked here too.
#
# --self-test runs the checker against fixtures instead of the tree.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

producer_words() {
  # The arms of prompt_source_to_string, in the order it writes them.
  sed -n '/^let prompt_source_to_string = function$/,/^$/p' "$1" \
    | grep -oE '"[a-z_]+"' | tr -d '"'
}

dashboard_words() {
  # The PromptSource union's members.
  grep -E "^export type PromptSource = " "$1" \
    | grep -oE "'[a-z_]+'" | tr -d "'"
}

tui_words() {
  # The words decode_prompt_row accepts for a row's source. Only the arms that
  # quote a word count: the value, null, and type arms carry no vocabulary.
  sed -n '/match member "source" json with/,/^  in$/p' "$1" \
    | grep -oE '`String "[a-z_]+"' | grep -oE '"[a-z_]+"' | tr -d '"'
}

compare_words() {
  local left="$1" right="$2" left_label="$3" right_label="$4" label="$5"
  if [ -z "${left}" ]; then
    echo "${label}: found no words on the ${left_label} side" >&2
    return 1
  fi
  if [ -z "${right}" ]; then
    echo "${label}: found no words on the ${right_label} side" >&2
    return 1
  fi
  if [ "${left}" != "${right}" ]; then
    echo "${label}: ${left_label} and ${right_label} do not name the same words" >&2
    echo "  ${left_label}: $(echo "${left}" | tr '\n' ' ')" >&2
    echo "  ${right_label}: $(echo "${right}" | tr '\n' ' ')" >&2
    return 1
  fi
  return 0
}

if [ "${1:-}" = "--self-test" ]; then
  scratch=$(mktemp -d)
  trap 'rm -rf "${scratch}"' EXIT

  printf 'let prompt_source_to_string = function\n  | A -> "one"\n  | B -> "two"\n\n' \
    > "${scratch}/producer.ml"
  printf 'let prompt_source_to_string = function\n  | A -> "one"\n  | B -> "three"\n\n' \
    > "${scratch}/producer-renamed.ml"
  printf 'let something_else = 1\n' > "${scratch}/producer-absent.ml"

  printf "export type PromptSource = 'one' | 'two'\n" > "${scratch}/dashboard.ts"

  cat > "${scratch}/tui.ml" <<'FIXTURE'
  let* pr_source =
    match member "source" json with
    | `String "one" -> Ok A
    | `String "two" -> Ok B
    | `String value -> Error value
    | `Null -> Error (Printf.sprintf "missing required field '%s'" "source")
    | value -> field_type_error "source" "a string" value
  in
FIXTURE
  cat > "${scratch}/tui-renamed.ml" <<'FIXTURE'
  let* pr_source =
    match member "source" json with
    | `String "one" -> Ok A
    | `String "three" -> Ok B
    | `String value -> Error value
  in
FIXTURE
  printf 'let something_else = 1\n' > "${scratch}/tui-absent.ml"

  failures=0
  expect_pass() {
    if ! compare_words "$1" "$2" left right self-test 2>/dev/null; then
      echo "self-test: $3" >&2
      failures=$((failures + 1))
    fi
  }
  expect_fail() {
    if compare_words "$1" "$2" left right self-test 2>/dev/null; then
      echo "self-test: $3" >&2
      failures=$((failures + 1))
    fi
  }

  producer=$(producer_words "${scratch}/producer.ml" | sort)
  dashboard=$(dashboard_words "${scratch}/dashboard.ts" | sort)
  tui=$(tui_words "${scratch}/tui.ml" | sort)

  expect_pass "${producer}" "${dashboard}" "matching producer and dashboard were reported as a mismatch"
  expect_pass "${producer}" "${tui}" "matching producer and TUI were reported as a mismatch"
  expect_fail "$(producer_words "${scratch}/producer-renamed.ml" | sort)" "${dashboard}" \
    "a renamed producer word was not caught against the dashboard"
  expect_fail "${producer}" "$(tui_words "${scratch}/tui-renamed.ml" | sort)" \
    "a renamed TUI word was not caught"
  expect_fail "$(producer_words "${scratch}/producer-absent.ml" | sort)" "${dashboard}" \
    "a missing producer side was not caught"
  expect_fail "${producer}" "$(tui_words "${scratch}/tui-absent.ml" | sort)" \
    "a missing TUI side was not caught"

  # The value/null/type arms must not be read as vocabulary: the null arm
  # quotes the field name, and reading it would let "source" pass as a word.
  if [ "${tui}" != "$(printf 'one\ntwo\n')" ]; then
    echo "self-test: the TUI extractor read something other than the quoted arms: ${tui}" >&2
    failures=$((failures + 1))
  fi

  if [ "${failures}" -ne 0 ]; then
    echo "prompt source words self-test: ${failures} case(s) wrong" >&2
    exit 1
  fi
  echo "prompt source words self-test: the checker fires on a rename on either side and not otherwise"
  exit 0
fi

producer=$(producer_words "${repo_root}/lib/prompt_registry/prompt_registry_types.ml" | sort)
dashboard=$(dashboard_words "${repo_root}/dashboard/src/api/dashboard-tools-prompts.ts" | sort)
tui=$(tui_words "${repo_root}/lib/tui_decode.ml" | sort)

compare_words "${producer}" "${dashboard}" "the producer" "the dashboard" "prompt source words"
compare_words "${producer}" "${tui}" "the producer" "the TUI decoder" "prompt source words"
echo "prompt source words: the producer, the dashboard, and the TUI name the same three"
