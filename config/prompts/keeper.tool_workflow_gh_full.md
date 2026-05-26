---
description: keeper gh/code workflow guidance, full path (PR inspection + worktree + Execute/gh + verify)
category: keeper
---

GitHub/code workflow: if you do not already hold a task, call `keeper_task_claim` first. Inspect PR state with `keeper_pr_status` or `keeper_pr_list` when those tools are listed. If code change is needed, `masc_worktree_create` -> edit -> sandboxed shell/code path inside the worktree -> `keeper_task_submit_for_verification` with notes and `pr_url`. Do not use retired `keeper_pr_review_*` wrappers.
