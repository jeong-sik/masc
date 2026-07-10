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
  `{ state_mu; jobs; pending; active_worker }`.
- One drain daemon consumes each keeper's explicit FIFO, preserving turn N before turn N+1.
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

`Keeper_memory_lane.init ~sw` records this switch. The first queued unit starts one drain daemon
with `Eio.Fiber.fork_daemon ~sw`; that daemon re-binds the switch via
`Eio_context.with_turn_switch sw` for every unit so that
`run_best_effort` (which reads `sw`/`net`/`clock` from `Eio_context`, `keeper_librarian_runtime.ml:331,347`)
issues its provider call under the executor switch. `net`/`clock` are global atomics set at the
same startup point, available everywhere.

Leak-safety follows `keeper_turn_admission.run_locked`: the in-flight and pending decrements are
bound to every unit exit including `Eio.Cancel.Cancelled`, while a switch release atomically clears
and reports any queue it still owns. The daemon does not keep normal server shutdown alive; when
the executor has no non-daemon work left, Eio cancels the drain and the same abandonment path runs.
A cancelled or normally released executor therefore cannot leak worker ownership or counters.

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

### Separate keeper ordering from provider-call protection

The old global slot mixed two concerns: per-keeper memory ordering and provider-pool
protection. Per-keeper ordering now comes from `Keeper_memory_lane`'s FIFO worker. A later
per-keeper provider semaphore duplicated that same ordering because the only production
`run_best_effort` caller is already inside the Keeper's memory lane. Its fixed acquisition window
could only discard work; it could not protect fleet-wide capacity.

The duplicate semaphore and `MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT` knob are retired.
Provider/model capacity, health, and fallback belong to the OAS provider/runtime boundary. MASC
keeps independent Keeper lanes and does not recreate a cross-Keeper provider scheduler.

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
the same time. Without a MASC-wide gate, N keepers may issue N concurrent provider calls. That is
the intended lane-independence boundary. Measured provider saturation remains observable, but
provider capacity and fallback must be enforced by the selected runtime/provider implementation
rather than by discarding Keeper memory after a hardcoded wait.

Memory writes become eventually consistent: a keeper's turn N+1 can begin before turn N's
deterministic note lands, so recall on turn N+1 may miss turn N's note. Ordering within a keeper is
preserved by the FIFO (turn N completes before turn N+1 on the lane).

## Relationship to #21408

PR #21376 merged the per-Keeper memory lane and closed competing PR #21408. Later source drift
reintroduced #21408's per-Keeper semaphore shape even though the lane already serialized its only
production caller. This revision restores one ownership primitive: the memory lane owns Keeper
ordering; the OAS provider runtime owns provider capacity.

## Known limitations

- Drain daemons are owned by the server root switch, not the per-keeper supervisor switch
  (`keeper_supervisor_launch.ml`). If a keeper is stopped/recovered while a memory unit is in flight,
  that unit runs to completion rather than being cancelled with the keeper.
- The FIFO preserves accepted work during the current server lifetime but stores closures in memory.
  Root-switch shutdown explicitly abandons and counts unfinished units; restart replay requires the
  durable due/start/success/failure receipt tracked by production-hardening issue #23925 item 31.
- The in-memory FIFO is not admission-bounded. Sustained producer/drain imbalance or a stalled job
  can therefore grow one keeper's closure backlog until it threatens the process. Item 31 must move
  accepted work to a durable, replayable queue with explicit admission and terminal receipts; an
  arbitrary drop threshold is not an acceptable substitute.

## Runtime tunables and metrics

Per-keeper lane:

- `masc_keeper_memory_lane_submitted_total`
- `masc_keeper_memory_lane_ran_inline_total`
- `masc_keeper_memory_lane_dropped_total`
- `masc_keeper_memory_lane_pending` (gauge, per-keeper)
- `masc_keeper_memory_lane_in_flight` (gauge, per-keeper)

Exceptional queue abandonment is logged at WARN level with the keeper name. If the retired
`MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT` variable is still configured, startup logs and
counts the ignored setting explicitly.

## Tests

`test/test_keeper_memory_lane.ml`:

- ungated path when executor not initialized falls back to inline (no lost work in tests).
- one FIFO daemon serializes submissions for the same keeper.
- two different keepers run concurrently (no cross-keeper blocking).
- a backlog larger than two units is accepted, drained without loss, and preserves FIFO order.
- a submitted unit that raises decrements `pending` and the worker continues (no leak).
- cancelling the executor switch while a unit is in flight clears worker ownership and decrements
  `pending`.
- replacing the lane's initialized executor switch is rejected explicitly.

## Rollback

Reverting the lane requires re-inlining the memory series in
`keeper_agent_run_post_turn_memory.ml` and dropping `Keeper_memory_lane` plus its `init` call.
It must not restore the retired timeout/drop gate. No schema or on-disk format changes.
