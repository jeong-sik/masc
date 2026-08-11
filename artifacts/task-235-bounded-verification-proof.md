# task-235 bounded verification proof

Base under review: PR #28213 current head `f8d428f38be24ecc485c91fcea45eeca62075a9b`.

Source evidence from `test/test_runtime_codex_app_server.ml`:
- `test_stream_idle_timeout_is_typed` matches
  `Runtime_codex_app_server.Timeout { seconds; turn_accepted = true }`
  and fails if the timeout has `turn_accepted = false`.
- `test_stream_idle_timeout_after_turn_acceptance_is_typed` uses a delayed
  terminal line after turn acceptance and makes the same true assertion; its
  false branch fails with `turn/start acceptance was lost before the idle timeout`.
- `test/test_runtime_codex_app_server.ml` registers both tests in the
  `subscription boundary` suite.
- `test/stanzas/test_runtime_codex_app_server.inc` registers the executable.

Verification:
- `bash scripts/dune-local.sh build test/test_runtime_codex_app_server.exe` -> exit 0.
- `bash scripts/dune-local.sh exec test/test_runtime_codex_app_server.exe` -> exit 0.
- Result: 50 tests run, 50 passed; the accepted-turn timeout tests were cases 18 and 19.
- Worktree was clean and HEAD matched `origin/pr-28213`.
