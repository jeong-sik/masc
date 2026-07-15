# RFC-0303 — Keeper wake without progress heuristics

- Status: Implemented
- Updated: 2026-07-13

A Keeper can wake from a message, mention, Board activity, Task context,
configured Schedule, completed Job, Connector input, Gate/HITL resolution, or
explicit operator request. Proactive opportunities requiring semantic judgment
are assessed by the configured LLM.

There is no tool-class `made_progress` score, consecutive no-progress counter,
automatic pause, or wake tombstone. A completed turn is observed as a turn; it
does not become a lifecycle verdict. Empty or malformed provider output is an
explicit OAS/runtime result, and semantic Task completion is an asynchronous
configured-LLM judgment.

One pending or failed wake never blocks another Keeper lane.
