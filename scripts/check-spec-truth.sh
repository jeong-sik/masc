#!/usr/bin/env bash
# check-spec-truth.sh — Orphan spec validator.
#
# Verifies that every live `Mirrors:` reference declared in a TLA+ spec file
# points to an OCaml source file (or module) that still exists in the
# codebase.  A spec that references a deleted or renamed implementation
# module is classified as an *orphan spec* and causes CI to fail.
#
# This is one half of the `make check-ssot` gate (fingerprint diff side is
# handled by scripts/ci/check-ssot-spawn-drift.sh and
# scripts/ci/check-tla-variant-sync.sh).
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
# Resolution rules (first match wins):
#   1. If the reference starts with `lib/` or `bin/` or `test/` — treat as a
#      repo-relative file path; check existence with `test -f`.
#   2. Otherwise — treat as an OCaml module name (CamelCase or with `.`
#      separator).  Convert to a filename stem by lower-casing and replacing
#      `.` with `/`, then look for a matching `.ml` or `.mli` under `lib/`.
#      E.g. `Keeper_cascade_routing.select_cascade` →
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
resolve_mirrors_ref() {
  local ref="$1"

  # Strip trailing parenthetical annotation, e.g. "(SelectCascade action)"
  ref="${ref%% (*}"
  ref="${ref%% [*}"

  # Empty ref (bare `Mirrors:` with no path) is intentionally skipped.
  if [[ -z "$ref" ]]; then
    return 2
  fi

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
  # Convert CamelCase or snake_case module name to filename stem.
  # Lower-case the whole thing; module names are already snake_case in OCaml.
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

echo "=== check-spec-truth: scanning TLA+ spec Mirrors: annotations ==="
echo "    Repo root: $REPO_ROOT"
echo ""

# Iterate over every .tla file in specs/
while IFS= read -r -d '' tla_file; do
  rel_file="${tla_file#"${REPO_ROOT}/"}"

  # Extract Mirrors: lines; strip TLA+ comment prefix `\* ` or `(* `.
  while IFS= read -r raw_line; do
    # Extract everything after `Mirrors:` (may be empty for bare annotation).
    ref_raw="${raw_line#*Mirrors:}"
    # Strip leading whitespace from the reference token.
    ref_raw="$(echo "$ref_raw" | sed 's/^[[:space:]]*//')"

    ((checked_count++)) || true

    if [[ -z "$ref_raw" ]]; then
      # Bare `Mirrors:` line — nothing to resolve; skip.
      verbose "  SKIP (bare Mirrors:) in $rel_file"
      ((skipped_count++)) || true
      continue
    fi

    resolve_mirrors_ref "$ref_raw"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      : # resolved
    elif [[ $rc -eq 2 ]]; then
      verbose "  SKIP (empty ref) in $rel_file"
      ((skipped_count++)) || true
    else
      echo "FAIL: orphan spec reference in $rel_file"
      echo "      Mirrors: $ref_raw"
      echo "      Neither a file nor a resolvable OCaml module was found."
      ((orphan_count++)) || true
      fail=1
    fi
  done < <(rg --no-filename 'Mirrors:' "$tla_file" 2>/dev/null || true)

done < <(find specs -name '*.tla' -print0 2>/dev/null)

echo ""
echo "=== check-spec-truth summary ==="
echo "  Annotations checked : $checked_count"
echo "  Skipped (bare/empty): $skipped_count"
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
