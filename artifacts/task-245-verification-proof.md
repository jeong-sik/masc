# task-245 verification proof

Base: PR #28215 head `06b6117cba179efc829277d0bb3c7ee004f57b16`.

## Fix

The isolated test copies `lib/keeper/keeper_github_identity.ml`, whose current production path references `Fs_compat.remove_tree`, Eio, Eio_context, streaming redaction helpers, and streaming process execution. The test dune previously declared none of those boundaries.

Added test-only boundaries:

- `test/keeper_github_identity/fs_compat.ml`: recursive `remove_tree` cleanup.
- `test/keeper_github_identity/eio_context.ml`: clockless `get_clock_opt` boundary used by uninvoked streaming code.
- `test/keeper_github_identity/keeper_secret_redaction.ml`: stream-state passthrough helpers for the isolated module.
- `test/keeper_github_identity/process_eio.ml`: synchronous process-backed implementation of the streaming helper used only to typecheck the copied module.
- `test/keeper_github_identity/dune`: declares the two modules and links `eio`.

Production `lib/keeper/keeper_github_identity.ml` and the fake-gh tests are unchanged.

## Verification

Passed:

```
dune build --root . --build-dir _build-task245 test/keeper_github_identity/test_keeper_github_identity.exe
dune exec --root . --build-dir _build-task245 test/keeper_github_identity/test_keeper_github_identity.exe
git diff --check
```

Focused executable result: `Test Successful`, 9 tests run.

The requested repository-wide `dune build --root . --build-dir _build-task245 @check @install` remains blocked by unrelated pre-existing PR-head errors outside this test boundary, including `stable_read_only_observation` arity, `Keeper_config` exposure, unrelated test syntax/type errors, and `test_keeper_sandbox_docker_route.ml`'s `Keeper_github_identity` exposure. The focused target itself builds and runs successfully.
