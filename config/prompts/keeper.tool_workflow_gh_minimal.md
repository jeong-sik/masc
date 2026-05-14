---
description: keeper gh workflow guidance minimal path (only keeper_shell is in the active policy)
category: keeper
---

GitHub workflow: use `keeper_shell op=gh` only for commands supported by your active tool policy. `keeper_shell op=gh` derives repo context from the active task worktree/current_task_id; claim a task first when repo context is required. Do not create PRs through `keeper_shell op=gh`; use the dedicated draft-PR tool when it is listed.
