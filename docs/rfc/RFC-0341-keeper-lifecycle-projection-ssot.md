# RFC-0341 — Keeper lifecycle projection SSOT

- Status: Accepted
- Updated: 2026-07-13

Keeper lifecycle authority has three sources only:

- enabled/running lane state;
- an explicit operator stop with actor/time provenance;
- a durable Dead tombstone.

Kick queues a turn for a waiting lane. Stop and Boot are explicit operator
commands. Delete is a distinct explicit command. Provider, tool, persistence,
resource, context, retry, and progress failures are observations and never
produce a latch, pause, recovery band, or implicit lifecycle transition.

The backend emits one typed lifecycle value and exact allowed explicit actions;
the dashboard renders them without OR-chains, string matching, or metrics-based
fallback labels. Legacy auto-pause reasons are retired observations and cannot
be migrated into active authority.
