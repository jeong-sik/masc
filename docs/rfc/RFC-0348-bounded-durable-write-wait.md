# RFC-0348 — Bounded lane acquisition for durable keeper_msg writes (#25398)

- Status: Draft
- Author: vincent
- Related: masc#25398 (bug, P0), RFC-0345 (streaming idle-timeout floor — same liveness-floor framing for the provider-stream path), RFC-0344/#25291 (durable store schema hardening), `lib/keeper/keeper_msg_async.ml` (lane gates), `lib/keeper/keeper_fs.ml` (durable write chain), RFC-0000 §1.2 (liveness)

## 0. Summary

A hung durable persist (disk stall, NFS hang, blocked `fsync`/`rename`) permanently wedges the affected keeper's `keeper_msg` pipeline. The write chain has no timeout, the lane gate holds until the write returns, and every later caller queues behind it without bound — recovery requires a process restart (#25398).

This RFC bounds **lane acquisition**, not the write. The in-flight write keeps its lane until it finishes; callers that cannot acquire the lane within a liveness floor give up and return a typed rejection. Acquisition failure is unambiguous — nothing was written — so it needs no reconciliation, no rollback, and no uncertain-publication state.

Two designs have now been rejected, both recorded in §2 so they are not reintroduced: abandoning the wait and releasing the lane (§2.1–2.3), and bounding acquisition by polling `try_lock` (§2.4). **§3 as written implements the second and is therefore withdrawn** — it stands only as the record of what was tried. §3.5 states the constraints any replacement must satisfy.

## 1. Problem (evidence)

Verified against `b39c1027f6`.

- `keeper_msg_async.ml:2173`: `submit_with_ops` enters `with_keeper_submission_lock`; at `:2184` the initial persist runs `with_keeper_persistence_lock` **inside** that critical section. A hang there holds both locks, so every later submit for that keeper blocks forever.
- `keeper_msg_async.ml:413-428` (`with_lane_gate`): `Fun.protect ~finally:unlock (fun () -> Eio.Cancel.protect f)`. The comment at `:419-422` states the rationale — a started durable systhread cannot be cancelled, so the lane is deliberately held until the write returns. The rationale is correct; the consequence is that the lane's lifetime equals the write's, unbounded.
- Write chain: `persist_entry_unlocked` → `save_entry_durable` (`:1160`) → `ops.save_json_durable` → `Keeper_fs.save_json_durable_atomic` → `run_in_systhread_cancel_checked` (`keeper_fs.ml:238-242`). No timeout at any layer; the cancel check runs only **after** the systhread returns.
- The systhread is not cancellable and does not become cancellable under load: `Eio_unix.run_in_systhread` checks the fiber context once at submit time and otherwise dispatches, installing no cancel function — "Systhreads do not respond to cancellation once running" (`eio/unix/thread_pool.mli:22-23`).
- `Keeper_disk_pressure` (`keeper_disk_pressure.mli:1-4`) is observation-only and records typed `ENOSPC`; a stall raises nothing, so it is not observed at all.
- Metrics (`persistence_lane_pending`/`in_flight`) stay correctly elevated during a hang — all decrement paths are sound — so the stuck lane is visible. Nothing recovers it.

Disproven by the same audit (no action): submission↔persistence AB-BA deadlock (ordering is consistent), lane-table races (all under the module mutex), metric leaks, lane locks held across LLM calls.

### 1.1 Two victims, different remedies

The hang damages two distinct resources, and conflating them is what produced the unsound draft:

| Resource | Who holds it | Correct remedy |
|---|---|---|
| The lane held by the hung write | the write itself | **keep holding it** — releasing it breaks the exclusion invariant (§2) |
| The unbounded queue of later callers | everyone else | **bound the wait** — typed rejection instead of an indefinite block |

Liveness is restored by the second row alone. The first row is not a defect to fix; it is the invariant to preserve.

## 2. Rejected design — abandon the wait and release the lane

The earlier draft proposed: race the write against a floor, return `Durable_wait_floor_exceeded` on timeout, map it into the existing `Published_uncertain` arm, release the lanes, and let the systhread complete detached with its late result sent to an observer counter. This is unsound in two independent ways. Both were found by reading the code the draft claimed to have verified.

