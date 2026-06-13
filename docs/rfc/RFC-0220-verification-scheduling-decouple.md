---
rfc: "0220"
title: "Decouple keeper liveness from verification state + guaranteed satisfier for every verification obligation"
status: Draft
created: 2026-06-09
updated: 2026-06-09
author: vincent
supersedes: []
superseded_by: null
related: ["0113", "0192", "0199"]
implementation_prs: []
---

# RFC-0220: Decouple keeper liveness from verification state + guaranteed satisfier for every verification obligation

Status: Draft · Architectural framing + typed-state unification + atomicity fix + deterministic migration
Audit source: `~/me/.tmp/masc-fiber-audit-2026-06-09/DIAGNOSIS.md` (finding S3)
Ground-truth invariants encoded:
- **I1** — a keeper must never permanently stop. A blocked/empty claim pool must not idle a keeper.
- **I2** — the only legitimate timeout is the OAS provider transport timeout (connect + inter-chunk idle). No heuristic per-turn / wall-clock deadline as control flow.

All file:line anchors in this RFC were verified against the working tree on 2026-06-09 before writing. Anchors are given as `file:line` for reviewer navigation; treat the symbol name as the durable reference.

---

## §1 Problem (verified against code)

A keeper that has nothing claimable goes idle. The audit traced this to verification state leaking into the keeper scheduling path, plus a store-drift bug that produces a permanently unclaimable task. Three concrete defects compose.

### 1.1 Verification state gates the worker claim pool

`lib/workspace/workspace_task_schedule.ml:57-62`:

