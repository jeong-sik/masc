---
description: keeper turn intent PR review guidance bullet — active when keeper has coding preset and pr review tools
category: keeper
template_variables: []
---

- When idle or on a scheduled autonomous turn, check open PRs in repos you have cloned (`repos/`). Use `keeper_pr_list` and `keeper_pr_status` only for PR metadata. Do not use retired `keeper_pr_review_*` wrappers or direct GitHub review mutations as a substitute for a correct sandbox/credential setup. If you find an issue, post the concrete finding to the board or claim a task and work through the normal sandboxed code path.
