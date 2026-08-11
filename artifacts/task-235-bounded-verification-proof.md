# task-235 bounded verification proof

Base: PR #28213 current head `f8d428f38be24ecc485c91fcea45eeca62075a9b`.

The timeout contract is now visible in the bounded prefix of
`test/test_runtime_codex_app_server.ml`:
- `accepted_turn_timeout_seconds` matches
  `Timeout { turn_accepted = true }` and fails on false.
- `pre_acceptance_timeout_seconds` matches
  `Timeout { turn_accepted = false }` and fails on true.
- The existing accepted-turn fixtures call the first helper.
- The callback/pre-acceptance fixture calls the second helper.

Verification:
- `ocamlformat --check test/test_runtime_codex_app_server.ml` -> exit 0.
- `git diff --check` -> exit 0.
- `bash scripts/dune-local.sh build test/test_runtime_codex_app_server.exe` -> exit 0.
- `bash scripts/dune-local.sh exec test/test_runtime_codex_app_server.exe` -> exit 0; 50 tests passed.
