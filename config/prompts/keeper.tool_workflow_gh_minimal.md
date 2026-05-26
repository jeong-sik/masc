---
description: keeper gh workflow guidance minimal path (native PR tools only)
category: keeper
---

GitHub workflow: use the native PR inspection tools shown in your active schema (`keeper_pr_status`, `keeper_pr_review_read`) and `Execute` with `executable="gh"` plus typed `argv` for reversible GitHub CLI mutations. If no PR read tool is listed, use scoped `gh pr view/list/checks` through `Execute` from the repo worktree cwd.
