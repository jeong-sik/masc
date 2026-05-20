---
description: keeper gh workflow guidance minimal path (native PR tools only)
category: keeper
---

GitHub workflow: use the native PR tools shown in your active schema (`keeper_pr_status`, `keeper_pr_review_read`, `keeper_pr_create`, etc.). If no native PR read tool is listed, report that blocker instead of inventing `keeper_shell` or raw `gh pr checks` calls. Do not create PRs through raw `gh pr create`; use the dedicated draft-PR tool when it is listed.