```ocaml
let verification_blocks_claim latest_status_by_task (task : Masc_domain.task) =
  match Hashtbl.find_opt latest_status_by_task task.id with
  | Some (_, `Pending) | Some (_, `Assigned) -> true
  | Some (_, `Rejected) -> false
  | Some (_, `Passed) | None -> false
;;
```

Applied at `workspace_task_schedule.ml:351-353`, scoped to `all_todo` (defined at `:336-340` as `filter (task_status = Todo)`):

```ocaml
let latest_verification_status = latest_verification_status_by_task config in
let verification_blocked_todo =
  List.filter (verification_blocks_claim latest_verification_status) all_todo
```

The exclusion itself is **correctly scoped**. It removes from the claim pool only `Todo` tasks whose latest verification request is `Pending`/`Assigned`. For a task that has correctly transitioned to `AwaitingVerification`, the predicate is never applied (it is not in `all_todo`), and the task remains claimable (`types_core.ml:579-584`, see §1.4). The bug is not "the exclusion is wrong". The bug is that an *illegal* `Todo + Pending` pair can exist at all — and when it does, the exclusion removes the task from the claim pool while no other path can ever clear it (§1.3, §1.4).

When `verification_blocked_todo` together with the other filters empties the eligible list, `claim_next_r` returns `Claim_next_no_eligible { verification_blocked_count; ... }` (`workspace_task_schedule.ml:466-474`). The keeper-facing consumer at `lib/keeper/keeper_tool_task_runtime.ml:648-669` renders this as a message string ending in `ACTION: Stop task-checking`. That instruction is what idles the keeper — a violation of I1.

### 1.2 The Submit transition is a non-atomic dual write across two stores

`transition_task_r` (`lib/workspace/workspace_task_transitions.ml:11`) runs the whole transition body inside `with_file_lock_r config backlog_path (fun () -> ...)` (`:41`). Inside that body, for a `Submit_for_verification` action, two durable writes happen in sequence to two different stores:

1. **Verification request store** — `prepare ~task ~assignee ~verification_id ~evidence_refs` at `workspace_task_transitions.ml:230`. `prepare` is `Verification.create_request`-style and persists a `Pending` request via `Verification.save_request` → `Fs_compat.save_file_atomic` (`lib/verification.ml:400-410`). This write happens **before** the task FSM is updated.
2. **Task FSM store** — `write_backlog config backlog_update.backlog` at `workspace_task_transitions.ml:444`, which is what actually moves the task to `AwaitingVerification`.

The lock body is wrapped by `Common.protect`, not `Eio.Cancel.protect`. `lib/process/file_lock_eio.ml:248-250`:

```ocaml
Common.protect ~module_name:"file_lock_eio" ~finally_label:"finalizer"
  ~finally:(fun () -> release_flock_fd fd)
  f
```

`Common.protect` (`lib/core/common.mli:27-35`) is `Fun.protect`-shaped: it guarantees the finalizer runs and routes finalizer errors, but it does **not** mask cancellation of `f`. The body `f` — the two-write sequence — is therefore cancellable at any await point. Eio cancellation delivered to the keeper fiber between write (1) and write (2) leaves:

- verification request = `Pending` (durably written, step 1 done)
- task FSM = `Todo` (or `InProgress`; the backlog write at step 2 never happened)

The finalizer releases the flock (correct for the lock), but nothing rolls back the orphaned `Pending` request. The two stores have drifted.

### 1.3 The only rescue is a destructive 24h heuristic that never fires for the drifted pair

`Verification_protocol.check_timeouts` (`lib/verification_protocol.ml:350-438`) is the sole background loop that clears stuck verification state. It is forked once at startup (`lib/server/server_bootstrap_loops.ml:683-690`):

```ocaml
fork_subsystem "verification_timeout" (fun () ->
  let interval = Env_config_runtime.Verification.timeout_check_interval_seconds in
  let rec loop () =
    Eio.Time.sleep clock interval;
    Verification_protocol.check_timeouts ~config:state.workspace_config;
    loop ()
  in loop ());
```

`check_timeouts` matches `task.task_status` and acts **only** on `AwaitingVerification` (`verification_protocol.ml:358`). For every other status it is an explicit no-op (`verification_protocol.ml:431`):

```ocaml
| Todo | Claimed _ | InProgress _ | Done _ | Cancelled _ -> ()
```

When it does fire (default deadline `Env_config_runtime.Verification.timeout_deadline_seconds ()`, 86400s = 24h), its action is **destructive**: `Workspace.force_cancel_task_r` (`verification_protocol.ml:415`) cancels the task outright. This is exactly the class of heuristic wall-clock deadline-as-control-flow that I2 forbids, and it is destructive (it discards the work, it does not reschedule the obligation).

Because the drifted pair is `Todo + Pending`, `check_timeouts` never matches it. The task is invisible to the only rescue. It sits forever.

### 1.4 The satisfier path exists — but only from `AwaitingVerification`, which the drift never reaches

A verification obligation is satisfied by a *different* keeper claiming the `AwaitingVerification` task (cross-agent verification dispatch, Issue #19314):

- `AwaitingVerification` is claimable: `types_core.ml:579-584` returns `Claim_available` for it.
- Explicit claim-by-id preserves the status and assigns the verifier: `workspace_task_claim.ml:151-158` matches `AwaitingVerification`, keeps the status, and routes to verifier assignment.

There is **no active verifier-assignment scheduler** that pushes a `Pending` request onto a verifier's queue. Verification work is *pull-based*: a verifier keeper must find the `AwaitingVerification` task in its claimable pool. The comment at `workspace_task_claim.ml:182-184` references a "verification dispatch loop", but no such assignment loop runs — the only verification background fiber is the destructive timeout loop in §1.3.

The consequence for the drifted pair is the trap:

| Pool | Membership rule | Drifted `Todo+Pending` |
|------|-----------------|------------------------|
| Worker claim pool | `Todo` and not verification-blocked | **excluded** (`verification_blocks_claim` = true) |
| Verifier claim pool | task = `AwaitingVerification` | **absent** (task is `Todo`, not `AwaitingVerification`) |
| 24h destructive rescue | task = `AwaitingVerification` | **never matches** (task is `Todo`) |

The task satisfies the membership rule of **no** pool. It is unreachable by every mechanism. Fixing the drift (moving the task to `AwaitingVerification`) does **not** merely relabel the stuck state — it makes the obligation genuinely schedulable, because `AwaitingVerification` is in the verifier-claimable set.

### 1.5 Empirical evidence (runtime store, verified 2026-06-09)

Runtime store `~/me/.masc/verifications/`:

- `vrf-ea67cb9bbe54e69eee764d8a587f3b6a.json` — `task_id: task-628`, `verifier: null`, `status: { status: pending }`, `created_at: 1780338285.19` (2026-06-02 03:24 KST), `worker: keeper-echo-agent`.
- `vrf-13cae6cf48ef468a4d70898f474b741c.json` — `task_id: task-629`, `verifier: null`, `status: { status: pending }`, `created_at: 1780336332.14` (2026-06-02 02:52 KST), `worker: keeper-ramarama-agent`.

Backlog `~/me/.masc/tasks/backlog.json`:

- `task-628` — `status: "todo"`
- `task-629` — `status: "todo"`

Both: `request = Pending`, `task = Todo`, 8 days (2026-06-02 → 2026-06-09), zero auto-clear. This is the `Todo + Pending` illegal pair from §1.2 reproduced in production.

---

## §2 Owner vision (the requirements this RFC encodes)

1. **Keeper liveness is independent of verification state.** An empty or verification-blocked claim pool must not idle a keeper. With nothing to claim, the keeper takes autonomous turns (path-1), not a stop.
2. **A genuine wait is explicit, typed, and event-driven.** Where the system legitimately waits, it waits on a causal wakeup (Promise/Condition/Stream resolved by the event that ends the wait), never on a timeout. Schedule-to-start latency for verification work is a *worker-availability* condition, not a deadline to add (Temporal model, §6).
3. **Every obligation has a guaranteed schedulable satisfier.** A pending verification must be claimable by some verifier keeper. The satisfier (the `AwaitingVerification` task) must never be excluded from the verifier pool while the system waits for it to be satisfied. Excluding the satisfier is what produced the 8-day stall.

The Parse-don't-validate lever: make the illegal `Todo + Pending` pair **unrepresentable** by unifying the two stores into one typed status authority.

---

## §3 Design — unified typed verification state (primary fix)

### 3.1 Single status authority

`task_status` (`lib/types/types_core.mli:74-86`) becomes the **only** authority for "where is this task in its lifecycle, including verification". The separate `request_status` (`lib/workspace/workspace_verification_store.mli:6-9`) stops being a status store.

Today two enums encode overlapping facts:

```ocaml
(* task_status — types_core.mli:74 *)
| Todo | Claimed | InProgress | AwaitingVerification { verification_id; ... } | Done | Cancelled

(* request_status — workspace_verification_store.mli:6 *)
| `Pending | `Assigned of string | `Completed of verdict
```

`Pending`/`Assigned` are sub-states of "this task is awaiting verification". `Completed Pass`/`Completed Fail` are the *outcomes* that drive the task to `Done`/back to `Todo|InProgress`. Encoding them in a second store is what admits drift.

**Proposal.** Fold the verification sub-state into `AwaitingVerification`:

```ocaml
type verification_phase =
  | Awaiting_verifier                  (* no verifier yet (was request `Pending`) *)
  | Verifier_assigned of { verifier : string }   (* was request `Assigned _ *)

type task_status =
  | Todo
  | Claimed of { assignee : string; claimed_at : string }
  | InProgress of { assignee : string; started_at : string }
  | AwaitingVerification of
      { assignee : string
      ; submitted_at : string
      ; verification_id : string
      ; phase : verification_phase   (* NEW — replaces the separate request_status *)
      (* `deadline` removed — see §3.4 / I2 *)
      }
  | Done of { ... }
  | Cancelled of { ... }
```

With this:

- `Pending` exists **only** as `AwaitingVerification { phase = Awaiting_verifier; ... }`. There is no way to spell "request Pending while task Todo" — the phase lives inside the `AwaitingVerification` constructor. The illegal pair is unrepresentable by construction. This is the whole §1 bug, eliminated structurally.
- `Verdict` outcomes are not a status; they are events that drive the transition `AwaitingVerification → Done` (Pass) or `AwaitingVerification → Todo|InProgress` (Fail/Partial). They do not persist as a third "completed" status — the task simply moves.

### 3.2 The request store degrades to an immutable evidence record

The verification request file (`~/me/.masc/verifications/vrf-*.json`) keeps existing, but it is no longer a *status* store. It becomes an append-once **evidence/payload record** keyed by `verification_id`:

- carries: `criteria`, `evidence_refs`, `output`, `worker`, `created_at`, and (once a verdict is reached) the `verdict` + verifier identity as an audit fact.
- does **not** carry the authoritative claimable status. Schedulers read `task_status` only.

`latest_verification_status_by_task` (`workspace_task_schedule.ml:46-55`) and `verification_blocks_claim` (`:57-62`) are **deleted**. The schedule path no longer joins against a second store; eligibility is computed purely from `task_status`. `verification_blocked_todo` (`:352-353`), the `task_claim_next_skip_verification` log event (`:365-374`), and the `verification_blocked_count` plumbing through `Claim_next_no_eligible` collapse to dead code and are removed together.

Removing the cross-store join is the part that makes §1.1 disappear: there is nothing to drift against.

### 3.3 Keeper liveness path-1 (empty/blocked pool → autonomous turn, never idle)

Encodes vision (1). When `claim_next_r` would return `Claim_next_no_unclaimed` or `Claim_next_no_eligible`, the keeper does **not** halt. The keeper takes an autonomous turn against its goal.

The current consumer (`keeper_tool_task_runtime.ml:648-669`) returns `ACTION: Stop task-checking`. That string is the idle trigger. The liveness fix is a **loop change**, not a message reword: the keeper run loop must, on a no-claim result, proceed to a provider turn over the live path

```
keeper_agent_run → keeper_turn_driver_try_provider.run_try_provider
  → Runtime_agent.run → Agent_sdk.Agent.run_stream → OAS Complete.complete_stream
```

rather than treating "no task" as "stop". Exact wiring in §7. The typed result already exists — `Keeper_tool_outcome.No_progress { reason = No_eligible_tasks { ... } }` (`keeper_tool_task_runtime.ml:736-747`) — so the loop can branch on the typed outcome instead of parsing the human string.

### 3.4 path-2 (genuine wait is event-driven, never a timeout)

Encodes vision (2). After this RFC there is no legitimate *blocking* wait inside the verification path: a keeper with no eligible task takes a turn (path-1) instead of blocking. Where the system does choose to wait for an event (e.g. a verifier-availability signal feeding a dashboard or a future verifier-routing surface), it waits on a causal wakeup primitive (`Eio.Condition` / `Eio.Stream` / a resolved `Promise`) resolved by the producing event (a verifier coming online, a `submit_for_verification` landing). It does not sleep on a poll interval and it does not impose a deadline.

The `deadline` field is dropped from `AwaitingVerification` (§3.1). With path-1 guaranteeing the keeper never idles and the satisfier guaranteed (§3.5), there is no need for a per-obligation wall-clock deadline. This is the I2 commitment in the data model: the only timeout left anywhere is the OAS transport timeout on the streaming turn (`Keeper_runtime_resolved.stream_idle_timeout_*`, already in `keeper_agent_run.ml:452-454`).

### 3.5 Guaranteed satisfier (the load-bearing section)

Encodes vision (3). The obligation is the `AwaitingVerification` task. Its satisfier is some verifier keeper claiming it. The guarantee is:

**An `AwaitingVerification` task is always a member of the verifier-claimable pool, and is never excluded from it while it waits for a verifier.**

Mechanically, after §3.2:

1. `AwaitingVerification` is claimable (`types_core.ml:579-584`, unchanged) and, with `verification_blocks_claim` deleted, nothing removes it from the claim pool. The §1.4 trap (excluded from worker pool, absent from verifier pool) cannot recur, because there is no longer a `Todo+Pending` state to be trapped in — Submit either fully lands `AwaitingVerification` or fully fails (§3.6).
2. The cross-agent verifier claim path (`workspace_task_claim.ml:151-158`) preserves `AwaitingVerification` and assigns the verifier (transition to `phase = Verifier_assigned { verifier }`). Self-verification is blocked by the existing same-actor guard so the worker cannot satisfy its own obligation.
3. Satisfier scheduling is **pull-based and worker-availability-bounded**, not deadline-bounded (Temporal model, §6). If no verifier is currently free, the obligation simply remains in the pool until one is; "no available verifier right now" is latency, not failure, and is resolved by a verifier becoming available — exactly the event path-2 would wait on, never a timeout.

**Known divergence to fix as part of this RFC (otherwise the satisfier is silently destroyed):** the *auto*-claim path `claim_next_r` unconditionally overwrites status with `Claimed { assignee }` (`workspace_task_schedule.ml:484-485`), which would clobber an `AwaitingVerification` task if a verifier reached it through auto-claim rather than explicit claim-by-id. The two claim paths treat the same claimable status inconsistently. To make the satisfier robust regardless of which claim surface a verifier uses, `claim_next_r` must, for an `AwaitingVerification` candidate, take the cross-agent verifier branch (preserve status, assign verifier) instead of the worker `Claimed` overwrite — i.e. the auto-claim writer must reuse the same decision as `workspace_task_claim.ml:151-158`. This is the only behavioral widening beyond the unification; it removes an existing inconsistency rather than adding a new branch.

### 3.6 Transition atomicity — Submit and verdict (residual tactical fix, scoped to the migration window)

The dual write is **not** unique to Submit. The verdict transitions are symmetric: `Approve_verification` / `Reject_verification` persist the verdict via `prepare_verification_verdict` at `workspace_task_transitions.ml:277-320` — and the error string there even reads "verdict persistence failed *before status transition*" — before the same `write_backlog` at `:444`. A cancel delivered between the verdict-record write and the backlog write leaves evidence-record = `Completed` while task = `AwaitingVerification`: the symmetric tear to §1.2.

Once §3.1 unifies the stores, the dual write loses its teeth on **both** sides, because `task_status` is the sole authority and the evidence record is never read for status:

- A **Submit-tear** (record `Pending` written, backlog not moved) leaves a normal, re-claimable `Todo` task plus a dangling evidence payload — no scheduler reads the payload for status, so the task is fully schedulable.
- A **verdict-tear** (record `Completed` written, backlog not moved) leaves a normal, re-claimable `AwaitingVerification` task plus a dangling evidence payload — a verifier can re-adjudicate; nothing reads the payload `Completed` as authoritative status.

Critically: the verdict-tear must **not** be gated against as a new drift condition (no "record says Completed but task isn't Done → block" check). Adding such a gate re-invents the §1.1 cross-store gate and re-admits the antipattern. Under unification the tear is simply non-fatal; the dangling record is reaped by the reconciler (§8).

So, post-unification, `Eio.Cancel.protect` is a **cleanliness guard, not a correctness necessity** — it keeps the durable region tidy during the migration window and for the residual evidence-record write, but the design is already correct without it. During the migration window (before the unified `task_status` ships everywhere) apply it to **both** regions:

- Wrap each durable write region — evidence-record write **and** backlog write, for Submit (`:212-273`) and for verdict (`:277-320`) alike — in `Eio.Cancel.protect` so a cancellation delivered mid-region cannot tear the two apart. Both complete or, on a pre-write failure, neither is observable.
- The region stays inside the existing flock body (`workspace_task_transitions.ml:41`), so cross-process safety is unchanged; `Eio.Cancel.protect` only removes the intra-process cancel-tear.
- Keep `Common.protect` for the *finalizer* (flock release, `file_lock_eio.ml:248-250`) — that part is correct as-is. The change is to make the **body's durable-write regions** uninterruptible, not to change the finalizer.

Position: **unification (§3.1) is primary** — it makes the illegal pair unrepresentable and both tears non-fatal. `Eio.Cancel.protect` (§3.6) is a cleanliness/transition guard, not a second correctness fix. They are not independent fixes.

---

## §4 Why this is not a workaround (CLAUDE.md gate self-check)

| Signature | Applies? | Why |
|-----------|----------|-----|
| Telemetry-as-fix | No | `verification_blocked_count` / `task_claim_next_skip_verification` are **deleted**, not added. No counter is introduced as a fix. |
| String/substring classifier | No | Removes a cross-store string-status join; replaces a human-string `ACTION: Stop` trigger with a typed-outcome branch. No string classifier added. |
| N-of-M patch | No | The unification covers all status reads in one type change; the compiler enumerates every match site of `task_status` / `request_status`. No "fixed K of M sites" deferral. |
| Cap / cooldown / dedup / repair | The 24h destructive cancel (`check_timeouts`) is exactly this. It is **removed** (§5), not added. |
| catch-all `_ ->` added | No | The new `verification_phase` is a closed sum; matches stay exhaustive. No catch-all introduced. |
| test backdoor | No | None added. |
| same fix N sites | No | Single type change drives the migration. |

This RFC removes two workaround-class mechanisms (the cross-store gate and the destructive 24h deadline) by changing the data model so they are unnecessary.

---

## §5 The 24h heuristic rescue becomes removable (I2)

`Verification_protocol.check_timeouts` (`verification_protocol.ml:350-438`) and its fork (`server_bootstrap_loops.ml:683-690`) exist only to rescue stuck verification by destructively cancelling after 24h. After §3:

- the drifted `Todo+Pending` state cannot exist (§3.1), so there is nothing to rescue;
- an `AwaitingVerification` obligation is always in the verifier pool (§3.5), so it is satisfied by a verifier claiming it, not by a deadline;
- a keeper never idles on an empty pool (§3.3), so "no verifier responded" never blocks the fleet.

Therefore `check_timeouts`, the `verification_timeout` fork, and the per-obligation deadline are **removed entirely**. This is the concrete I2 win: the last heuristic wall-clock deadline-as-control-flow in the verification path is deleted, leaving only the OAS transport timeout.

Long-wait **operability** (the legitimate concern behind the old board notify) is preserved without a timer. A long-waiting `AwaitingVerification { phase = Awaiting_verifier }` is already a typed, observable fact in the activity-event stream (the `Submit_for_verification` event with no subsequent claim). Surfacing "this obligation has waited a long time" is a *read-side derivation* over that stream / a dashboard query — not a poll-interval fiber that wakes up to emit a warning. Keeping a poll timer that fires "you have waited N seconds", even non-destructively, would still be a heuristic timer and would contradict vision-2; we deliberately do not keep one. Operators see long-waiting obligations through the existing activity surface.

Removal ordering: first remove the destructive `force_cancel_task_r` action (turn `check_timeouts` into a no-op), ship + observe one fleet cycle confirming nothing depends on the cancel side effect, then delete the loop, the function, and the deadline knobs. The notify is not retained — its information moves to the activity stream.

---

## §6 Prior art (cited)

- **Temporal schedule-to-start.** "No available worker" is a worker-availability condition, not a timeout to add — a retry just pops the work back onto the same queue. This is exactly §3.5: a pending verification with no free verifier is latency, resolved when a verifier becomes available; adding a deadline (the §1.3 24h cancel) only destroys the work. We model the verifier pool as a Temporal task queue: membership guaranteed, satisfaction bounded by worker availability, never by a clock.
- **gRPC context/deadline propagation.** Where a deadline genuinely exists it is carried as a typed field across every boundary (cf. RFC-0192 runtime deadline propagation). We deliberately do *not* introduce a verification deadline field (§3.4) — the only deadline in the system remains the OAS transport one.
- **httpx transport timeouts (Anthropic/OpenAI SDK).** connect + read(per-chunk idle) + write + pool, with **no** wall-clock total. Empirical proof that I2 (transport idle timeout, no heuristic total) is sufficient for a streaming turn. The keeper streaming turn already uses this shape (`keeper_agent_run.ml:452-454`); nothing in this RFC adds a total deadline.
- **Erlang `one_for_one` + Akka DeathWatch.** Isolate failure to the failing unit; peers observe via supervision, no central gate. The verifier-availability model is peer-pull, not a central scheduler that can wedge the fleet.

---

## §7 Exact files / functions

### Type model
- `lib/types/types_core.mli:74-86` / `lib/types/types_core.ml` — add `verification_phase`; replace `AwaitingVerification`'s `deadline : string option` with `phase : verification_phase`. Update `task_status_to_yojson` / `task_status_of_yojson` (`types_core.ml:614+`) with a migration-tolerant decoder (§8). Update `task_claim_decision` (`types_core.ml:571-590`) — `AwaitingVerification` stays `Claim_available` (unchanged behavior; the phase does not gate claimability).

### Verification store → evidence record
- `lib/workspace/workspace_verification_store.mli:6-18` / `.ml` — keep `request_header` as an evidence record; remove `request_status` from the *scheduler* read path. Status reads move to `task_status`. The `request_status` variant survives only as the recorded verdict/payload (audit fact), not as a claimable status.
- `lib/verification.ml` — `save_request` (`:400-410`) keeps persisting evidence; `assign_verifier` (`:522`) records verifier identity in the evidence record AND drives the `phase = Verifier_assigned` transition on the task FSM (single authority). `request_status_is_actionable` (`:259-264`) has no callers (verified) and becomes dead code on removal of the scheduler join — delete it.

### Dashboard / read-side (payload reads, keep)
- `lib/dashboard/dashboard_verification.ml:85-116` — `status_bucket_of_request` / `derive_status_fields` read `req.status` for **display** (Pending/Approved/Rejected bucket + verdict string). This is a *payload* read of the evidence record, not a scheduler-authority read, and stays valid post-unification — the record must retain the verdict for the UI (§3.2). No scheduler authority leaks here; confirmed the only authoritative-status consumer of the verification store is `workspace_task_schedule.ml:31-55` (being deleted). The `request_status` types in `lib/gate/gate_protocol.ml`, `lib/keeper/keeper_msg_async.ml`, `lib/goal/goal_verification.ml` are unrelated (gate messages / keeper async / goal verification) — out of scope.

### Scheduler decouple
- `lib/workspace/workspace_task_schedule.ml` — delete `verification_claim_state`/`verification_claim_state_of_status` (`:31-44`), `latest_verification_status_by_task` (`:46-55`), `verification_blocks_claim` (`:57-62`), `verification_blocked_todo` (`:352-353`), the `task_claim_next_skip_verification` event (`:365-374`), and `verification_blocked_count` from `Claim_next_no_eligible` (`:466-474`).
- `lib/types/types_core.mli` / `.ml` — drop `verification_blocked_count` from the `Claim_next_no_eligible` record.
- `lib/keeper/keeper_tool_task_runtime.ml:648-669, 697-747` — remove `verification_blocked_count` plumbing; branch the keeper loop on `Keeper_tool_outcome.No_progress` (`:736-747`) to path-1 (autonomous turn) instead of returning `ACTION: Stop task-checking`.
- `lib/task/tool_task_handlers.ml` — update the other `Claim_next_no_eligible` consumer for the record shape change.

### Satisfier robustness
- `lib/workspace/workspace_task_schedule.ml:475-486` — for an `AwaitingVerification` candidate, reuse the cross-agent verifier branch (`workspace_task_claim.ml:151-158`) instead of overwriting with `Claimed { assignee }`. Auto-claim and explicit-claim must agree on `AwaitingVerification` handling.

### Liveness loop (path-1)
- `lib/keeper/keeper_agent_run.ml` + `keeper_turn_driver_try_provider.run_try_provider` — on a no-claim outcome, proceed to a provider turn (the verified live path) rather than halting. Keep the OAS transport timeout (`keeper_agent_run.ml:452-454`) as the only timeout.

### Atomicity (residual, both transition regions)
- `lib/workspace/workspace_task_transitions.ml:212-273` (Submit region) **and** `:277-320` (Approve/Reject verdict region) plus the shared `write_backlog` at `:444` — wrap each durable evidence-record-write + backlog-write region in `Eio.Cancel.protect`. The verdict region carries the symmetric tear (§3.6) and was missing from the earlier scope; both regions are in. Leave the flock finalizer on `Common.protect`. Do **not** add a "record Completed but task not Done" drift gate (§3.6).
- `lib/process/file_lock_eio.ml:241-252` — no change required (finalizer stays `Common.protect`); the body protection lives at the transition call site so only the durable-write regions are masked, not the whole locked body.

### 24h rescue removal (I2)
- `lib/verification_protocol.ml:350-438` — remove the `force_cancel_task_r` action first (`:415`), then delete `check_timeouts` and `awaiting_verification_deadline` (`:~330-348`). No notify timer is retained; long-wait surfacing moves to the activity-event stream (§5).
- `lib/server/server_bootstrap_loops.ml:683-690` — delete the `verification_timeout` fork.
- `Env_config_runtime.Verification.timeout_deadline_seconds` / `timeout_check_interval_seconds` — remove the now-unused knobs (also remove the `deadline` field references dropped from `AwaitingVerification`).

---

## §8 Migration for the 8-day stuck task-628 / task-629

Deterministic and mechanical. The durable `Pending` request is honored as **intent** (a verification was requested). The reconciler eliminates the illegal pair; it does **not** adjudicate verdicts (no "PR merged so auto-pass" — that is the permissive-default antipattern; a verifier decides).

One-time reconciler (run at startup before the schedulers, and as a documented migration step):

```
for each verification evidence record R with no terminal verdict:
  let T = task R.task_id
  if T.task_status is Todo | Claimed | InProgress:        (* the drifted / pre-submit pair *)
     transition T -> AwaitingVerification
        { assignee   = R.worker
        ; submitted_at = iso8601_of_unix R.created_at
        ; verification_id = R.id
        ; phase = (match R.verifier with
                   | None   -> Awaiting_verifier
                   | Some v -> Verifier_assigned { verifier = v }) }
  else if T.task_status is AwaitingVerification: leave as-is (already consistent)
  else if T is Done | Cancelled:
     record R is a dangling evidence payload -> mark resolved/archived, no task change
```

Applied to the empirical cases:
- `task-628` (`vrf-ea67...`, worker `keeper-echo-agent`, verifier null) → `AwaitingVerification { assignee = keeper-echo-agent; verification_id = vrf-ea67...; phase = Awaiting_verifier }`. It then enters the verifier-claimable pool. A verifier (not echo) claims and adjudicates.
- `task-629` (`vrf-13ca...`, worker `keeper-ramarama-agent`, verifier null) → same, assignee `keeper-ramarama-agent`.

Do **not** route 628/629 through `check_timeouts` (it would destructively cancel them — §1.3). The reconciler is the migration path; `check_timeouts` is being removed.

JSON decode tolerance: `task_status_of_yojson` must accept legacy `AwaitingVerification` objects that carry `deadline` (drop it) and legacy backlogs without `phase` (default `Awaiting_verifier` when a matching non-terminal evidence record exists, else treat as a malformed record surfaced by the reconciler — do not silently fabricate a phase).

---

## §9 Test plan

Harness-first (CLAUDE.md): no AI-loop behavior change without a measurable test.

### Unit / property
1. **Illegal pair unrepresentable.** Type-level: there is no constructor for "request Pending while task Todo". Add a test asserting that `task_status` round-trips `AwaitingVerification { phase = Awaiting_verifier }` and that no code path produces a Todo task with an authoritative pending verification status (the join function no longer exists — assert the symbol is gone).
2. **Submit atomicity under cancellation.** Drive `transition_task_r ~action:Submit_for_verification` inside an `Eio.Switch`, deliver `Eio.Cancel.cancel` between the evidence-record write and the backlog write, assert the post-state is one of {fully submitted `AwaitingVerification`, fully unchanged} — never `Todo + dangling-authoritative-pending`. (Mirror the §1.2 race; this is the regression test for the bug.)
3. **No-eligible → path-1.** With an empty/blocked claim pool, assert the keeper loop proceeds to a provider turn (mockable `run_try_provider`) and does **not** return a halt/stop outcome. Assert I1: the loop schedules another turn.
4. **Satisfier claimability.** Given `AwaitingVerification { phase = Awaiting_verifier }`, assert it is in `claim_next_r`'s eligible set and that a *different* keeper claiming it (both auto-claim and explicit claim-by-id) preserves `AwaitingVerification` and assigns the verifier; assert self-verification by the worker is blocked.
5. **24h rescue removed.** Assert `check_timeouts` no longer cancels; assert the `verification_timeout` fork is absent from bootstrap.

### Migration test
6. Seed a store with the exact 628/629 shape (`Todo` task + `Pending` verifier-null evidence record, created_at 8 days ago). Run the reconciler. Assert task → `AwaitingVerification { phase = Awaiting_verifier }`, evidence record intact, task now eligible. Assert no verdict was fabricated (`phase = Awaiting_verifier`, not Done).

### TLA+ (optional, recommended — bug-model pattern, CLAUDE.md §TLA+)
7. Model the Submit dual-write as a `BugAction` (`PendingWrittenTaskNotMoved`) + invariant (`NoTodoWithPendingVerification`). Clean spec (single authoritative write) satisfies it; buggy spec (`Next \/ BugAction`) must violate it in ≤3 steps. Model the satisfier as a liveness property: every `AwaitingVerification` is eventually claimed given a fair verifier.

---

## §10 Tradeoffs

- **Type change blast radius.** Changing `AwaitingVerification`'s fields touches every exhaustive `match` on `task_status` and the yojson codecs. This is the cost of Parse-don't-validate; it is also the benefit — the compiler enumerates every site, so the migration cannot silently miss one (contrast the N-of-M antipattern). Mitigation: land the type change in one PR; the build enforces completeness.
- **Evidence-record dual existence during migration.** Until the unified status ships everywhere, the evidence record and the task FSM coexist. The `Eio.Cancel.protect` guard (§3.6) covers the window. After full unification the record is pure audit payload.
- **Removing the 24h cancel removes a (destructive) backstop.** If §3.5's satisfier guarantee has a hole (e.g. a fleet with zero verifier-capable keepers), an obligation could wait indefinitely. This is the **correct** behavior under I1/I2 (wait on availability, not a clock) and matches Temporal schedule-to-start. Operability is preserved by surfacing long-waiting obligations from the **activity-event stream** (a read-side derivation, §5), not by a poll timer — keeping a timer, even a non-destructive notify-only one, would still be a heuristic timer in tension with vision-2. Operators see a long-waiting obligation without the system either destroying it or running a clock against it.
- **Auto-claim vs explicit-claim convergence (§3.5).** Making `claim_next_r` honor `AwaitingVerification` is a small behavioral widening of auto-claim. The alternative (forbid auto-claiming `AwaitingVerification` entirely, force verifiers to claim-by-id) is simpler but narrows how verifiers discover work and risks under-utilizing the verifier pool. Chosen: converge the two paths so verification work is discoverable through the same surface as worker work.
- **path-1 turn cost.** A keeper that previously idled now spends provider tokens taking autonomous turns. This is intended (I1) but is a real cost; the goal-scope and decline-memory machinery (RFC-0216) bounds wasted turns. Not a deadline — a relevance filter.

---

## §11 Rollout

1. PR-1: type unification (`task_status` + `verification_phase`), codec migration tolerance, delete cross-store join, reconciler. Compiler-enforced completeness.
2. PR-2: satisfier convergence (`claim_next_r` honors `AwaitingVerification`) + path-1 liveness loop change + tests.
3. PR-3: neuter then remove `check_timeouts` + `verification_timeout` fork (I2), keep notify-only.
4. Run the reconciler against the live store; verify 628/629 transition to `AwaitingVerification` and get claimed by a verifier.

Each PR is independently buildable and testable; PR-1 is the load-bearing one (the bug is unrepresentable after it).
