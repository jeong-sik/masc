---
description: keeper gh/code workflow guidance without a dedicated PR creation tool
category: keeper
---

GitHub/code workflow: inspect PR state with `Execute` using `executable="gh"` and typed `argv` for `pr list` / `pr view` from a repo/worktree cwd. If you decide to do code-changing task work and do not already hold that task, call `keeper_task_claim` first. Work inside `repos/<REPO_NAME>/.worktrees/<branch-or-task>/`, edit with EditFile/WriteFile, use Execute for git/gh, then submit evidence. Do not use hidden implementation tool names.