**2.1 Stale-rename clobber.** The atomic write is write-to-temp plus `Unix.rename temp path` (`keeper_fs.ml:366`). Temp names are unique per call (`Filename.open_temp_file ~temp_dir ".atomic_" ".tmp"`, `lib/fs_compat/atomic_write.ml:31-39`), so two concurrent writers both survive to their rename, and the rename target is identical for a given record — it derives only from `base_path` + `request_id` (`keeper_msg_async.ml:1160-1166`, `:1216-1230`). There is **no generation, CAS, version, or expected-value comparison anywhere before that rename**. The per-keeper lane mutex is therefore the sole serializer of writes to a record path. Releasing it mid-write lets a write that started earlier and finished later rename over a newer record: silent loss, both writers returning `Ok`.

A per-target guard does exist in the codebase — `Capability_mutation_lease.try_acquire` rejects a second writer with `Mutation_contended` (`atomic_write.ml:1295-1303`) — but production request persistence does not route through it (`keeper_msg_async.ml:314-316` → `keeper_fs.ml:509-517` → the bare-rename chain). Any future detach design must adopt a fencing guard of this kind **first**; detaching without one is a data-loss change.

**2.2 Compensation races the in-flight write.** The `Published_uncertain` arm is not a passive label: it performs `rollback_rejected_record_file_unlocked` (`keeper_msg_async.ml:2209`), which deletes the record file. That arm assumes the write has *finished*. Mapping a still-running write into it produces delete-then-resurrect — the rollback removes the file and the detached systhread renames it back. The draft's claim that this needed "no new failure vocabulary" was exactly backwards: a still-running write is a state the existing vocabulary has no member for.

**2.3 Why the draft looked easy.** Every mechanical part needed for detaching already exists — a long-lived switch (`server_background_switch ()`, `keeper_msg_async.ml:533-540`), an existing detached fiber on it (`Eio.Fiber.fork_daemon ~sw:background_sw`, `:2326`), and a promise-shaped offload (`Domain_pool.submit_io_async : 'a Eio.Promise.or_exn`, `domain_pool.mli:75,81`). The implementation would have gone in cleanly and the corruption would have been rare and silent. Availability of the mechanism is not evidence that the semantics are sound.

### 2.4 Rejected — bounded acquisition by polling `try_lock`

Implemented in #25438, verified unsound by a four-lens adversarial review, withdrawn. Three independent blocking defects, two of them inherent to polling.

