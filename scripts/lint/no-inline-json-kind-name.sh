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
# The second category is gone. It read: sub-libraries whose `dune`
# declares yojson-only dependencies cannot reach Json_util without
# taking masc_core, so a copy each is the smaller trade-off. The
# premise was right and the conclusion was not — the answer to a
# library that cannot take masc_core is a dependency it can take.
# `lib/shared_types/json_kind.ml` is that library, proposed in the
# body of PR #16915 and in the comment on the copy that renamed
# itself to slip this lint; it exists now, and every one of those
# files reaches it.
#
# One entry of that category was also simply wrong: shared_audit's
# dune has listed masc_core all along, so Json_util was always
# reachable from it.
#
# What is left:
#   1. The mapping itself (lib/shared_types/json_kind.ml).
#   2. lib/json_field/json_field.ml, which is not a copy: it reports
#      OCaml variant names, its .mli documents them, and its tests
#      pin them.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Each entry's dune declares yojson-only dependencies (RFC-0056 leaf
# isolation), so reaching Json_util would mean adding masc_core and
# breaking that invariant. Verified per dune, not assumed.
ALLOWLIST=(
  # The mapping itself — a yojson-only leaf, so the libraries that keep
  # RFC-0056 isolation reach it without taking masc_core.
  "lib/shared_types/json_kind.ml"

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
  echo "  2. Replace each callsite: json_kind_name X  ->  Json_kind.name X"
  echo "     (or Json_util.kind_name X, which is the same mapping, where"
  echo "      the library already takes masc_core)"
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
