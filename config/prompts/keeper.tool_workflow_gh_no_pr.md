---
description: keeper gh/code workflow guidance when keeper_pr_create is not in the active policy
category: keeper
---

GitHub/code workflow: if you do not already hold a task, call `keeper_task_claim` first; inspect with `keeper_shell op=gh`; if code change is needed, `masc_worktree_create` -> edit -> `keeper_bash` for `git add` / `git commit` / `git push`. Do not create PRs through `keeper_shell op=gh`; submit verification notes with the pushed branch and request a dedicated draft-PR tool.