**Polling destroys starvation-freedom.** `Eio.Mutex.unlock` performs a direct handoff: `Waiters.wake_one … `Take` transfers ownership and leaves `state = Locked`, so a concurrent `try_lock` observes `false` (`eio_mutex.ml:43-47`, `:80-84`). Waiters queue in `t.waiters` via `Eio.Mutex.lock` (`:59`) and are served in order — the existing path is FIFO and starvation-free. Replacing it with polling means nothing ever enters `t.waiters` in production, every acquisition becomes a barging race, and the race is biased against waiters: a poller retries every 50 ms while an arriving caller tries immediately. Under ordinary keeper load — `set_status` Queued/Running/Done per request, checkpoint persists, and submits all key on the same `{base_path; keeper_name}` lane, each holding it 5–30 ms — a waiter can lose for the full floor and be rejected while the lane was in fact free thousands of times. The floor then measures wall-clock waiting, not wedging, while every consumer treats it as wedging, and `lane_unavailable_to_string`'s "a durable write is still in flight" becomes false. The draft asserted "the workload does not produce this"; that was written without evidence and is wrong.

The draft justified polling by noting `Eio.Mutex` offers no way to observe whether a cancelled waiter had already taken the lock. That is true of `Eio.Mutex` and does not generalise: `Eio.Semaphore.acquire` has well-defined cancellation (a cancelled waiter is removed before the resource is transferred), and an explicit holder/ticket record in the lane also resolves it. A constraint on one data structure was generalised into "polling is the only option" without looking for an alternative.

**The bound does not compose.** `set_status` holds `transition_lock` under `~protect:true` — uncancellable — across the persistence floor, and then `persist_failure_locked` re-acquires the same wedged lane for a second full floor: 120 s uncancellable, while `transition_lock` itself carries no bound at all. Operator cancel blocks behind it, N×120 s when calls queue. Bounding the lane relocated the unbounded wait one level up rather than removing it.

**A typed transient failure was folded into permanent-failure handling.** See §3.2's error routing: `Lane_unavailable` shared an arm with `Write_failed (Not_published _)` on the grounds that both leave the same on-disk state. True, and irrelevant — the question that arm answers is whether retrying the original write is futile, and for lane contention it is not. In `set_status` the fold reaches `persist_failure_locked`, which flattens `Done { ok; body; data }` to the string `"done"` inside a `Persistence_failed` marker and then durably commits it after its own retry proves the lane is free again. A keeper turn that succeeded is recorded as failed and the answer is lost; `origin/main` blocks and writes `Done` correctly. That is a data-loss regression introduced by the routing, not by the bound.

Corollaries worth keeping: `result_contract = Failed` on a never-started submission is a false contract (its sibling never-started rejections emit none, and `Failed` suppresses the retry the variant exists to make safe); `persistence_lane_waits` double-counts on a wedged lane, overstating waiters exactly when an operator is reading it; and measuring elapsed time with `Mtime_clock` while sleeping on the `Eio_context` clock leaves a latent full-CPU spin for any embedding that installs a virtual clock.

Confirmed clean, and worth preserving in any replacement: no mutex leak, no counter leak, and no lane-table refcount hazard — `lock.users` is incremented before the acquisition attempt and therefore spans the whole wait, so table removal (`users = 0`) is unreachable while any waiter exists, which is what prevents two fibers from holding "the" lane for one keeper.

## 3. Design (WITHDRAWN — see §2.4; retained as the record of what was tried)

### 3.1 Bounded acquisition in `with_lane_gate`

`with_lane_gate` already fast-paths with `Eio.Mutex.try_lock` (`:414`) before falling back to a blocking `Eio.Mutex.lock`. The change replaces the unbounded fallback with a bounded one and reports the outcome:

```ocaml
type lane_acquisition =
  | Lane_acquired
  | Lane_unavailable of { waited_s : float; floor_s : float }

