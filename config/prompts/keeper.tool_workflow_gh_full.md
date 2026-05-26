---
description: keeper gh/code workflow guidance, full path (PR inspection + worktree + Execute/gh + verify)
category: keeper
---

GitHub/code workflow: if you do not already hold a task, call `keeper_task_claim` first. Inspect PR state with `Execute` using `executable="gh"` and typed `argv` for `pr list` / `pr view` from a repo/worktree cwd. If code change is needed, `masc_worktree_create` -> edit -> sandboxed shell/code path inside the worktree -> `keeper_task_submit_for_verification` with notes and `pr_url`. Do not use hidden implementation tool names.
