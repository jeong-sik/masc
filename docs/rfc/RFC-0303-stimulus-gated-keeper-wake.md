---
rfc: "0303"
status: Implemented
---

# RFC-0303 — Keeper wake without progress heuristics

- Status: Implemented
- Updated: 2026-08-02
- Scheduled-autonomous admission remains unconditional: a scheduled heartbeat
  is itself a wake signal. The rejections below (progress scores, no-progress
  counters, automatic pause, wake tombstones) remain in force.

A Keeper can wake from a message, mention, Board activity, Task/Goal context,
configured Schedule, completed Job, Connector input, Gate/HITL resolution, or
explicit operator request. Proactive opportunities requiring semantic judgment
are assessed by the configured LLM.

There is no tool-class `made_progress` score, consecutive no-progress counter,
automatic pause, or wake tombstone. A completed turn is observed as a turn; it
does not become a lifecycle verdict. Empty or malformed provider output is an
explicit agent_core/runtime result, and semantic Task completion is an asynchronous
configured-LLM judgment.

One pending or failed wake never blocks another Keeper lane.
