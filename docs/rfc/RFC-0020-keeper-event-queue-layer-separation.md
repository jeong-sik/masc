# RFC-0020: Keeper heartbeat — Event Layer / Policy Layer separation

- **Status**: Draft
- **Author**: vincent (with Claude)
- **Created**: 2026-04-30
- **Related**: RFC-0002 (keeper state machine), RFC-0003 (composite lifecycle), `specs/keeper-state-machine/KeeperEventQueue.tla` (#12386), `specs/keeper-state-machine/KeeperHeartbeat.tla`
- **Drives**: split the heartbeat data channel from the heartbeat policy channel so an inbound stimulus is never silently delayed by a `Skip_idle` decision

## 1. Problem (field-verified)

Today the keeper heartbeat path entangles two concerns that operate on different timescales:

- **Event Layer** — asynchronous external stimuli: board posts, mentions, operator directives, message arrivals. Latency-critical (operator UX expects sub-second propagation).
- **Policy Layer** — periodic internal decisions: heartbeat tick, `Skip_idle` cooldown, noop backoff, generation lineage clamps. Resource-management focused.

These two layers share a single OCaml code path (`Keeper_keepalive.run_smart_heartbeat_gate` calling `Heartbeat_smart.should_emit` calling `interruptible_sleep`) and a single piece of cross-fiber state (`registry_entry.fiber_wakeup : bool Atomic.t`). The result is a starvation race spelled out in `RUTHLESS_JUDGMENT.md` §1 A5:

```
[Event Layer]                       [Policy Layer]
board post arrives                  heartbeat tick:
   ↓                                  Heartbeat_smart.should_emit (meta, obs)
wakeup_keeper(name)                       ↓
   ↓                                  Skip_idle ?  sleep  :  Emit
Atomic.set fiber_wakeup true              ↓
                                      [conflict] wakeup arrived
                                      but the policy already
                                      committed to sleep
```

The bug is structural: `fiber_wakeup` is a **hint signal**, not a **data channel**. A hint can be silently dropped by a busy policy decision. The runtime has no place to put the actual stimulus, so the only way to recover is to wait for the next periodic tick — which by definition violates the operator-latency assumption.

The first attempt to repair this (`FORMAL_FIX_DESIGN.md`) tried to formalise the existing entanglement with `[@@deriving tla]` and `pending_buffer`. That proposal rests on six assumptions, none verified end-to-end (PPX existence, runtime-vs-spec semantics match, side-channel removal, finite-model coverage of infinite state, urgency budget, polymorphic variant safety). The conclusion in `RUTHLESS_JUDGMENT.md` §1 — *"this design rests on sand"* — stands. We replace it with an architectural separation that does not depend on a derived PPX.

## 2. Design principles

| # | Principle | Concrete consequence |
|---|-----------|----------------------|
| P1 | **Data channel ≠ hint signal.** Stimulus payload lives in an Event Layer queue; `fiber_wakeup` survives only as a "wake from sleep" hint. | `enqueue` is a pure data write; `wakeup` is a separate Atomic flip. Either may happen without the other. |
| P2 | **Policy is gated, not interleaved.** The Smart Heartbeat decision applies *only when the queue is empty*. A non-empty queue overrides the policy and forces an `Emit`. | `Heartbeat_smart.should_emit` is unchanged; its caller (`run_smart_heartbeat_gate`) consults the queue first. |
| P3 | **Layer ownership is module-level.** `Keeper_event_queue` owns dedup, urgency, FIFO. The keeper heartbeat owns timing, cooldown, backoff. Neither module reads or writes the other's state. | Event Layer is a self-contained module with property tests; Policy Layer's existing tests stay intact. |
| P4 | **Manual TLA+ first, PPX never.** The model fits on one page and runs in TLC < 1s. Adding `[@@deriving tla]` is a separate, optional optimisation that may follow once the manual spec proves stable in CI. | `specs/keeper-state-machine/KeeperEventQueue.tla` ships with both clean (`Spec`) and buggy (`SpecBuggy`) configurations. CI gates both. |
| P5 | **PR queue mirrors module layers.** Each PR is responsible for one layer transition. A PR that fails CI does not block sibling layers — exactly the separation we are buying inside the code. | Six-PR plan (§6). Half are already merged at the time of writing. |

## 3. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Event Layer  (external, asynchronous)                          │
│  ─────────────────────────────────────────                      │
│  board post / mention / operator directive                      │
│      ↓                                                          │
│  wakeup_keeper(?stimulus, name)                                 │
│      ├── if stimulus given:  Keeper_registry.enqueue_event ...  │
│      └── always:             Atomic.set entry.fiber_wakeup true │
│                                                                 │
│  invariants (KeeperEventQueue.tla):                             │
│    Conservation             — enqueued ≥ dequeued               │
│    QueueNeverStarvedBySkip  — ¬ (queue_size > 0 ∧ skip)         │
│    EmitMatchesEvidence      — emit is reactive or scheduled,    │
│                                never spurious                   │
└─────────────────────────────────────────────────────────────────┘
                              │ (data)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Policy Layer  (periodic, internal)                             │
│  ─────────────────────────────                                  │
│  heartbeat tick:                                                │
│    1. snapshot Keeper_registry.event_queue_snapshot             │
│    2. if non-empty   →   smart_decision := "emit"   (Rule 2)    │
│       else            →  Heartbeat_smart.should_emit            │
│    3. if "emit"      →   Keeper_event_queue.dequeue → run turn  │
│       if "skip"      →   interruptible_sleep                    │
└─────────────────────────────────────────────────────────────────┘
```

Read top-to-bottom, the diagram never points an arrow back from Policy to Event Layer state. That irreversibility is the root invariant: a Policy decision cannot retroactively unsubscribe a stimulus that has already entered the queue.

## 4. Module surface

```ocaml
(* lib/keeper/keeper_event_queue.mli — landed in #12396 *)
type urgency = Immediate | Normal | Low
type stimulus = {
  post_id   : string;
  urgency   : urgency;
  arrived_at : float;
  payload   : string;
}
type t

val empty            : t
val enqueue          : t -> stimulus -> t
val dequeue          : t -> (stimulus * t) option
val dedup_by_post_id : ?window_seconds:float -> t -> t
val sort_by_urgency  : t -> t
val length / is_empty / summary

(* lib/keeper/keeper_registry.mli — landed in #12403 (this RFC's PR-B1) *)
type registry_entry = {
  ...
  event_queue : Keeper_event_queue.t Atomic.t;
  ...
}

val enqueue_event :
  base_path:string -> string -> Keeper_event_queue.stimulus -> unit
(** CAS retry loop; lock-free; no-op + warn if keeper missing. *)

val event_queue_snapshot :
  base_path:string -> string -> Keeper_event_queue.t
```

The `Atomic.t` choice is deliberate: enqueue is many-writer (every fiber that observes a stimulus may call it), so a CAS retry is more economical than an Eio mutex.

## 5. TLA+ correspondence

`specs/keeper-state-machine/KeeperEventQueue.tla` is the source of truth for the runtime contract:

| Spec invariant | OCaml assertion | Test |
|---|---|---|
| `Conservation` | `enqueued_total >= dequeued_total` (monotone counters) | `test_conservation` in `test/keeper_event_queue/` |
| `QueueNeverStarvedBySkip` | the heartbeat caller must never settle on `Skip` while `event_queue_snapshot` is non-empty | `test_queue_overrides_policy` (data side) + integration test in PR-C2 |
| `EmitMatchesEvidence` | every `Emit` either consumes a stimulus or is a scheduled tick | `test_dequeue_only_consumes_enqueued` + integration test in PR-C2 |

The buggy spec models exactly the regression `RUTHLESS_JUDGMENT.md` §1 A5 describes — `TickStarvesQueue` flips `smart_decision := "skip"` while `queue_size > 0`. TLC reaches the violation in three steps; CI gates both clean and buggy configurations on every PR.

## 6. PR plan

| PR | Scope | Status |
|---|---|---|
| #12386 | TLA+ spec (`KeeperEventQueue.tla` + buggy bug-model) | ✅ Merged |
| #12396 | Library + isolated property tests | ✅ Merged |
| #12403 | Registry entry field + `enqueue_event` / `event_queue_snapshot` | ⏸ Draft, ready |
| **this PR (RFC)** | **Architecture document** | **Draft** |
| PR-C1 (planned) | `wakeup_keeper` learns optional `?stimulus` and calls `enqueue_event`. No policy change. | — |
| PR-C2 (planned) | `run_smart_heartbeat_gate` consults the queue before `Heartbeat_smart.should_emit`. Implements Rule 2. | — |
| PR-C3 (planned) | Per-turn `dequeue` at the start of the unified turn entry point. | — |

Three things matter about this split:

- **Each PR's diff lives in exactly one of the two layers.** Library / spec / registry data / signal data / heartbeat policy / turn flow — six axes, six PRs.
- **A PR can fail CI without blocking sibling layers.** The TLA+ PR landed before the library; the library landed before the registry; none of them touched policy.
- **The unmerged tail of the queue can be reordered.** PR-C1, C2, C3 may be reviewed in any order because each compiles independently.

## 7. Migration & rollout

Every shipped PR is currently a no-op for production keepers — the queue exists, it is empty, no fiber writes to it, no fiber reads from it. PR-C1 begins to *write* (only when callers pass `?stimulus`), PR-C2 begins to *read*, PR-C3 begins to *consume*. Each step independently observable in `dashboard_keeper` and the existing heartbeat metrics.

Rollback for any of PR-C1/2/3 is a clean revert; the queue field stays harmlessly empty.

A future RFC may revisit:

- whether `?stimulus` should become a required argument once all callers migrate,
- whether `dedup_by_post_id` belongs at enqueue time (vs. lazy at dequeue),
- whether `urgency` is a sufficient dispatch hint or if richer types (latency budget, deadline) are warranted.

None of those are blocking for the current split.

## 8. Open questions

- **Q1**. Should `event_queue` snapshot inside `dispatch_event` use `Atomic.get` directly, or wrap with a defensive `compare_and_set` retry on consumer side too? The Policy Layer is single-fiber per keeper, so a plain `Atomic.get` is sufficient — but the model would need to reflect that.
- **Q2**. `dedup_by_post_id` defaults to a 60s window. Should the runtime expose this as a config knob, or is one constant fine until production telemetry suggests otherwise? Default to "constant" until we have a concrete pain report (`@~/me/instructions/software-development.md` *"No hyperparameter as env knob"*).
- **Q3**. Do we want a `Keeper_event_queue.peek` for telemetry (read head without dequeue)? Cheap to add, but pulls the dashboard slightly into the Event Layer's internals. Defer until a dashboard PR explicitly needs it.

## Appendix A. Why not `[@@deriving tla]` (yet)

`FORMAL_FIX_DESIGN.md` proposed a PPX-based pipeline that auto-syncs OCaml types to TLA+ variable shapes. The runtime cost of getting that pipeline right is large, the spec we need is small, and the hand-written `KeeperEventQueue.tla` (~140 lines) is reviewable on one screen. Hand-writing also lets us encode the runtime-vs-spec mapping in comments where the deviation is explicit (e.g. `arrived_at : float` vs. TLA+ integer time), instead of asking the PPX to lie about it.

If a future RFC introduces `[@@deriving tla]` for unrelated reasons, this spec will be a useful before/after comparison: did the derived spec end up shorter? Did it preserve the same invariants? Was the buggy model still expressible? Until then, manual is honest.
