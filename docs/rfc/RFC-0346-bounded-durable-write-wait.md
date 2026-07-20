# RFC-0346 — Bounded durable-write wait with typed uncertain-publication escalation (#25398)

- Status: Draft
- Author: vincent
- Related: masc#25398 (bug, P0), RFC-0345 (streaming idle-timeout floor — same liveness-floor framing for the provider-stream path), RFC-0344/#25291 (durable store schema hardening), `lib/keeper/keeper_msg_async.ml` (lane gates), `lib/keeper_runtime/keeper_fs.ml` (durable write chain), RFC-0000 §1.2 (liveness)

## 0. Summary

A hung durable persist (disk stall, NFS hang, blocked `fsync`/`rename`) permanently leaks the affected keeper's `keeper_msg` submission and persistence lanes. The write chain has no timeout anywhere, the lane gate deliberately defers cancellation until the write returns, and no watchdog or circuit breaker exists — recovery requires a process restart (#25398).

This RFC separates two conflated concepts — the **uncancellable durable write** (sound: abandoning a started write is what invents uncertain publication states) versus the **unbounded wait on that write while holding admission lanes** (the defect). It proposes bounding the *wait*, not the write: after a liveness floor elapses, the waiting fiber stops waiting, maps the outcome into the existing typed `Published_uncertain` handling, and releases the lanes; the systhread runs to completion detached and its late result is observed, not consumed.

## 1. Problem (evidence)

