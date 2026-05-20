---
description: keeper user-prompt Immediate Task Move section (emitted when claimable backlog is visible and keeper holds no task)
category: keeper
---
- Call keeper_task_claim with {} to claim the next eligible unclaimed task.
- For the routine claim flow, call keeper_task_claim directly; use keeper_tasks_list to inspect backlog state, diagnose missing work, or verify task lifecycle. Never substitute Bash probes (ls/cat/find against .masc/, backlog.json, or repo-local task files) for keeper_tasks_list — the runtime blocks those with `task_state_file_probe_blocked`.
- Prefer keeper_task_claim before keeper_board_list or passive file/search tools when you have no claimed task.
- If you need PR/GitHub context, claim first and then use the native PR tools shown in your active schema.
