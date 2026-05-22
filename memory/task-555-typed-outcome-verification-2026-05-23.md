---
name: task-555-typed-outcome-verification
description: Task-555 Executor Idle-Loop Anti-Pattern typed_outcome chain verification results
metadata:
  type: project
---

# Task-555 Typed Outcome Chain Verification (2026-05-23)

## Status

PR #17913 merged to main (commit `42f2851387`). Full call chain verified end-to-end.

## Call Chain

```
[OAS hook] keeper_hooks_oas.ml:post_tool_use
  -> JSON에서 typed_outcome 추출 + strip_from_json

[Task handlers] keeper_exec_task.ml
  -> keeper_task_result_json / keeper_tool_result_json 에 typed_outcome 필드 포함

[Agent result] keeper_agent_result.ml:tool_call_detail
  -> typed_outcome : Keeper_tool_outcome.t option 필드 정의 + JSON 직렬화

[Turn success] keeper_unified_turn_success.ml:~111
  -> detail.typed_outcome -> classify_tool_progress_with_outcome

[Classification] keeper_tool_disclosure.ml:569
  -> No_progress (No_eligible_tasks) -> Streak_reset_and_empty_queue_sleep

[Detection] keeper_passive_loop_detector.ml:record_turn_effect
  -> streak 리셋 + detection latch 관리
```

## Handler Coverage (9 tools)

| Tool | typed_outcome | Idle-loop relevant |
|------|--------------|-------------------|
| keeper_tasks_list | none (raw JSON) | no |
| keeper_tasks_audit | No_work_available / Progress | yes (No_work_available) |
| keeper_task_force_release | Progress | no |
| keeper_task_force_done | Progress | no |
| keeper_broadcast | Progress | no |
| keeper_task_create | Progress | no |
| keeper_task_claim | **No_eligible_tasks** / none | **yes** — core path |
| keeper_task_done | Progress / none | no |
| keeper_task_submit_for_verification | Progress / none | no |

## Key Path

`keeper_task_claim` → `Coord.Claim_next_no_eligible` with `scope_excluded_count` →
`No_progress { reason = No_eligible_tasks { scope_excluded_count; blocked_count; verification_blocked_count; required_tool_excluded_count; all_goals_excluded } }` →
`classify_tool_progress_with_outcome` → `Streak_reset_and_empty_queue_sleep` →
`record_turn_effect` resets streak and triggers detection latch.

## Tests

`test/test_keeper_passive_loop_detector.ml`: 23/23 PASS (all 4 turn_effect variants + mixed API).

## Blockers

Main branch has 3 unrelated regressions blocking full `dune runtest`:

1. `lib/tool_code_write.ml:707` — `Masc_exec.Exec_dispatch.dispatch` unbound (rename to `dispatch_simple`?)
2. `lib/worker_dev_tools.ml:473` — same
3. `lib/keeper/keeper_shell_ops.ml:1354-1457` — partial match, `Destructive_protected` case missing

These are **not** caused by task-555. Separate hotfix required.