All references verified against `ba1be22a8e` (2026-07-20 audit, #25398).

- `keeper_msg_async.ml:2171`: `submit_with_ops` enters `with_keeper_submission_lock`; at `:2182` the initial "Queued" persist runs `with_keeper_persistence_lock` **inside** that critical section. A hang here leaks both locks in one call; every later submit for the same keeper blocks forever on the submission lane.
- `keeper_msg_async.ml:413-428` (`with_lane_gate`): `Fun.protect ~finally:unlock (fun () -> Eio.Cancel.protect f)` — cancellation is deliberately deferred until `f` returns ("A started durable systhread cannot be cancelled. Keep the lane held…"). The rationale is sound; the consequence is that the lane's lifetime equals the write's lifetime, unbounded.
- Write chain: `persist_entry_unlocked` → `save_json_durable` → `Keeper_fs.save_json_durable_atomic` → `run_in_systhread_cancel_checked` (`keeper_fs.ml:238-242`) → `Eio_guard.run_in_systhread`. No timeout at any layer; the cancel check runs only **after** the systhread returns.
- `Keeper_disk_pressure` (`keeper_disk_pressure.mli:1-4`) is observation-only and records typed `ENOSPC` — a stall raises nothing, so it is not even observed.
- Metrics (`persistence_lane_pending`/`in_flight`) stay correctly elevated during a hang (the audit confirmed all decrement paths are sound), so operators can see the stuck lane — but nothing recovers it.
- Later-persist variant: a hang in the daemon's own `Running`/`Done` persist leaks the persistence lane alone; the next submit's initial persist then blocks on it **while holding** the submission lane, converging on the same terminal state one hop later.

Disproven by the same audit (no action needed): submission↔persistence AB-BA deadlock (ordering is consistent), lane-table races (all under the module mutex), metric leaks, lane locks held across LLM calls.

## 2. Non-goals

- Cancelling or timing out the durable write itself. A started write must run to completion; killing it mid-`rename` is precisely how uncertain publication states are created. This RFC never interrupts the systhread.
- Tuning per-device or per-filesystem write timeouts. As with RFC-0345, the floor is a single generous liveness ceiling that only fires on genuine hangs, not a performance knob.
- General disk-pressure admission control (`Keeper_disk_pressure` stays observation-only; #25139-adjacent work is out of scope).
- Changing the `keeper_msg` public API (`submit`/`cancel`/`poll` signatures are unchanged).

## 3. Design

### 3.1 Bounded wait primitive

Add to `Keeper_fs`:

```ocaml
val save_json_durable_atomic_with_wait_floor :
  floor_s:float ->
  (* existing save_json_durable_atomic parameters *) ... ->
  (unit, durable_wait_outcome) result

type durable_wait_outcome =
  | Durable_completed of (unit, exn) result   (* systhread finished in time *)
  | Durable_wait_floor_exceeded of { stage : durable_stage; floor_s : float }
```

Implementation shape: the systhread resolves an `Eio.Promise.t` instead of being awaited directly; the calling fiber races the promise against `Eio.Time.sleep floor_s` (`Fiber.first`). On floor exceed, the fiber returns `Durable_wait_floor_exceeded` immediately; the systhread keeps running detached and, on late completion, resolves the promise into an **observer** (log line + counter `DurableWaitLateCompletions{stage,outcome}`), never into the abandoned caller. Single-consumer discipline: the promise is consumed exactly once by whichever side loses the race; the loser's result goes to the observer. `Eio.Cancel.protect` semantics for the fiber-side wait are preserved for the non-floor path.

### 3.2 Typed escalation in keeper_msg_async

`persist_entry_unlocked` maps `Durable_wait_floor_exceeded` into the **existing** `Write_failed (Published_uncertain { stage; … })` arm — the state is genuinely uncertain (the write may still land later), and `submit_with_ops` already owns that arm (`keeper_msg_async.ml:2196+`): it detaches the runtime preserving the reservation, settles the entry as reconciliation-required, and returns a typed rejection to the caller. No new failure vocabulary; the floor produces a state the reconciliation path (`recover_lost_disk_records`, durable-active inventory) was already designed to absorb.

Net effect on the leak: `with_lane_gate`'s `f` now returns within `floor_s` even under a hang, so `Fun.protect`'s finally releases the persistence lane, `submit_with_ops` unwinds, and the submission lane releases. The keeper's pipeline stays live; the stuck write is visible as a typed reconciliation entry plus the late-completion counter instead of a wedged mutex.

### 3.3 Floor value and configuration

One constant, SSOT in `Env_config_keeper` (mirroring RFC-0345's posture): `MASC_KEEPER_DURABLE_WAIT_FLOOR_SEC`, default **60.0**, clamp `[10.0, 600.0]`. 60s is ~3 orders of magnitude above a healthy local `fsync`+`rename` and comfortably above worst observed APFS stalls; it exists to catch hangs, not slow disks. `0`/unset-to-disable is deliberately **not** offered: an operator who wants the old behavior is asking for an unbounded lane hold, which is the defect. (If a deployment genuinely needs it, the clamp ceiling of 600s is the escape hatch.)

### 3.4 Blast-radius hardening (optional, separable)

Move the initial "Queued" persist out of the submission-lock critical section so a persistence-lane hang no longer takes the submission lane down in the same call. The audit shows the terminal outcome converges anyway (one hop later), so this is hardening, not the load-bearing fix; it can ship as a follow-up PR if the lock-scope analysis holds under review.

## 4. Verification

- **Unit (red→green)**: fake durable op that blocks on a promise; assert (a) without the floor the caller never returns (bounded test via `Fiber.first` harness), (b) with the floor the caller returns `Durable_wait_floor_exceeded` within the floor, the lane mutex is released, and a subsequent submit for the same keeper succeeds; (c) late completion increments the observer counter and does not double-settle the entry.
- **TLA+ bug model** (repo convention, `tla/`): `DurableWaitLeak` — model lane hold as a state; `BugAction` = wait without floor on a hung write; invariant `LaneEventuallyReleased` (leads-to). Clean spec (floored wait) passes; `NextBuggy` violates. Both `.cfg`s required per the mutation-testing convention.
- **Live probe**: none required for merge; the late-completion counter and existing `persistence_lane_*` gauges are the runtime evidence surface.

## 5. Rollout

1. PR-1: `Keeper_fs` bounded-wait primitive + observer counter + unit tests (no call-site change; dead until wired).
2. PR-2: `keeper_msg_async` wiring (`persist_entry_unlocked` + `Published_uncertain` mapping) + lane-release tests + TLA+ pair.
3. PR-3 (optional): submission-lock scope reduction (§3.4).

Rollback: each PR is independently revertible; PR-2 revert restores the current unbounded wait without touching the primitive.

## 6. Open questions

- Should the same floor wrap the **other** durable stores' systhread waits (checkpoint store uses a separate `Eio_guard`-based path — the audit found it does not share these lanes, but it shares the unbounded-wait shape)? Proposed: separate follow-up survey, not this RFC.
- Counter cardinality: `stage` label is bounded (enum) — confirm with the metrics-cardinality lint before PR-1.
