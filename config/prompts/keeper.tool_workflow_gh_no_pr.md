---
description: keeper gh/code workflow guidance without a dedicated PR creation tool
category: keeper
---

GitHub/code workflow: if you do not already hold a task, call `keeper_task_claim` first. Inspect PR state with `keeper_pr_status` or review context with `keeper_pr_review_read` when those tools are listed. If code change is needed, `masc_worktree_create` -> edit -> `Bash` for `git add` / `git commit` / `git push` with `cwd` inside the worktree, then use `Bash` with `executable="gh"` and typed `argv` for `pr create` or `pr edit`.
