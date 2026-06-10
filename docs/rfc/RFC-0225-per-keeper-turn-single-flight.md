---
rfc: "0225"
title: "Per-keeper turn single-flight admission"
status: Draft
relates: "RFC-0153 (tier admission), 2026-06-10 voice repeat RCA (~/me/reports/2026-06-10-masc-voice-repeat-rca.md)"
date: 2026-06-10
---

# RFC-0225: Per-keeper turn single-flight admission

## 1. Problem

Nothing in the runtime enforces "one in-flight turn per keeper". Two
independently observed entry paths run `run_turn` concurrently for the same
keeper:

1. **Autonomous lane** — the heartbeat cycle starts a scheduled turn
   (`keeper_heartbeat_loop_cycle.ml`).
2. **Chat lane** — `Keeper_chat_consumer` polls dashboard messages every 1s
   and `Keeper_msg_async.submit` spawns `Eio.Fiber.fork_daemon` **per
   request** (`keeper_msg_async.ml:354-406`); its mutex protects bookkeeping
   only, not turn execution. `keeper_turn.ml:451-468` has no in-flight check,
   and `can_execute_turn` gates lifecycle phase only
   (`keeper_state_machine_types.ml:430-443`).

Measured on 2026-06-10 (sangsu, session `trace-1780648779957-00000`): a
17-minute autonomous turn (FSM tid=370) overlapped five chat turns
(tid=382-386). The overlap caused three concrete corruptions:

- **Checkpoint clobber** — both lanes share one trace_id-keyed checkpoint
  file (`keeper_run_context.ml:101-112`); finalize is last-writer-wins
  (`keeper_agent_run_finalize_response.ml:112-127`). The autonomous lane's
  07:11:50Z save (oas turn_count=1355) overwrote the chat lane's 07:10:38Z
  save (oas=1324) which contained the entire voice conversation — user-visible
  as "the keeper forgot what it just said".
- **Meta regression** — `update_direct_turn_meta` writes a stale
  snapshot+1 (`keeper_turn.ml:57-80`), regressing `total_turns` 385→370 and
  causing keeper_turn_id 386 to be reused at 07:39:19Z.
- **Telemetry cross-attribution** — `keeper_tool_call_log_context.ml:48`
  stamps pending turn context into a Hashtbl keyed by keeper_name only with
  `Hashtbl.replace` (last-writer-wins), so the two lanes' tool_calls records
  swapped each other's turn ids in both directions. Downstream analysis of
  `tool_calls/*.jsonl` is unreliable for any concurrency window.

## 2. Non-goals

- Not a fix for the voice repeat itself — that was the speak tool contract
  drift, fixed separately (sync `agent_speak` restore).
- Not a turn scheduler redesign; RFC-0153 tier admission stays as-is.

## 3. Design

### 3.1 Single admission point

Introduce a per-keeper turn admission primitive that every entry path
(heartbeat, chat, MCP-triggered, board-reactive) must pass:

```ocaml
(* one value per keeper, owned by the registry *)
type turn_slot

val try_admit : turn_slot -> [ `Admitted of admission_token | `Busy of in_flight_info ]
val release : admission_token -> unit  (* via Switch.on_release *)
```

- `Admitted` hands back a linear token consumed by `run_turn`; release is
  bound to the run's `Eio.Switch` so cancellation and exceptions release it.
- `Busy` carries the in-flight lane + started_at so callers can decide:
  chat requests **queue** (bounded, FIFO per keeper) rather than reject —
  the dashboard user expects a reply, not a typed error; autonomous cycles
  **skip** (the next heartbeat retries naturally).
- The `fork_daemon`-per-request pattern in `keeper_msg_async.ml` is replaced
  by a per-keeper serial consumer fiber draining the queued chat requests
  through the same admission point.

### 3.2 Write-integrity backstop (defense in depth)

Admission is the primary fix; the writes are corrected so a future bypass
cannot corrupt state silently:

- Checkpoint save becomes versioned CAS: refuse (and log at Error) when the
  on-disk oas `turn_count` is **newer** than the snapshot being saved
  (`keeper_agent_run_finalize_response.ml`).
- `update_direct_turn_meta` becomes monotonic: read-modify-write under the
  meta CAS with `max` instead of stale-snapshot+1 (`keeper_turn.ml:57-80`).

### 3.3 Tool-call log context keyed by run identity

Remove the keeper_name-keyed global `pending_turn_context` Hashtbl
(`keeper_tool_call_log_context.ml`). The FSM already threads run identity
through per-run closures (`keeper_agent_run_turn_helpers.ml:236-254`); pass
the same `(trace_id, keeper_turn_id)` to the tool-call recorder explicitly.

## 4. Verification

- Concurrency test: start a long-running fake turn, inject a chat request,
  assert the second `run_turn` does not start until the first releases
  (runtime manifest shows zero overlapping executions per keeper).
- Property test: arbitrary interleavings of two finalize calls never
  decrease `total_turns` and never let an older-generation checkpoint
  overwrite a newer one.
- Regression fixture: replay the 2026-06-10 two-lane tool_calls pattern and
  assert every record carries its own run's `(trace_id, keeper_turn_id)`.
- TLA+ bug model (CLAUDE.md pattern): `BugAction` = second concurrent
  admission, `Invariant` = at most one in-flight turn per keeper; clean spec
  passes, buggy spec must violate.

## 5. Rollout

1. Admission primitive + chat lane serial consumer (3.1).
2. Write-integrity CAS (3.2) — independent, can land in parallel.
3. Log context rekey (3.3) — independent.
4. Remove any interim logging added for the incident once 1-3 are merged.
