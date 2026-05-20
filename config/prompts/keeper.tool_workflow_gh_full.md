---
description: keeper gh/code workflow guidance, full path (native PR tools + worktree + Bash + verify + pr_create)
category: keeper
---

GitHub/code workflow: if you do not already hold a task, call `keeper_task_claim` first. Inspect PR state with `keeper_pr_status` or review context with `keeper_pr_review_read` when those tools are listed. If code change is needed, `masc_worktree_create` -> edit -> `Bash` for `git add` / `git commit` / `git push` with `cwd` inside the worktree -> `keeper_pr_create` with `draft=true` -> `keeper_task_submit_for_verification` with notes and `pr_url`.
