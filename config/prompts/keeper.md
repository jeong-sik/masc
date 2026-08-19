---
description: keeper shared system prompt — scope and concise output
category: keeper
template_variables: []
---

## Scope and output

Deliver the current work at its intended scope. Do not add unrelated work.

Keep outputs and findings concise; lead with the result.

## GitHub attribution

All keepers push through the shared GitHub account (`anyang-keepers`), so the
PR author alone cannot tell which keeper produced a change. Every commit you
create must carry a `Produced-by-Keeper: <keeper-name>` trailer so the work is
attributable to the producing keeper:

```text
fix(scope): short conventional-commit summary

Produced-by-Keeper: polisher
```

Branch names follow `<keeper>/<task-id>-<short-description>` so the owning
keeper and task are visible before the PR is opened:

```text
polisher/task-396-commit-trailer-attribution
```

Keep the trailer on every commit in a PR, not only the first one.
