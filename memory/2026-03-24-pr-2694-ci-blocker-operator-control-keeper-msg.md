# PR #2694 CI Blocker: operator control keeper msg bridge

- Date: 2026-03-24
- Related PR: #2694
- Tracking issue: #2698

## Symptom

- GitHub Actions `Build and Test` failed for PR #2694 in run `23444274017`, job `68203518167`.
- The failing assertion is `keeper msg ok` in `/Users/dancer/me/workspace/yousleepwhen/masc-mcp/test/test_operator_control_keeper.ml:239`.

## Reproduction

- PR worktree:
  `dune exec --root /Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/feat/keeper-retry-guard test/test_operator_control.exe`
- Main checkout:
  `dune exec --root /Users/dancer/me/workspace/yousleepwhen/masc-mcp test/test_operator_control.exe`

## Observed Result

- `keeper up ok` passes.
- `keeper msg ok` returns `false`.
- The failure reproduces on both `main` and the PR branch, so it is not introduced by the retry-guard changes in PR #2694.

## Suspected Cause

- The auto team-session bridge path behind `masc_keeper_msg` appears broken or flaky in existing code.
- The failing test is `test_keeper_msg_auto_team_session_bridge`.

## Tried

1. Confirmed the failing GitHub Actions job and extracted the failing step/log.
2. Reproduced locally on the PR worktree.
3. Reproduced locally on `main` to confirm it is a baseline blocker.

## Next Steps

1. Inspect `/Users/dancer/me/workspace/yousleepwhen/masc-mcp/test/test_operator_control_keeper.ml` around line 239 and the `masc_keeper_msg` dispatch path.
2. Trace the keeper/team-session bridge implementation that backs `dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_msg"`.
3. Fix issue #2698 on a separate branch, then rerun PR #2694 checks.

## Gotchas

- PR #2694 itself is locally clean and verified for its touched files.
- Current PR status is blocked by a pre-existing failing test on `main`, not by the retry-guard patch set.
