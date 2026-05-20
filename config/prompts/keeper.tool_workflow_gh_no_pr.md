---
description: keeper gh/code workflow guidance when keeper_pr_create is not in the active policy
category: keeper
---

GitHub/code workflow: if you do not already hold a task, call `keeper_task_claim` first. Inspect PR state with `keeper_pr_status` or review context with `keeper_pr_review_read` when those tools are listed. If code change is needed, `masc_worktree_create` -> edit -> `Bash` for `git add` / `git commit` / `git push` with `cwd` inside the worktree. Do not create PRs through raw `gh pr create`; submit verification notes with the pushed branch and request a dedicated draft-PR tool.
