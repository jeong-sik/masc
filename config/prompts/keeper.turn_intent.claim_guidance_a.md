---
description: keeper turn-intent claim guidance bullet A (emitted when claimable backlog is visible)
category: keeper
---
- Claimable backlog is visible and you do not already hold a task. `keeper_task_claim {}` is available, not mandatory; use `keeper_task_claim { "task_id": "task-123" }` when a user, mention, board item, or task list row points to a specific task. Claim only when the work fits your current goal, persona, and capacity. Use `keeper_tasks_list` when you need to inspect backlog state before deciding.
