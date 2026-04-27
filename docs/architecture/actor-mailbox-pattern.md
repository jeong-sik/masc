# Actor-Mailbox Pattern in masc-mcp

This document describes the actor-mailbox pattern that already exists
in masc-mcp and the design rules a new use of it should follow. It is
not a proposal — it codifies what `lib/session.ml`, `lib/board_dispatch.ml`,
and `lib/pulse/` already practice.

## TL;DR

The pattern is: **one bounded `Eio.Stream` mailbox + one fiber that
loops on `Stream.take` + a record of immutable state threaded through
the loop**. Cross-fiber callers send messages by `Stream.add` and
optionally await a `Promise` resolver bundled into the message.

```
producer fiber ─── Stream.add ──▶  [bounded mailbox]
                                          │
                                          ▼
                            consumer fiber: let rec loop state =
                              let msg = Stream.take mb in
                              loop (process state msg)
```

## Existing examples

| File | Mailbox | Pattern shape |
|------|---------|---------------|
| `lib/session.ml:56,90,271-278` | `registry.mailbox` (Eio.Stream, cap 10000) + per-session notification queue (cap 1000) | **Request-response.** Each message carries an `Eio.Promise` resolver; consumer resolves it to return data to the caller. |
| `lib/board_dispatch.ml:35,71-89` | `store.flusher_inbox` (cap 1000), commands `Flush` / `Sweep` | **Fire-and-forget.** No resolver — caller does not block on the consumer's progress. |
| `lib/pulse/pulse.ml` | Adaptive tick + per-consumer registration | **Pub-sub-with-tick.** Consumers register first-class modules, receive each beat. |
| `lib/sse.ml:304` | per-client `event_stream` (cap 64) | **Per-subscriber broadcast.** A snapshot of the registry is taken, each subscriber receives via its own stream. |

## When to use this pattern

- **Cross-fiber state synchronization** where the state owns a single
  fiber and other fibers must not touch it directly.
- **Backpressure** is required and an unbounded queue would risk
  memory exhaustion (see #10777 — unbounded streams have already cost
  us a heap blow-up).
- **Failure as a first-class signal** — bounded streams turn a stuck
  consumer into a measurable producer-side block (`Stream.add` waits)
  rather than an invisible drop.

## When NOT to use this pattern

- A single synchronous call already correctly expresses the
  dependency. Wrapping a pure function in a mailbox introduces fiber
  context, scheduling jitter, and a new failure mode (lost messages
  on switch teardown) for no benefit.
- The producer must observe the consumer's state inline (e.g. read a
  computed field, then immediately branch on it). The request-response
  shape works but is heavier than a direct call; only adopt it when
  the consumer truly needs to serialise concurrent access.
- The function would only ever be called from one fiber. Mailboxes
  exist to serialise multi-fiber access. A single-fiber consumer is
  just a function.

## Anti-patterns observed in this repo

1. **Unbounded streams** (`Eio.Stream.create 0`). #10777 — heap
   exhaustion. Always pick a bound, even if it is large.
2. **Split atomic increment then read** — `Atomic.incr; Atomic.get`
   produces duplicate IDs under contention. Use
   `Atomic.fetch_and_add` / `Atomic.compare_and_set` instead. See
   `lib/metrics_store_eio.ml:72-75`.
3. **`Eio.Mutex` across domains** — Eio.Mutex is fiber-scoped within
   a single domain. Cross-domain locking needs `Stdlib.Mutex` or a
   different approach. See `memory/feedback_eio-mutex-vs-stdlib.md`.
4. **`Eio.traceln` inside the critical section** — the fiber yields
   inside `Eio.traceln`, which lengthens the lock window. Capture
   locals first, release the lock, then trace. See
   `memory/feedback_eio-traceln-outside-critical-section.md`.
5. **Naked callback invocation** (PR-J context) — when a mailbox
   message carries a callback closure, invoking it without
   `try/with` lets a transient consumer-side failure abort the
   entire loop step. Wrap with a counter+warn so failures surface as
   metrics rather than logs nobody reads.

## Why this is not a "let's actor-ize the keeper FSMs" plan

The 5 keeper sub-FSMs (KSM/KTC/KDP/KCL/KMC) currently couple via
synchronous direct calls inside `Keeper_unified_turn.run_unified_turn`
(see PR-H test docs and `docs/keeper-fsm-graph.dot`). Refactoring all
five into mailbox actors is a multi-day effort whose benefit hinges on
hypothetical data — frequency of cross-FSM communication, contention
on the shared `Keeper_registry`, observability gain over what
`masc_keeper_fsm_edge_transitions_total` (PR-I) and
`masc_keeper_lifecycle_callback_failures_total` (PR-J) already give us.

The honest path: **measure first** (the counters from PR-I and PR-J
will accumulate four weeks of fleet data), then decide whether
selective migration of one or two sub-FSMs to this pattern is
warranted. Until that data exists, treat sub-FSM actor-ization as
out-of-scope.