val with_lane_gate :
  on_wait:(unit -> unit) ->
  floor_s:float ->
  Eio.Mutex.t ->
  (unit -> 'a) ->
  ('a, lane_acquisition) result
```

Acquisition uses bounded `try_lock` polling rather than `Fiber.first` over `Eio.Mutex.lock`. `Fiber.first` cancels the loser, and `Eio.Mutex` offers no way to observe whether a cancelled waiter had already taken the lock — that race would leak the very lane this RFC protects. Polling has no such race: the lock is either held by this fiber or it is not.

Once acquired, everything downstream is unchanged: `Eio.Cancel.protect` still wraps the write, and the lane is still held for the write's full duration.

### 3.2 Caller handling — no reconciliation

`Lane_unavailable` means **nothing was written**. There is no temp file, no rename, no partial state. The caller therefore takes the same shape as the existing `Not_published` arm (`:2228-2230`) — drop the runtime reservation and return a typed rejection — with a distinct error so operators can separate "lane wedged" from "disk error":

```ocaml
| Submit_lane_unavailable of { waited_s : float; floor_s : float }
```

Explicitly **not** routed through `Published_uncertain`: no rollback runs, because there is nothing to roll back, and any compensating write here would race the still-running holder (§2.2).

### 3.3 Floor value and configuration

One constant, SSOT in `Env_config_keeper`: `MASC_KEEPER_LANE_ACQUIRE_FLOOR_SEC`, default **60.0**, clamp `[10.0, 600.0]`. Poll interval is a separate internal constant (**50 ms**), not configurable. 60 s is far above any healthy contended acquisition — the lane serializes one keeper's record writes — so the floor fires on hangs, not on load. Disabling is not offered: an unbounded lane wait is the defect.

Behaviour change to accept knowingly: under sustained legitimate contention on one keeper's lane, polling gives up FIFO fairness, so a caller can lose repeatedly and time out where it would previously have queued. The floor is sized so this requires ~60 s of continuous contention on a single keeper's lane, which the workload does not produce; if it ever does, the answer is an Eio semaphore with cancel-safe FIFO acquisition, not a larger floor.

### 3.4 Submission-lock scope (separate PR)

The initial persist runs inside the submission lock (§1), so a hang currently wedges both lanes. With §3.1 in place the pile-up is already bounded on both, so narrowing the submission lock is a coupling improvement rather than the liveness fix — the reverse of how the earlier draft ranked it. Ships separately if the lock-scope analysis holds under review.

### 3.5 Constraints on any replacement

Derived from §2.4, not yet a design. A replacement must satisfy all four:

1. **Starvation-free bounded acquisition.** No polling. Either `Eio.Semaphore` (cancel-safe FIFO) or an explicit ticket/holder record in the lane. A waiter must never be rejected while the lane repeatedly becomes free.
2. **Bound only where rejection is safe.** Submission may reject; settling an already-running turn may not, because the result exists only in memory. Concretely this means `Lane_unavailable` must not appear in `persist_error` at all — removing it deletes the data-loss fold, the statically-dead arm, and the wildcard absorptions in one move.
3. **One deadline per operation, not per acquisition.** The submit path takes two lanes and `set_status` floors twice; a per-acquisition floor multiplies.
4. **`transition_lock` is in scope.** It is unbounded and held under `~protect:true` across the lane wait. Bounding only the lane moves the wedge rather than removing it. Any liveness claim must cover both locks.

Testing constraints, from the mutation review of #25438: a revert of the bound must **fail** rather than hang (Eio does not detect this deadlock, Alcotest has no per-test timeout, and CI would burn a 40-minute job reporting only a timeout); each isolation case must assert the holder still holds rather than relying on a sibling case for validity; and the submit-level wiring — the typed error and its reservation cleanup — needs direct coverage, since mutations to both survived the existing suite.

## 4. Verification

- **Unit (red→green)**: fake durable op that blocks on a promise the test controls. Assert (a) a second caller for the same keeper returns `Lane_unavailable` within the floor rather than blocking, (b) the blocked holder still owns the lane and its write completes normally when released, (c) a `Lane_unavailable` submit performs **no** rollback and leaves no record file, (d) the fast path still acquires without waiting when the lane is free.
- **Regression guard against §2**: a test asserting the lane is still held for the write's full duration — i.e. that no code path releases it early. This is the executable form of the invariant the rejected design broke.
- **TLA+ bug model** (`tla/`, repo convention): `LaneAcquireFloor` — `BugAction` = unbounded wait on a hung holder; invariant `AcquirerEventuallySettles`. Clean spec passes, `NextBuggy` violates. Both `.cfg`s per the mutation-testing convention. A second bug model for §2 (`BugAction` = release lane while write in flight, invariant `AtMostOneRenameInFlightPerPath`) documents the rejected design as a checked property rather than prose.
- **Live probe**: none required for merge; existing `persistence_lane_*` gauges plus the new rejection counter are the runtime evidence surface.

## 5. Rollout

1. PR-1: bounded acquisition in `with_lane_gate` + `Submit_lane_unavailable` threading + unit tests + TLA+ pair. Load-bearing on its own — no dead-code stage.
2. PR-2 (optional): submission-lock scope reduction (§3.4).

Rollback: PR-1 is independently revertible and restores the current unbounded wait.

## 6. Open questions

- Do the other durable stores share this shape? The checkpoint store uses `File_lock_eio.with_durable_lock` (`keeper_checkpoint_store.ml:415,648`), a different mechanism the audit did not cover. Proposed: separate survey, not this RFC.
- Should the production request write path adopt `Capability_mutation_lease` (§2.1) regardless? It would make the exclusion invariant enforced at the fs layer instead of relying on callers holding a lane. That is the precondition for any future detach design and is worth its own RFC.
