---
rfc: "0315"
title: "Typed wake-turn context and self-directed work lane"
status: Active
created: 2026-07-07
updated: 2026-07-10
author: vincent
supersedes: []
superseded_by: null
related: ["0294", "0303", "0310", "0313"]
implementation_prs: []
---

# RFC-0315: Typed wake-turn context and self-directed work lane

A Keeper turn must know why it woke, which task/goal it owns, and which queued
stimuli arrived without inventing a second state protocol.

## Ownership

- The scheduler/heartbeat decision supplies the typed wake reason.
- Goal and Task APIs own objectives, assignment, priority, and status.
- Board, connector, and reaction ledgers own incoming stimuli and delivery
  evidence.
- OAS checkpoints own replayable typed message/tool/reasoning blocks.
- Memory APIs own durable notes. Transcript prose is context only.

The complete boundary is
[`KEEPER-STATE-OWNERSHIP.md`](../KEEPER-STATE-OWNERSHIP.md).

## Turn assembly

`Keeper_unified_turn` passes the scheduler decision and resolved claimed task
into `Keeper_unified_prompt`. `Keeper_world_observation` contributes typed goal
assignment and stimulus observations. Rendering may describe these facts to the
model, but rendered text never becomes their source of truth.

Each Keeper has its own lane. Busy work remains in order; new messages are
queued and may produce an explicit busy acknowledgement. Completion of a
long-running job wakes that Keeper without blocking unrelated lanes.

## Self-directed work

When no immediate stimulus is actionable, a Keeper with an active Goal may
decompose it into typed Tasks, claim eligible work, publish observable progress,
or state a typed blocker through the owning API. A Keeper with no active Goal
may choose work consistent with its persona and tools, but must create or claim
typed work before treating it as an operational objective.

The runtime must not pause solely because a prose summary is absent. Pause/stop
remain explicit lifecycle outcomes for genuine failure or operator action.

## Validation

- `test_keeper_wake_turn_context.ml` pins wake reason, claimed task, and goal
  rendering.
- `test_keeper_event_queue.ml` and reaction-ledger tests pin assignment edges.
- Keeper state-machine tests pin lane lifecycle transitions independently of
  transcript content.
- Replay-checkpoint tests pin typed OAS message/tool/reasoning preservation.
