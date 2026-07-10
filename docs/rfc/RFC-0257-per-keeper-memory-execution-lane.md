# RFC-0257 — Per-keeper memory execution lane

- Status: Draft
- Date: 2026-06-17
- Related: RFC-0225 (per-keeper turn single-flight), RFC-0153 (runtime backpressure and admission), RFC-0147 (keeper-agent-run decomposition)

## Problem

Before this RFC, post-turn memory work (librarian extraction + memory-bank compaction) ran through
a process-global single slot in `keeper_librarian_runtime.ml`.

`with_provider_slot` acquired that one module-level semaphore on every librarian invocation, with a
short wait; on timeout the extraction was dropped (`provider_slot_busy`).

With ~13 keepers, every keeper's librarian work funnels through one slot. One keeper holding
the slot forces the others to wait 0.25s and then discard the extraction. This contradicts the
baseline concurrency model: keeper turns are lane-per-keeper (RFC-0225 `keeper_turn_admission.ml`
`turn_mu : Eio.Mutex.t`, one slot per keeper). A shared cross-keeper slot serializes independent
lanes — the same anti-pattern rejected in PR #21344.

The librarian today also runs *inline* inside the turn lane: `run_turn` finalize
(`keeper_agent_run_finalize_response.ml:192`) calls `Keeper_agent_run_post_turn_memory.run`
synchronously, which executes under the keeper's `turn_mu`. So memory extraction (a provider
round-trip) blocks that keeper's next chat turn.

## Design

Give each keeper its own memory execution lane, detached from the turn lane.

### Lane registry

New module `Keeper_memory_lane` mirroring `keeper_turn_admission`:

- Per-keeper entry keyed by `Keeper_registry_types.registry_key ~base_path keeper_name`:
  `{ state_mu; jobs; pending; active_worker_id }`.
- One drain worker consumes each keeper's explicit FIFO, preserving turn N before turn N+1.
- Different keepers run concurrently (independent lanes).
- Accepted units are not discarded because earlier memory work is slow. The pending gauge reports
  backlog directly; only executor shutdown or worker-spawn failure can abandon queued work, and
  those exceptional outcomes are counted and logged.

### Executor switch

The detached fibers are owned by the server root switch, established at startup:

```
lib/server/server_runtime_bootstrap.ml:139
  Eio_context.set_switch sw   (* server root switch *)
```

`Keeper_memory_lane.init ~sw` records this switch. The first queued unit starts one drain worker
with `Eio.Fiber.fork ~sw`; that worker re-binds the switch via
`Eio_context.with_turn_switch sw` for every unit so that
`run_best_effort` (which reads `sw`/`net`/`clock` from `Eio_context`, `keeper_librarian_runtime.ml:331,347`)
issues its provider call under the executor switch. `net`/`clock` are global atomics set at the
same startup point, available everywhere.

Leak-safety follows `keeper_turn_admission.run_locked`: the in-flight and pending decrements are
bound to every unit exit including `Eio.Cancel.Cancelled`, while a switch release atomically clears
and reports any queue it still owns. A cancelled executor therefore cannot leak worker ownership
or counters.

### What moves to the lane vs stays inline

`Keeper_agent_run_post_turn_memory.run` does four things:

1. typed tool-result memory promotion (`Memory.append_from_tool_results`)
2. librarian extraction (`Keeper_librarian_runtime.run_best_effort`)
3. memory-bank compaction (`Memory.compact_if_needed`)
4. post-turn quality metrics → decision log (`append_jsonl_line` to `keeper_decision_log_path`)

