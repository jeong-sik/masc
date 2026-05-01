#!/usr/bin/env bash
# check-spec-truth.sh — Orphan spec validator.
#
# Verifies that every live `Mirrors:` reference declared in a TLA+ spec file
# points to an OCaml source file (or module) that still exists in the
# codebase.  A spec that references a deleted or renamed implementation
# module is classified as an *orphan spec* and causes CI to fail.
#
# This script is one of the checks run by `make check-ssot`, alongside
# `scripts/check-ssot.sh` and
# `scripts/ci/check-ssot-spawn-drift.sh`.
#
# Meta-issue: #9516 (SSOT root-cause prevention)
#
# Usage:
#   scripts/check-spec-truth.sh          # check; exit 0 = clean / 1 = orphan found / 2 = error
#   scripts/check-spec-truth.sh --verbose
#
# Format of a `Mirrors:` annotation (in TLA+ comment, any leading `\* `):
#   \* Mirrors: lib/some/path.ml
#   \* Mirrors: lib/some/path.ml (optional description)
#   \* Mirrors: Module_name.function_name
#
# Multi-line blocks are also supported — continuation comment lines
# immediately following a `Mirrors:` header are parsed for additional refs:
#
#   \* Mirrors: lib/foo.ml (inline ref on first line)
#   \*          lib/bar.ml (continuation ref on subsequent comment line)
#   \*
#   \* Mirrors:
#   \*   - lib/baz.ml (bullet-list continuation)
#
# Resolution rules (first match wins):
#   1. If the reference starts with `lib/` or `bin/` or `test/` — treat as a
#      repo-relative file path; check existence with `test -f`.
#   2. Otherwise — treat as an OCaml module name (CamelCase or with `.`
#      separator).  Convert to a filename stem by lower-casing the first
#      component before `.`, then look for a matching `.ml` or `.mli` under
#      `lib/`.  E.g. `Keeper_cascade_routing.select_cascade` →
#           look for `lib/**/keeper_cascade_routing.ml`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

VERBOSE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help)
      sed -n '1,/set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: check-spec-truth.sh requires ripgrep (rg)." >&2
  exit 2
fi

fail=0
orphan_count=0
checked_count=0
skipped_count=0

verbose() {
  if [[ $VERBOSE -eq 1 ]]; then
    echo "$*"
  fi
}

