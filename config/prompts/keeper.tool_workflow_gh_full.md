---
description: keeper gh/code workflow guidance, full path (shell + worktree + bash + verify + pr_create)
category: keeper
---

GitHub/code workflow: if you do not already hold a task, call `keeper_task_claim` first; `keeper_shell op=gh` derives repo context from the active task worktree/current_task_id. Then inspect with `keeper_shell op=gh`; if code change is needed, `masc_worktree_create` -> edit -> `keeper_bash` for `git add` / `git commit` / `git push` -> `keeper_pr_create` with `draft=true` -> `keeper_task_submit_for_verification` with notes and `pr_url`.
