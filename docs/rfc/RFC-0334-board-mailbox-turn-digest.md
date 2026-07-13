# RFC-0334 — Board signals as durable Keeper input

- Status: Superseded by the Keeper Board-attention boundary
- Updated: 2026-07-13

The earlier design coupled Board delivery to a local fanout limit and an
arrival-time batching window. That made a process-local scheduling choice decide
which Keepers could observe a persisted Board event. It also kept a diagnostic
projection for an intentionally discarded signal.

The current boundary is simpler:

1. A Board event is persisted before attention judgment.
2. Each Keeper has an independent durable candidate lane.
3. The configured model decides relevance from the complete persisted Board,
   Goal, Task, and Keeper context.
4. A relevant verdict enqueues an exact typed event identity for that Keeper.
5. Queue persistence and exact identity provide restart recovery without a
   global fleet decision or product-specific effect policy.
6. Board author, post kind, and exact-mention state remain source/routing
   metadata. They do not form a local authority ranking; the configured model
   interprets the content in its complete context.

The old fixed fanout and arrival-window plan is archival only. No runtime,
metric, dashboard, or test surface may depend on it.
