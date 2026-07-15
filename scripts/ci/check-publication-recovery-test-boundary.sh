#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if ! command -v rg >/dev/null 2>&1; then
  echo "publication recovery boundary scan requires rg" >&2
  exit 2
fi

rg_or_empty() {
  local output status
  if output="$(rg "$@")"; then
    printf '%s' "$output"
  else
    status=$?
    if [[ "$status" -eq 1 ]]; then
      return 0
    fi
    echo "publication recovery boundary scan failed: rg exited ${status}" >&2
    return "$status"
  fi
}

test_facade_candidates="$(
  rg_or_empty -n --no-heading \
    '\bPublication_recovery_for_testing\b' \
    lib bin \
    --glob '*.ml' \
    --glob '*.mli'
)"

test_facade_matches="$(
  rg_or_empty -v \
    '^lib/fs_compat/publication_recovery_for_testing\.mli?:' \
    <<<"$test_facade_candidates"
)"

if [[ -n "$test_facade_matches" ]]; then
  echo "publication recovery test surface escaped into production code:" >&2
  echo "$test_facade_matches" >&2
  exit 1
fi

removed_public_test_path_matches="$(
  rg_or_empty -n --no-heading \
    '\bFs_compat\.(Publication_recovery_for_testing|Capability_write_for_testing)\b' \
    lib bin test \
    --glob '*.ml' \
    --glob '*.mli'
)"

if [[ -n "$removed_public_test_path_matches" ]]; then
  echo "removed publication recovery test path exists:" >&2
  echo "$removed_public_test_path_matches" >&2
  exit 1
fi

forbidden_fixture_api_matches="$(
  rg_or_empty -n --no-heading \
    '\b(Publication_recovery_for_testing|Capability_write_for_testing|publication_recovery_access|publication_recovery_registry|publication_recovery_registry_error|publication_recovery_lane_open_error|publication_recovery_lane_open_error_kind|Publication_recovery_invalid_owner|Publication_recovery_reconciliation_blocked|Publication_recovery_store_failed|open_publication_recovery_registry|publication_recovery_registry_error_to_string|with_publication_recovery_lane|publication_recovery_lane_open_error_to_string|publication_recovery_record_area|publication_recovery_fixture_error|run_publication_recovery_resource_scope|run_publication_recovery_cleanup_boundary|single_publication_recovery_borrow_balance|publication_recovery_stage_name|seed_prepared_publication_recovery|seed_bound_publication_recovery|write_raw_publication_recovery_record|public_registry)\b' \
    lib/fs_compat/fs_compat.ml \
    lib/fs_compat/fs_compat.mli
)"

if [[ -n "$forbidden_fixture_api_matches" ]]; then
  echo "forbidden publication recovery fixture API exists in Fs_compat:" >&2
  echo "$forbidden_fixture_api_matches" >&2
  exit 1
fi

test_library_source_leaks="$(
  rg_or_empty -n --no-heading \
    '\bFs_compat_test_support\b' \
    lib bin \
    --glob '*.ml' \
    --glob '*.mli'
)"

if [[ -n "$test_library_source_leaks" ]]; then
  echo "workspace-only fs_compat test library escaped into production code:" >&2
  echo "$test_library_source_leaks" >&2
  exit 1
fi

internal_library_candidates="$(
  rg_or_empty -n --no-heading \
    '\bFs_compat_internal\b' \
    lib bin \
    --glob '*.ml' \
    --glob '*.mli'
)"

internal_library_source_leaks="$(
  rg_or_empty -v '^lib/fs_compat/' <<<"$internal_library_candidates"
)"

if [[ -n "$internal_library_source_leaks" ]]; then
  echo "package-private fs_compat library escaped its owning directory:" >&2
  echo "$internal_library_source_leaks" >&2
  exit 1
fi

echo "publication recovery test boundary: ok"
