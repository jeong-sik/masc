---
title: "Withdraw recording-error dedup and metric sunset gates"
rfc: "0144"
status: Withdrawn
created: 2026-05-20
updated: 2026-07-13
implementation_prs: []
---

# RFC-0144: Withdraw recording-error dedup and metric sunset gates

## Decision

Withdraw registry-side error suppression, time-window occurrence thresholds,
metric-based removal gates, stale-turn categories, and recurring soak checks.

Every source boundary returns and records its typed error. Observability may
aggregate occurrences, but counts and elapsed time cannot demote an error,
change a later call, force retry, or acquire Keeper lifecycle authority. Remove
the workaround directly with its callers instead of waiting for an arbitrary
metric threshold.
