# task-233 verification proof

## Change

Removed the orphaned `bench_sample` type and its stale documentation from:

- `lib/tool_local_runtime_core.ml`
- `lib/tool_local_runtime_core.mli`

The PR head `a6506ea4b0b1005fff4dc21b3b1c777dac9bd87d` no longer has the local-runtime bench/status consumers. A repository search after the change returned no `bench_sample` matches under `lib`, `test`, `docs`, or `bin`.

## Verification

- `rg -n bench_sample lib test docs bin` — exit 1 with no matches (no remaining callers or declarations).
- `ocamlformat --check lib/tool_local_runtime_core.ml lib/tool_local_runtime_core.mli` — passed.
- `git diff --check` — passed.
- `bash scripts/dune-local.sh build lib/tool_local_runtime_core.ml` — passed.
- `bash scripts/dune-local.sh build lib/masc.cmxa` — passed; only the existing `-j-std` deprecation warning was emitted.
