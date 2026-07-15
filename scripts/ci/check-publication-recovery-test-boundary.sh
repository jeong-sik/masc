#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

test_facade_matches="$({
  rg -n --no-heading \
    '\bPublication_recovery_for_testing\b' \
    lib bin \
    --glob '*.ml' \
    --glob '*.mli' \
    | rg -v \
        '^lib/fs_compat/(fs_compat|publication_recovery_for_testing)\.mli?:' \
    || true
})"

if [[ -n "$test_facade_matches" ]]; then
  echo "publication recovery test surface escaped into production code:" >&2
  echo "$test_facade_matches" >&2
  exit 1
fi

forbidden_fixture_api_matches="$({
  rg -n --no-heading \
    '\b(publication_recovery_record_area|publication_recovery_fixture_error|run_publication_recovery_resource_scope|run_publication_recovery_cleanup_boundary|single_publication_recovery_borrow_balance|publication_recovery_stage_name|seed_prepared_publication_recovery|seed_bound_publication_recovery|write_raw_publication_recovery_record|public_registry)\b' \
    lib/fs_compat/fs_compat.ml \
    lib/fs_compat/fs_compat.mli \
    || true
})"

if [[ -n "$forbidden_fixture_api_matches" ]]; then
  echo "forbidden publication recovery fixture API exists in Fs_compat:" >&2
  echo "$forbidden_fixture_api_matches" >&2
  exit 1
fi

echo "publication recovery test boundary: ok"
