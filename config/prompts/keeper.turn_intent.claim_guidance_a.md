---
description: keeper turn-intent claim guidance bullet A (emitted when claimable backlog is visible)
category: keeper
---
- See unclaimed work and you do not already hold a task? Call keeper_task_claim with {}. It auto-claims the next eligible task; you do not need a task_id argument. keeper_tasks_list remains the canonical way to inspect backlog state — use it any time you need to diagnose what work exists, not just when the claim returns empty.
