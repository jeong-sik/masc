---
rfc: "0068"
title: "Withdraw operator disposition hierarchy"
status: Withdrawn
updated: 2026-07-13
---

# RFC-0068: Withdraw operator disposition hierarchy

| | |
|---|---|
| Status | Withdrawn |
| Withdrawn | 2026-07-13 |
| Reason | Runtime outcomes must remain observations, not an automatic operator-action or Keeper-lifecycle taxonomy. |

## Historical disposition

The proposed disposition sum combined unrelated provider, tool, completion,
and operator concepts and derived pause/next-action behavior from them. That
layer is removed. Dashboard surfaces render the original typed observation and
its provenance; they do not synthesize a higher disposition.

Only explicit operator commands alter pause/stop state. This file is retained
only as historical context.
