# Command Plane (Retired)

| Item | Value |
|------|-------|
| Status | Retired tombstone |
| Active modules | None |
| Active MCP tools | None |
| Persistence owner | None |

The former Command Plane subsystem is not part of the current MASC
architecture. Its implementation, transport names, persistence tree, scoring,
and policy machinery were removed. This file intentionally does not preserve a
second executable specification for that deleted product.

Current concepts stay independent and communicate through their public typed
boundaries:

- Keeper owns one continuous lane and receives wake-up events.
- Task owns planned work state without becoming a Keeper lifecycle constraint.
- Board and Connector publish observations or wake-up events without taking
  ownership of a Keeper lane.
- Runtime selects Provider and Model capabilities.
- Tools submit normalized external-effect requests to Gate.
- Gate applies an explicit configured mode: Always Allow, LLM Auto Judge, or
  nonblocking HITL.
- Operator surfaces project state and request explicit actions; they do not
  create a parallel authorization hierarchy.

No reputation score, organizational rank, budget, cost, turn count, provider
condition, queue depth, or elapsed-time bucket grants or removes tool access.
Those values may be observed, but Gate decisions do not derive from them.

Historical investigation belongs in Git history and withdrawn RFC tombstones,
not in the current behavioral spec.
