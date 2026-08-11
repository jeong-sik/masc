# task-265 rate-limit decoder proof

Base PR head: e222202e140973e96e4de088af8e8ea7ee6d222e.

Implementation evidence:
- `lib/types/masc_error.ml` uses an explicit `Result` decoder.
- The root decoder rejects non-object JSON with `rate_limit must be object, got <type>`.
- Integer and numeric fields reject wrong JSON types with field-specific messages.
- `priority_agents` rejects non-string elements and reports the zero-based failing index.
- Missing fields retain `default_rate_limit` values.

Regression evidence:
- `test/test_types_coverage.ml` covers valid decoding, default decoding, wrong scalar type, non-object input, and a mixed `priority_agents` array.
- `ocamlformat --check test/test_types_coverage.ml`: passed.
- `git diff --check`: passed.
- `bash scripts/dune-local.sh build test/test_types_coverage.exe`: passed.
- `bash scripts/dune-local.sh exec test/test_types_coverage.exe`: passed, 174 tests run.

Contract evidence:
- artifact:lib/types/masc_error.ml rejects wrong scalar field types and non-object rate-limit JSON with descriptive Error results
- artifact:lib/types/masc_error.ml rejects mixed/non-string priority_agents entries with the failing index
- artifact:test/test_types_coverage.ml covers wrong scalar types, mixed arrays, and valid/default decoding