# resolve_mirrors_ref <ref_token> → 0 = found, 1 = not found
#
# Callers must not pass empty strings; normalize before calling.
resolve_mirrors_ref() {
  local ref="$1"

  # Strip trailing parenthetical annotation, e.g. "(SelectCascade action)"
  ref="${ref%% (*}"
  ref="${ref%% [*}"

  # Rule 1: explicit repo-relative path
  if [[ "$ref" == lib/* || "$ref" == bin/* || "$ref" == test/* ]]; then
    if [[ -f "$ref" ]]; then
      verbose "  OK  (file) $ref"
      return 0
    else
      return 1
    fi
  fi

  # Rule 2: OCaml module name / qualified identifier
  # Take the first component before `.` for module resolution.
  local module_part="${ref%%.*}"
  # Lower-case: OCaml module names map to lower-case filenames.
  local stem
  stem="$(echo "${module_part}" | tr '[:upper:]' '[:lower:]')"

  # Search for <stem>.ml or <stem>.mli anywhere under lib/
  if rg --files -g "${stem}.ml" lib/ 2>/dev/null | grep -q .; then
    verbose "  OK  (module) $ref → lib/**/${stem}.ml"
    return 0
  fi
  if rg --files -g "${stem}.mli" lib/ 2>/dev/null | grep -q .; then
    verbose "  OK  (module-mli) $ref → lib/**/${stem}.mli"
    return 0
  fi

  return 1
}

# parse_mirrors_blocks <tla_file>
#
# Parses full `Mirrors:` blocks (including continuation comment lines) and
# emits one resolved ref token per line.  Emits the string "SKIP" for any
# block that contains no extractable refs (bare annotation).
#
# Continuation rule: a `Mirrors:` block extends through subsequent TLA+
# comment lines (`\* ...` or `(* ...`) until a blank comment line (`\*`
# alone) or a non-comment line is encountered.
#
# Ref extraction per line: tokens matching `(lib|bin|test)/path` (stopping
# at `:` for `:function_name` suffixes) or `Module.identifier` patterns.
parse_mirrors_blocks() {
  local tla_file="$1"
  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function strip_comment(s) {
      sub(/^[[:space:]]*\\\*[[:space:]]?/, "", s)
      sub(/^[[:space:]]*\(\*[[:space:]]?/, "", s)
      return s
    }
    # Emit path/module ref tokens found in text; return count emitted.
    function emit_refs(text,    i, n, parts, tok, found) {
      found = 0
      n = split(text, parts, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        tok = parts[i]
        # Strip leading bullet markers (e.g. "- lib/..." or "* lib/...")
        gsub(/^[-*]+/, "", tok)
        # Strip trailing punctuation except path chars
        gsub(/[,;)\]>]+$/, "", tok)
        if (tok ~ /^(lib|bin|test)\//) {
          # Strip ":function_name" suffix (e.g. "lib/foo.ml:bar")
          sub(/:.*$/, "", tok)
          print tok
          found++
        } else if (tok ~ /^[A-Za-z][A-Za-z0-9_]*\.[A-Za-z]/) {
          print tok
          found++
        }
      }
      return found
    }
    BEGIN { in_block = 0; block_refs = 0 }
    {
      line = $0
      if (in_block) {
        if (line ~ /^[[:space:]]*\\\*/ || line ~ /^[[:space:]]*\(\*/) {
          text = strip_comment(line)
          if (trim(text) == "") {
            # Blank comment line ends the current block
            if (block_refs == 0) print "SKIP"
            in_block = 0
            next
          }
          block_refs += emit_refs(text)
          next
        }
        # Non-comment line ends the current block
        if (block_refs == 0) print "SKIP"
        in_block = 0
      }
      if (line ~ /Mirrors:/) {
        text = line
        sub(/^.*Mirrors:[[:space:]]*/, "", text)
        in_block = 1
        block_refs = emit_refs(text)
      }
    }
    END {
      if (in_block && block_refs == 0) print "SKIP"
    }
  ' "$tla_file"
}

echo "=== check-spec-truth: scanning TLA+ spec Mirrors: annotations ==="
echo "    Repo root: $REPO_ROOT"
echo ""

# Iterate over every .tla file in specs/
while IFS= read -r -d '' tla_file; do
  rel_file="${tla_file#"${REPO_ROOT}/"}"

  # parse_mirrors_blocks emits one ref token per line, or "SKIP" for bare blocks.
  tokens_file="$(mktemp "${TMPDIR:-/tmp}/check-spec-truth.XXXXXX")"
  if ! parse_mirrors_blocks "$tla_file" > "$tokens_file"; then
    rm -f "$tokens_file"
    echo "ERROR: failed to parse Mirrors: blocks in $rel_file" >&2
    exit 2
  fi

  while IFS= read -r token; do
    if [[ "$token" == "SKIP" ]]; then
      verbose "  SKIP (bare Mirrors: block) in $rel_file"
      ((skipped_count++)) || true
      continue
    fi

    ((checked_count++)) || true

    if resolve_mirrors_ref "$token"; then
      : # resolved
    else
      echo "FAIL: orphan spec reference in $rel_file"
      echo "      Mirrors: $token"
      echo "      Neither a file nor a resolvable OCaml module was found."
      ((orphan_count++)) || true
      fail=1
    fi
  done < "$tokens_file"
  rm -f "$tokens_file"

done < <(find specs -name '*.tla' -print0 2>/dev/null)

echo ""
echo "=== check-spec-truth summary ==="
echo "  Refs checked        : $checked_count"
echo "  Skipped (bare block): $skipped_count"
echo "  Orphan refs found   : $orphan_count"
echo ""

if [[ $fail -eq 0 ]]; then
  echo "PASS: all live Mirrors: references resolve to existing OCaml sources."
else
  echo "FAIL: $orphan_count orphan spec reference(s) detected." >&2
  echo "  Repair: update the Mirrors: annotation to the new file/module path," >&2
  echo "          or remove the annotation if the mechanism was intentionally deleted." >&2
  echo "  Meta-issue: #9516" >&2
fi

exit "$fail"
