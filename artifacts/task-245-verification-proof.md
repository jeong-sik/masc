# task-245 verification proof

Base: PR #28215 head 06b6117cba179efc829277d0bb3c7ee004f57b16.

## Fix

The isolated test copies lib/keeper/keeper_github_identity.ml, whose current
production path references Fs_compat.remove_tree, Eio, Eio_context, streaming
redaction helpers, and streaming process execution. The test dune previously
declared none of those boundaries.

Added test-only boundaries:

- test/keeper_github_identity/fs_compat.ml: recursive remove_tree cleanup.
- test/keeper_github_identity/eio_context.ml: clockless get_clock_opt boundary
  used by uninvoked streaming code.
- test/keeper_github_identity/keeper_secret_redaction.ml: stream-state
  passthrough helpers for the isolated module.
- test/keeper_github_identity/process_eio.ml: synchronous process-backed
  implementation of the streaming helper used only to typecheck the copied
  module.
- test/keeper_github_identity/dune: declares the two modules and links eio.

The PR-head full-check blockers were also repaired with minimal compile-only
changes so the required repository aliases can run:

- bin/main_eio.ml: expose Masc.Keeper_config to the existing CLI validation.
- lib/keeper_runtime/keeper_event_queue_persistence.ml: pass both sampled
  states to stable_read_only_observation.
- test/test_exact_lane_run_registry.ml: use Option.bind with its option-first
  argument order at both serializer assertions.
- test/test_keeper_antigravity_runtime.ml: close the nested Fun.protect callback.
- test/test_keeper_sandbox_docker_route.ml: expose Masc.Keeper_github_identity
  and define the config path in the turn-runtime assertion.

Production GitHub identity behavior and the fake-gh test fixture remain
unchanged.

## Verification

The full required aliases exited 0:

  dune build --root . --build-dir _build-task245-full2 @check @install

The focused isolated executable exited 0:

  dune build --root . --build-dir _build-task245-full2 test/keeper_github_identity/test_keeper_github_identity.exe
  dune exec --root . --build-dir _build-task245-full2 test/keeper_github_identity/test_keeper_github_identity.exe

Result: Test Successful, 9 tests run.

The directly affected integration targets also built successfully:

  dune build --root . --build-dir _build-task245-focused3     lib/masc.cmxa bin/main_eio.exe     test/keeper_github_identity/test_keeper_github_identity.exe     test/test_exact_lane_run_registry.exe     test/test_keeper_antigravity_runtime.exe     test/test_keeper_sandbox_docker_route.exe

git diff --check exited 0.
