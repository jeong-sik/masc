# Keeper State Ownership

**Status**: normative
**Updated**: 2026-07-10

Keeper state is represented by typed runtime and domain records. Model-authored
prose is never a state transport.

## Ownership

| Concern | Owner | Canonical representation |
|---|---|---|
| Transcript, provider turn, checkpoint, context reduction | OAS | OAS context and checkpoint types |
| Keeper lifecycle and per-keeper lane position | MASC | keeper lifecycle FSM, event queue, and checkpoint reference |
| Goal and task state | MASC | goal/task stores and typed transitions |
| Board, HITL, connector, scheduler, and Fusion state | MASC | each domain's typed store and events |
| What happened during a turn | MASC/OAS boundary | tool results, execution receipts, and turn records |
| Long-term recall | MASC | memory records written through the memory API |

MASC may consume OAS runtime primitives. OAS must not import MASC domain
concepts or interpret MASC-specific message formats.

## Continuity Contract

Each Keeper advances on one ordered lane. A turn consumes the lane's current
checkpoint plus typed wake events, then produces an updated checkpoint and
observable receipts. Busy keepers keep their current work; newly arrived
events remain queued or receive an explicit acknowledgement through their
own domain path. Completion of asynchronous work wakes only the owning lane.

Conversation history and summaries are input context. They cannot claim a
task, change a goal, resolve HITL, acknowledge a connector event, or schedule
future work. Those transitions require the owning typed API.

Task sequencing and operating constraints are not memory-note categories.
They remain in the task, goal, scheduler, policy, or connector store that owns
the transition. Memory notes may preserve explicit facts, decisions, questions,
goals, or progress with typed provenance, but they never drive a transition.

## Forbidden Protocols

- No model-authored prose envelope is a state transport.
- No parser, stripper, sidecar, dashboard field, or compatibility reader may
  promote assistant text into runtime state.
- No persona-introspection record or UI projection may act as lifecycle truth.
- No state transition is inferred by matching model text.
- No duplicate state cache is derived from an assistant reply.

If a required typed transition fails, surface the typed error and preserve the
event for retry or operator inspection. Never turn it into a successful-looking
assistant message and never silently drop it.

## Validation

A continuity test must prove all of the following from typed evidence:

1. the intended Keeper lane received the wake event;
2. the turn loaded the expected OAS checkpoint;
3. domain mutations have matching tool results or transition receipts;
4. the new checkpoint is durable and can be restored;
5. another Keeper lane continues independently when this lane is busy or fails.

Tests must not ask a model to echo a state template or inspect prose for a
transition.