`Memory.append_from_tool_results` / `compact_if_needed` carry no internal lock; they are safe today only
because the turn lane calls them single-fiber-per-keeper. Detaching (3) while (1) still ran inline
would let two fibers touch the same keeper's memory bank concurrently. Therefore **(1) (2) (3) — all
memory-bank-touching work — move onto the lane** (serialized by the keeper's FIFO worker). **(4) stays
inline**: it only reads the typed turn history and writes the *decision* log, a separate
file independent of (1)(2)(3).

### Separate keeper ordering from provider-pool protection

The old global slot mixed two concerns: per-keeper memory ordering and provider-pool
protection. Per-keeper ordering now comes from `Keeper_memory_lane`'s FIFO worker. Provider-pool
protection remains as a separate, optional fleet-wide gate around the provider round-trip only.
That gate is not a memory-ordering primitive and does not serialize deterministic writes or
compaction.

### Correctness under detachment

Detaching means a keeper's turn N+1 can run while turn N's memory unit is still
on the lane. The data the unit reads must not race that later turn:

- `Keeper_meta_contract.keeper_meta` and `Workspace.config` have no `mutable`
  fields; updates return new records (`map_usage`, `reset_runtime_state` are
  `keeper_meta -> keeper_meta`). Turn N's unit closes over turn N's immutable
  record; turn N+1 gets its own. No race.
- The one mutable per-keeper read in the deterministic write is the tool-emission
  accumulator (`Keeper_tool_emission_hook.snapshot (accumulator_for_keeper
  meta.name)`). It is snapshotted **synchronously at turn end**, before submit,
  and the immutable snapshot is passed into the unit — so a later turn's
  emissions cannot fold into this turn's notes.
- The remaining shared mutable state is the on-disk memory bank, which the
  lane's single per-keeper worker serializes.

## Accepted consequence

Detaching memory work means a keeper can have a chat turn and a memory unit queued or in flight at
the same time. Without a fleet-wide bound, N keepers could issue N concurrent provider calls to the
shared flash/glm librarian pool. Measured production data (2026-06-16, issue #21230) showed that
this exact pattern spiked the librarian empty-response rate to 62%, so an unbounded concurrency
increase cannot be treated as a pure operator concern.

To reconcile the lane independence goal with that measurement, this design adds a **separate fleet-wide
provider concurrency gate** around librarian calls:

- `MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT` (default `1`): maximum simultaneous librarian
  provider round-trips across all keepers. `0` disables the gate.
- The wait is a fixed 0.25s best-effort acquisition window. It is deliberately not another
  environment knob; the capacity is the operator-controlled variable.

Per-keeper lane fairness is preserved (one FIFO worker orders each keeper's units), while the shared
pool is protected from the empty-response storm observed in #21230. Lane independence and provider
pool protection are now handled on separate axes rather than pretending one implies the other.

Memory writes become eventually consistent: a keeper's turn N+1 can begin before turn N's
deterministic note lands, so recall on turn N+1 may miss turn N's note. Ordering within a keeper is
preserved by the FIFO (turn N completes before turn N+1 on the lane).

## Relationship to #21408 (mutually exclusive)

PR #21408 is a competing solution to the same underlying problem: the old process-global
`provider_slot` serialized every keeper's librarian work fleet-wide. #21408 keeps the slot concept
but re-implements it as a per-keeper `Hashtbl` registry of slots (`provider_slot_for keeper_id`),
while #21376 (this RFC) removes the slot entirely and moves serialization into the per-keeper
memory lane (`Keeper_memory_lane`). The two PRs touch the same lines in
`keeper_librarian_runtime.ml` in opposite directions (one modifies `provider_slot`; the other deletes
it), so they are textually and semantically mutually exclusive — both cannot merge.

**Recommendation: keep #21376 and close #21408.** The per-keeper lane in #21376 already subsumes the
per-keeper serialization goal of #21408 (one FIFO worker orders each keeper's units independently),
and it does so with a cleaner architecture (lane ownership + explicit queue + leak-safety tests). The
fleet-wide provider-pool gate added above covers the shared-pool protection that #21408 was trying
to re-introduce. Merging both would create two concurrent primitives for the same concern.

If #21376 is deemed too large to land first, the alternative is to close #21376, merge #21408 as a
minimal fix, and then rework #21376 on top of it — but simultaneous open competition between the two
PRs must end before either merges.

## Known limitations

- Drain workers are owned by the server root switch, not the per-keeper supervisor switch
  (`keeper_supervisor_launch.ml`). If a keeper is stopped/recovered while a memory unit is in flight,
  that unit runs to completion rather than being cancelled with the keeper.
- The FIFO preserves accepted work during the current server lifetime but stores closures in memory.
  Root-switch shutdown explicitly abandons and counts unfinished units; restart replay requires the
  durable due/start/success/failure receipt tracked by production-hardening issue #23925 item 31.

## Runtime tunables and metrics

Per-keeper lane:

- `masc_keeper_memory_lane_submitted_total`
- `masc_keeper_memory_lane_ran_inline_total`
- `masc_keeper_memory_lane_dropped_total`
- `masc_keeper_memory_lane_pending` (gauge, per-keeper)
- `masc_keeper_memory_lane_in_flight` (gauge, per-keeper)

Fleet-wide librarian provider gate:

- `MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT` (default `1`)
- `masc_keeper_memory_lane_provider_slot_busy_total`

Exceptional queue abandonment and provider-slot-busy events are also logged at WARN level with the
keeper name.

## Tests

`test/test_keeper_memory_lane.ml`:

- ungated path when executor not initialized falls back to inline (no lost work in tests).
- one FIFO worker serializes submissions for the same keeper.
- two different keepers run concurrently (no cross-keeper blocking).
- a backlog larger than two units is accepted, drained without loss, and preserves FIFO order.
- a submitted unit that raises decrements `pending` and the worker continues (no leak).
- cancelling the executor switch while a unit is in flight clears worker ownership and decrements
  `pending`.

## Rollback

Revert is a single commit: restore `provider_slot` in `keeper_librarian_runtime.ml`, re-inline the
memory series in `keeper_agent_run_post_turn_memory.ml`, drop `Keeper_memory_lane` and its `init`
call. No schema or on-disk format changes.
