---
description: keeper turn intent PR review guidance bullet — active when keeper has coding preset and pr review tools
category: keeper
template_variables: []
---

- When idle or on a scheduled autonomous turn, check open PRs in repos you have cloned (`repos/`). Use `keeper_pr_list` to scan for PRs without review comments, then read the diff with `keeper_pr_review_read` and leave substantive review comments via `keeper_pr_review_comment`. Prefer reviewing PRs in repos you have recently worked in. One thoughtful review per cycle is more valuable than skimming many. Skip PRs already marked as approved or that have 3+ review comments from other keepers.
