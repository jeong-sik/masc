#!/usr/bin/env bash
# no-inline-json-kind-name.sh — Block inline `Yojson.Safe.t -> string`
# kind classifiers in lib/. Use Json_util.kind_name (declared in
# lib/core/json_util.ml) instead.
#
# Matched by shape, not by identifier. The pattern used to require the
# name `json_kind_name`, so a copy under any other name passed while
# this script printed OK. Five did, under kind_label,
# kind_name_of_json, yojson_variant_name and two spellings of
# kind_name. One says so in its own comment (ide_annotation_types.ml):
# "Name [kind_label] (not [json_kind_name]) slips the
# no-inline-json-kind-name lint regex".
#
# Rationale: PR #16534 (initial 6-site dedup) + #16546 (yojson 3.0
# dead-arm cleanup, 22 sites) + #16572 (final 11-site dedup)
# consolidated ~20 copies of the identical 9-line Yojson.Safe.t kind
# classifier into a single SSOT.  Without a lint guard, the next
# received-kind enrich sprint will reintroduce the boilerplate — AI
# agents learn from codebase statistics, and the SSOT cost (one
# `Json_util.kind_name` call) is small enough that the inline copy
# is "convenient" for an agent producing isolated files.
#
# Allowlisted files fall into two categories:
#   1. SSOT definition itself (lib/core/json_util.ml).
#   2. Sub-libraries whose `dune` declares yojson-only dependencies
#      (RFC-0056 leaf-isolation pattern).  Adding `masc_core` here
#      would break the isolation invariant; the 9-line cost per
#      file is the smaller trade-off.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Each entry's dune declares yojson-only dependencies (RFC-0056 leaf
# isolation), so reaching Json_util would mean adding masc_core and
# breaking that invariant. Verified per dune, not assumed.
ALLOWLIST=(
  # SSOT definition — the canonical helper itself.
  "lib/core/json_util.ml"

  # masc_multimodal — (libraries shared_types unix yojson fs_compat
  # digestif eio masc_random_id); no masc_core.
  "lib/multimodal/payload.ml"
  "lib/multimodal/artifact.ml"

  # masc_ide and shared_audit — same leaf shape, same constraint. Both
  # were invisible to this lint until it matched by shape.
  "lib/ide/ide_annotation_types.ml"
  "lib/shared_audit/envelope.ml"

  # json_field reports OCaml variant names rather than JSON type names
  # on purpose: its .mli documents got = "intlit" / "list" / "assoc"
  # and test_json_field pins them. Not a copy of the canonical mapping.
  "lib/json_field/json_field.ml"
)

matches_file=$(mktemp)
errors_file=$(mktemp)
trap 'rm -f "$matches_file" "$errors_file"' EXIT

count=0
scan_status=0

if command -v rg >/dev/null 2>&1; then
  rg --line-number --no-heading --type ocaml \
    'let [a-z_][A-Za-z0-9_]* : Yojson\.Safe\.t -> string = function' \
    lib/ >"$matches_file" 2>"$errors_file" || scan_status=$?
  if [[ $scan_status -gt 1 ]]; then
    echo "ERROR: ripgrep failed while scanning inline json_kind_name definitions" >&2
    cat "$errors_file" >&2
    exit "$scan_status"
  fi
else
  grep -RInE --include='*.ml' \
    'let [a-z_][A-Za-z0-9_]* : Yojson\.Safe\.t -> string = function' \
    lib/ >"$matches_file" 2>"$errors_file" || scan_status=$?
  if [[ $scan_status -gt 1 ]]; then
    echo "ERROR: grep failed while scanning inline json_kind_name definitions" >&2
    cat "$errors_file" >&2
    exit "$scan_status"
  fi
fi

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

  echo "ERROR: inline Yojson kind classifier (use Json_util.kind_name): $match"
  count=$((count + 1))
done < "$matches_file"

if [[ $count -gt 0 ]]; then
  echo ""
  echo "Found $count inline Yojson kind classifier(s) outside the allowlist."
  echo ""
  echo "Migration guide:"
  echo "  1. Delete the 9-line inline definition."
  echo "  2. Replace each callsite: json_kind_name X  ->  Json_util.kind_name X"
  echo "  3. If the file's library lacks masc_core, either:"
  echo "     - Add masc_core to its dune (lib/<sub>/dune) if isolation allows; or"
  echo "     - Add the file to the ALLOWLIST in this script with a one-line"
  echo "       rationale comment explaining the isolation constraint."
  echo ""
  echo "Background: PR #16534 + #16546 + #16572 closed the boilerplate"
  echo "pattern across the non-isolated surface; this lint prevents"
  echo "regression from future PRs."
  exit 1
fi

echo "OK: no inline Yojson kind classifiers outside allowlist"
exit 0
