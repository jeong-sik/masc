---
description: keeper gh/code workflow guidance without a dedicated PR creation tool
category: keeper
---

GitHub/code workflow: if you do not already hold a task, call `keeper_task_claim` first. Inspect PR state with `keeper_pr_status` or `keeper_pr_list` when those tools are listed. If code change is needed, `masc_worktree_create` -> edit -> sandboxed shell/code path inside the worktree, then submit evidence. Do not use hidden implementation tool names.
