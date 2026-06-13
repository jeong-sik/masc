# RFC-0219: Remove Sandbox Repo Patrol Gates

**Status**: Implemented
**Date**: 2026-06-06
**Author**: Vincent + Claude
**Subsystem**: `lib/keeper/keeper_sandbox_repo_lifecycle.ml`, `lib/keeper/keeper_tool_execute_runtime.ml`

## Problem

Keeper Execute pipeline has a set of "repo patrol" gates that pre-emptively
block commands when the sandbox repo checkout is not in an ideal state. These
gates cause deadlocks: the keeper cannot fix the problem because the fix
itself (e.g. `git pull`) requires Execute, which is blocked.

Observed failure (keeper:garnet 2026-06-06):
- Sandbox repo `repos/masc` was 445 commits behind `origin/main`
- `ensure_current` returned `Preserved "uncommitted changes in the working tree"`
  (false positive — repo was actually clean, just behind)
- Every Execute was blocked with `sandbox_repo_stale`
- 5 identical retries → threshold-silence → circuit breaker trip
- Keeper fully paralyzed; required manual `git pull` by operator

## Gates to Remove

### 1. `sandbox_repo_stale` (validate_cwd_sync_ready)

**File**: `keeper_sandbox_repo_lifecycle.ml:198-234`

Checks if sandbox repo is current with origin. Blocks Execute when:
- Behind (uncommitted changes, even if false positive)
- On task branch (not default branch)
- Detached HEAD
- Diverged
- Fast-forward refused

**Why remove**: Keeper can `git pull` / `git checkout main` / `git rebase`
itself. The gate creates a deadlock where the keeper cannot self-heal.

### 2. `sandbox_repo_sync_disabled` (Reject_repo_sync path)

**File**: `keeper_sandbox_repo_lifecycle.ml:89-98`

When keeper is readonly, refuses to even fetch/fast-forward the sandbox.

**Why remove**: Readonly keepers still need current code to read. `git fetch`
+ `git ff-only` is a read operation.

### 3. `sandbox_repo_not_ready` / `sandbox_worktree_not_ready` (validate_repo_path_ready)

**File**: `keeper_sandbox_repo_lifecycle.ml:119-196`

Pre-validates that cwd/path args are valid git checkouts.

**Why remove**: The command itself will fail with a clear git error if the
path isn't a checkout. Pre-validation adds latency and false positives
without adding safety — the failure mode is identical either way.

## Gates to Keep

| Gate | Reason |
|------|--------|
| **Destructive operation** (`is_destructive`) | Prevents `rm -rf`, force-push, etc. |
| **Write operation gated** (`write_enabled`) | Policy: readonly vs write-capable surfaces |

These are safety-critical and do not cause deadlocks.

## Implemented Change

Remove the `before_path_validation` callback that calls
`validate_cwd_ready` and `validate_path_args_ready`. The callback is the
sole call site for repo patrol gates.

Keep `Playground_repo_readiness.ensure_current` available as a utility
for future "keeper self-sync" tools, but do not gate Execute on it.

### Files Changed

- `lib/keeper_tooling/keeper_tool_execute_shell_ir.ml` — remove optional `before_path_validation` hook
- `lib/keeper_tooling/keeper_tool_execute_shell_ir.mli` — remove the hook from public dispatch APIs
- `lib/keeper/keeper_tool_execute_runtime.ml` — remove stale repo-sync cache invalidation residue
- `lib/keeper/keeper_sandbox_repo_lifecycle.ml` — remove the retired repo patrol gate module

`lib/playground_repo_readiness.ml` is intentionally left intact. Its
`ensure_current` utility remains available for future explicit self-sync tools.

### Migration

No migration needed. The gates produce Error results that block Execute;
removing them simply lets commands through to run (and fail naturally if
the repo is genuinely broken).

## Impact

- **Keeper autonomy**: Keepers can self-heal stale repos via `git pull`
- **Reduced operator burden**: No more manual sandbox sync
- **Risk**: A keeper might work against stale code briefly before noticing.
  This is acceptable — the keeper will detect version mismatch from error
  messages or test failures and pull.
- **Latency**: Removes 2-3 git probe subprocess calls per Execute invocation
