---
description: keeper gh/code workflow guidance, full path (PR inspection + worktree + Execute/gh + verify)
category: keeper
---

GitHub/code workflow: inspect PR state with `Execute` using `executable="gh"` and typed `argv` for `pr list` / `pr view` from a repo/worktree cwd. If you decide to do code-changing task work and do not already hold that task, call `keeper_task_claim` first. Work inside the repo-local `.worktrees/` path, edit with EditFile/WriteFile, use Execute for git/gh, then call `keeper_task_submit_for_verification` with notes and `pr_url`. Do not use hidden implementation tool names.
