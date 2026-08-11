# task-260 verification proof

## Scope

Task-260 targets PR #28247 (RFC-0371 B10). The task-recorded head `de13fa17fa2b7bc07fbe45df970b85be71b8c7e` is an ancestor of the fetched current PR head `ec2146112d602d6292ab347e5abefdf62a88d0bb`. The implementation branch is `sangsu/task-260-trajectory`, commit `9f9415b969`.

## Changes

- `packages/agent_core/lib/trajectory.ml`
  - Added `non_blank_tool_use_id`.
  - Both `Tool_execution_started` and `Tool_execution_finished` normalize `None`, `""`, and whitespace-only IDs to unpairable `None`.
  - Nonblank IDs remain unchanged and continue to pair normally.
- `packages/agent_core/test/test_trajectory.ml`
  - Added `test_blank_tool_use_ids_are_unpairable`, covering missing, empty, and whitespace-only IDs on both start and finish records.
  - Existing `test_tool_call_pairing` remains the normal nonblank pairing regression.

## Verification

All commands ran from the task worktree.

- `git diff --check`: exit 0.
- `bash scripts/dune-local.sh build packages/agent_core/test/test_trajectory.exe`: exit 0.
- `bash scripts/dune-local.sh exec packages/agent_core/test/test_trajectory.exe`: exit 0; `Test Successful`; 11 tests run, including `blank tool ids are unpairable`.
- `GITHUB_BASE_REF=fix/antigravity-test-syntax-20260811 python3 scripts/check_test_coverage.py`: exit 0; `Test coverage check passed.`
  The base branch was fetched explicitly, and the check was run after commit `9f9415b969`, so the added test file was included in the exact base-to-HEAD diff.

## CI note

The pre-fix GitHub Test Coverage Check for PR #28247 at head `ec2146112d602d6292ab347e5abefdf62a88d0bb` was observed failing because that head had no changed test file. The equivalent checker passes on the task HEAD with `packages/agent_core/test/test_trajectory.ml` included.
