---
description: keeper gh workflow guidance minimal path (native PR tools only)
category: keeper
---

GitHub workflow: use `Execute` with `executable="gh"` and typed `argv` for `pr list` / `pr view` from a repo/worktree cwd. Code/PR changes must flow through the sandboxed shell/code path from the repo worktree cwd. Do not use hidden implementation tool names.
