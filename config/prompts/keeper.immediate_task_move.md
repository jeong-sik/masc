---
description: keeper user-prompt Claimable Work section (emitted when claimable backlog is visible and keeper holds no task)
category: keeper
---
- Claimable backlog exists. `keeper_task_claim {}` may claim the next eligible unclaimed task, but this is an intake option rather than a required move.
- Use keeper_tasks_list to inspect backlog state, diagnose missing work, or verify task lifecycle before deciding. Never substitute Execute probes (ls/cat/find against .masc/, backlog.json, or repo-local task files) for keeper_tasks_list; the runtime blocks those with `task_state_file_probe_blocked`.
- Prefer the strongest live signal: pending mention, board activity, active goal, or submitted verification evidence may be better than claiming unrelated work.
- If you choose to take code-changing task work, claim first and then work through the visible file, edit, and Execute tools from the repo worktree. Create or update a forge PR only after the branch is prepared and the task requires it.
