# RFC-0252 — Per-keeper memory execution lane

- Status: Draft
- Date: 2026-06-17
- Related: RFC-0225 (per-keeper turn single-flight), RFC-0153 (runtime backpressure and admission), RFC-0147 (keeper-agent-run decomposition)

## Problem

Post-turn memory work (librarian extraction + memory-bank compaction) runs through a
process-global single slot:

```
lib/keeper/keeper_librarian_runtime.ml:42
  let provider_slot = Eio.Semaphore.make 1
```

`with_provider_slot` (`:197`, used at `:222`) acquires this one module-level semaphore on
every librarian invocation, with a 0.25s wait (`MASC_KEEPER_MEMORY_OS_LIBRARIAN_SLOT_WAIT_SEC`,
default `:47`); on timeout the extraction is dropped (`provider_slot_busy`).

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
  `{ mem_mu : Eio.Mutex.t; state_mu : Stdlib.Mutex.t; mutable pending : int }`.
- `mem_mu` serializes memory work *within* a keeper (ordering preserved: turn N before turn N+1).
- Different keepers run concurrently (independent lanes).
- `pending` is bounded (`max_pending`, a named constant). Over the bound the submission is
  dropped and logged — memory extraction is opt-in/best-effort, so dropping under saturation is
  acceptable; the drop is counted, never silent.

### Executor switch

The detached fibers are owned by the server root switch, established at startup:

```
lib/server/server_runtime_bootstrap.ml:139
  Eio_context.set_switch sw   (* server root switch *)
```

`Keeper_memory_lane.init ~sw` records this switch. Each submitted unit is run with
`Eio.Fiber.fork ~sw` and the switch re-bound via `Eio_context.with_turn_switch sw` so that
`run_best_effort` (which reads `sw`/`net`/`clock` from `Eio_context`, `keeper_librarian_runtime.ml:331,347`)
issues its provider call under the executor switch. `net`/`clock` are global atomics set at the
same startup point, available everywhere.

Leak-safety follows `keeper_turn_admission.run_locked`: `pending` decrement and `mem_mu` release
are bound to every exit path including `Eio.Cancel.Cancelled`, so a cancelled executor (server
shutdown) cannot leak a permit or a counter.

### What moves to the lane vs stays inline

`Keeper_agent_run_post_turn_memory.run` does four things:

1. deterministic memory write (`Memory.append_from_reply` / `append_from_tool_results`)
2. librarian extraction (`Keeper_librarian_runtime.run_best_effort`)
3. memory-bank compaction (`Memory.compact_if_needed`)
4. post-turn quality metrics → decision log (`append_jsonl_line` to `keeper_decision_log_path`)

`Memory.append_from_reply` / `compact_if_needed` carry no internal lock; they are safe today only
because the turn lane calls them single-fiber-per-keeper. Detaching (3) while (1) still ran inline
would let two fibers touch the same keeper's memory bank concurrently. Therefore **(1) (2) (3) — all
memory-bank-touching work — move onto the lane** (serialized per keeper by `mem_mu`). **(4) stays
inline**: it only reads (`goal_alignment_score`, history) and writes the *decision* log, a separate
file independent of (1)(2)(3).

### Remove the global slot

`provider_slot` / `with_provider_slot` in `keeper_librarian_runtime.ml` are deleted. Per-keeper
serialization now comes from `mem_mu`; the cross-keeper bottleneck is gone.

## Accepted consequence

Detaching memory work means a keeper can have a chat turn and a memory extraction in flight at the
same time — up to two concurrent provider calls per keeper. Across the fleet on a shared endpoint
this raises peak concurrency and can worsen the librarian empty-response rate (HTTP 200 empty body
under saturation, `keeper_librarian_runtime.ml:232`).

This is accepted. Provider load is an operator concern in this codebase, not a code gate
(`keeper_turn_driver_try_provider.ml:401`: "No per-lane capacity gate — provider load is managed by
operator adjusting keeper count."). Endpoint over-subscription is addressed by capacity/routing
(keeper count, endpoint parallelism), not by re-introducing a shared cap. Lane independence and
endpoint contention are separate concerns and are kept separate here.

Memory writes become eventually consistent: a keeper's turn N+1 can begin before turn N's
deterministic note lands, so recall on turn N+1 may miss turn N's note. Ordering within a keeper is
preserved by `mem_mu` (turn N completes before turn N+1 on the lane).

## Known limitations

- Executor fibers are owned by the server root switch, not the per-keeper supervisor switch
  (`keeper_supervisor_launch.ml`). If a keeper is stopped/recovered while a memory unit is in flight,
  that unit runs to completion rather than being cancelled with the keeper. The work is bounded and
  best-effort, writing only to that keeper's own memory bank, so the blast radius is one stale
  extraction. Tying memory units to keeper lifecycle is deferred.

## Tests

`test/test_keeper_memory_lane.ml`:

- ungated path when executor not initialized falls back to inline (no lost work in tests).
- `mem_mu` serializes two submissions for the same keeper (second runs after the first releases).
- two different keepers run concurrently (no cross-keeper blocking).
- `pending` over `max_pending` drops and counts the submission.
- a submitted unit that raises releases `mem_mu` and decrements `pending` (no leak).

## Rollback

Revert is a single commit: restore `provider_slot` in `keeper_librarian_runtime.ml`, re-inline the
memory series in `keeper_agent_run_post_turn_memory.ml`, drop `Keeper_memory_lane` and its `init`
call. No schema or on-disk format changes.
