# Notification refresh scheduling

The trailing400ms debounce delayed history refresh until broadcast traffic quieted. An actual action fixture failed before the change: same-batch notifications did not initiate a read without advancing wall-clock timers.

Replace fixed quiet-period timing with typed Scheduled(token) / Running(token,invalidated) states. Same-batch notifications coalesce into one microtask. While that scheduler-owned read runs, notifications invalidate its publication authority and request one follow-up. On settlement, a follow-up starts if and only if another notification occurred. Token checks prevent stale/reset completion from scheduling work. Explicit forced hydration by other callers remains governed by existing request tokens and can overlap; this change bounds notification-owned reads.

Independent hostile review found the first microtask-only candidate allowed unbounded overlapping reads; the typed running state addresses that P2. Deferred fixtures cover multiple event batches, superseded success/failure, one read followed by one latest read, no wall-clock wait and busy-state completion. Full keeper-actions suite passed78tests; TypeScript noEmit and diffcheck passed. No CI dispatch or local Dune build. Actual transport/runtime/screenshot proof and formal approval remain unverified.
