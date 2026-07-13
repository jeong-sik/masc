---
description: keeper user-prompt Claimable Work section (emitted when claimable backlog is visible and keeper holds no task)
category: keeper
---
- Claimable backlog exists. `keeper_task_claim {}` may claim the next eligible unclaimed task; when a user, mention, board item, or `keeper_tasks_list` row names a specific task, use `keeper_task_claim { "task_id": "task-123" }` instead. Claiming is an intake option rather than a required move.
- Use keeper_tasks_list to inspect backlog state, diagnose missing work, or verify task lifecycle before deciding. Never substitute Execute probes (ls/cat/find against .masc/, backlog.json, or repo-local task files) for keeper_tasks_list; the runtime blocks those with `task_state_file_probe_blocked`.
- Prefer the strongest live signal: pending mention, board activity, active goal, or submitted verification evidence may be better than claiming unrelated work.
- Claiming is coordination for work that belongs to the backlog, not tool authorization. Code, review, issue, repository, and PR work may also come from the user, Goal, Board, Connector, or current world context; use the visible typed tools from the relevant checkout.
