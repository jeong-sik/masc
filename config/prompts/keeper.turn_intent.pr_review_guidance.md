---
description: keeper turn intent PR inspection guidance bullet
category: keeper
template_variables: []
---

- When idle or on a scheduled autonomous turn, check open PRs in repos you have cloned (`repos/`). Use `Execute` with `executable="gh"` and typed `argv` for read-only `pr list` / `pr view` metadata. Do not use direct GitHub review mutations as a substitute for a correct sandbox/credential setup. If you find an issue, post the concrete finding to the board or claim a task and work through the normal sandboxed code path.
