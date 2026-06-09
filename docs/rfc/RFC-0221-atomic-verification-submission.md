---
rfc: "0221"
title: "Atomic verification submission — task_status as the sole outcome authority"
status: Implemented (steps 1-3 merged #20613/#20617; steps 4-5 measured then dropped, §3.3/§3.4)
supersedes: "RFC-0220 §8 (the every-boot reconciler)"
relates: "RFC-0220 (verification/scheduling decouple)"
date: 2026-06-09
---

# RFC-0221: Atomic verification submission

## 1. Problem

A verification transition writes **two durable stores** in sequence:

1. the verification evidence record (`<base>/verifications/vrf-*.json`), and
2. the task backlog (`task_status`).

In `Workspace_task_transitions.transition_task_r`, both writes are gated
**record-first**: the `prepare_verification_request` (submit) and
`prepare_verification_verdict` (approve/reject) callbacks run inside the
pre-write `let* ()` guard, and only if they return `Ok` does `write_backlog`
commit the status (`workspace_task_transitions.ml:212-363` then `:444`).

A partial failure — `write_backlog` raising, or a crash between the two writes —
leaves the stores disagreeing. This is RFC-0220 §1.1's "illegal pair": a
non-terminal record whose task is not `AwaitingVerification` (the empirical
task-628 / task-629 case: `Pending` record, `Todo` task).

PR-1 (RFC-0220) made `task_status` the **scheduling** authority and deleted the
cross-store join, so a record-without-status is now *inert* — ignored by
scheduling, the task is a normal claimable `Todo`, the fleet is not stuck. But
RFC-0220 §8 proposed an **every-boot startup reconciler** to repair the pair.
That is repair-on-read (CLAUDE.md "Repair / Sanitize on read" workaround
signature): it makes the symptom non-fatal on each boot without removing the
root — the two-write submission that can still drift.

## 2. The asymmetry that makes atomicity tractable

The two files are not symmetric, so 2-file atomicity does not require a general
transaction. `task_status` is the single authority for the task **outcome**; the
record's role differs per transition:

- **Submit.** The outcome (`AwaitingVerification`) **requires the record's
  content** — `output` / `criteria` are what a verifier reads to do the work.
  So the record must exist before the outcome is observable. Order: write record
  → commit status. Guarantee wanted: `AwaitingVerification ⟹ record exists`.
- **Approve / Reject.** The outcome (`Done` / `InProgress`) **does not require
  the record** — the verdict is already in `task_status` (`decide` writes
  `Done { notes = "Approved by <verifier> (vrf:<id>)" }`). The record is audit
  (verdict history, dashboard attribution). Order: commit status → write record
  verdict best-effort. A record-write failure can neither block nor contradict
  the committed outcome.

This asymmetry is principled, not incidental: the outcome's *dependency on the
record* points the commit order. It yields atomicity-of-outcome without a
cross-file transaction.

A second, mechanical fact forces the same order independently of the
content-vs-audit argument: **approve has no clean compensation.** Submit
*creates* the record, so its compensation is `delete_request` — a clean inverse
(§3.1). Approve/reject *update* the record submit created (`Pending` →
`Completed`). If approve went record-first, a `write_backlog` failure would need
to revert `Completed → Pending`; the only inverse available is the `delete_request`
from §3.1, which would erase the **submission** record entirely — destroying the
`output` / `criteria` the verifier must read after the task bounces back to
`AwaitingVerification`. That revert is not a transition the `Verification` state
machine offers. No clean compensation exists, so approve/reject *cannot* be made
record-first-with-compensation the way submit is — status-first is the only
order that keeps the stores consistent on the error path.

## 3. Design

### 3.1 Submit: record-first, status-commit, compensate

Keep the record write before the status commit (content guarantee). Make the
pair atomic for the **error** case by compensation: if `write_backlog` fails
after `save_request` succeeded, delete the just-written record and surface the
error. Neither store is left mutated.

For the **crash** case (record written, process dies before `write_backlog`),
the orphan record is inert (its task is not `AwaitingVerification`, so scheduling
ignores it). It is resolved by the one-time migration (§3.3) or reaped as inert
(§3.4) — never by per-boot repair machinery.

Requires a `delete_request` (or `archive_request`) store API (does not exist
today; `verification.ml` only has `save_request`).

### 3.2 Approve / Reject: status-commit-first, record best-effort

Move `prepare_verification_verdict` out of the pre-write guard to a post-commit
best-effort step. `write_backlog` (task → `Done` / `InProgress`) is the commit.
`submit_verdict` (record → `Completed`) runs after; on failure it logs (Silent
Failure 금지) but does not roll back — the outcome and its verdict already live
in `task_status`.

**Reject's reason is not lost.** Reject is the one verdict whose outcome
(`InProgress { assignee; started_at }`) carries no notes field, so the reason
text (`~reason`) is not in `task_status`. It does not need to be: the worker's
feedback channel is the **separate** post-commit notify
(`verification_notify_verdict_fn` → board post `"Rejected task … : <reason>"` +
SSE), invoked in `tool_task.ml` *after* `transition_task_r` returns `Ok` — a
different hook from the record write (`verification_record_verdict_fn`), wired
apart in `workspace_metric_hooks.ml`. The audit record is not the reason's
delivery path. status-first in fact *improves* reject: under the old record-first
gate a record-write failure returned `Error`, so the notify (which only fires on
`Ok`) never ran and the worker was never told it was rejected. Under status-first
the transition commits, returns `Ok`, and the notify always runs — only the audit
record is best-effort.

This **reverses a deliberate, tested contract**: `test_approve_prepare_failure_keeps_task_awaiting`
and `test_reject_prepare_failure_keeps_task_awaiting` assert "if the verdict
cannot be recorded, do not transition". Under single-authority that contract is
wrong — it makes an audit-write failure block a decided outcome and re-admits
the drift (record `Completed`, task `AwaitingVerification`). The tests are
updated to the new contract: the outcome commits; the audit write is
best-effort.

### 3.3 Legacy migration — measured, then dropped (won't-do)

The original plan was a one-time migration restoring each non-terminal record
whose task is `Todo | Claimed | InProgress` to `AwaitingVerification`. Before
building it, the drift was **measured** rather than assumed (harness-first: take
the measurement, don't ship a measurement tool). A read-only scan of the live
workspace joined every non-terminal (`Pending`/`Assigned`) record against
`task_status`:

| pair | count | nature |
|---|---|---|
| record + absent task | 56 | inert (no task to restore) |
| record + terminal task (`Done`/`Cancelled`) | 42 | inert (obligation already resolved) |
| record + live `Todo` task | **2** (task-628, task-629) | the named legacy drift |
| record + matching `AwaitingVerification` (healthy) | 0 | — |

The migration's *only* candidates are the 2 `Todo` cases — and restoring them is
**the wrong treatment**: both submissions are 10 days old with `verifier = None`,
and resurrecting them into a verifier queue from a stale record is exactly the
"act on a `Pending` record to mutate `task_status`" pattern RFC-0220 removed. A
`Todo` task is already claimable; if the work still matters it is re-submitted
through the normal flow, which produces a fresh, real obligation. So migration is
**dropped** — there is no record for which restore-to-`AwaitingVerification` is
correct.

### 3.4 Inert-record reaping — one-time cleanup, no standing machinery

All 100 non-terminal records in the scanned workspace were orphans (0 healthy).
They were reaped as a **one-time operational cleanup** (back up, then delete the
record files; tasks and the 485 terminal verdict records untouched), restoring
the store to 0 drift. This is *not* shipped as standing machinery: post-fix the
only new inert orphans come from a rare approve/reject audit-write I/O failure or
a submit crash-between, so the trickle is reaped lazily on the next read of that
task's verification view if at all — not by a boot pass or sweeper. Storage
hygiene, not correctness.

### 3.5 Why the orphan is inert (consumer audit)

status-first turns *every* audit-write I/O failure (not just a rare crash) into
the pair "record `Pending` + task `Done`/`InProgress`" — the same *shape* as the
628/629 drift. This is benign **only if** no code acts on a `Pending` record
without joining `task_status`. Every consumer of the task-verification record was
enumerated (`rg "load_request|list_requests" lib/`) and classified:

| Consumer | Reads `Pending`? | Class |
|---|---|---|
| `dashboard_verification.ml` (summary/requests JSON) | yes | display |
| `workspace_verification_store.load_request_header` (dir listing) | yes | inventory / telemetry |
| `keeper_world_observation_inputs.pending_verification` | yes | **behavior — but joined** |
| `goal_verification.list_requests_for_goal` | no (different type: `goal_verification_request`) | orthogonal |
| `verification.ml` internal (`save_request`, `submit_verdict`) | yes | mechanics |

The only behavior-driving consumer is the keeper world-observation count that
gates keeper wake/scheduling. It does **not** count raw actionable records; it
filters `backlog.tasks` through `task_has_actionable_verification`, which returns
`true` only when `task.task_status = AwaitingVerification` with a matching id
(`keeper_world_observation_inputs.ml:35-45,76-82`). A `Done` task with a `Pending`
orphan hits the `Done -> false` arm and is not counted — the join makes the count
`task_status`-authoritative. The raw actionable-id list has no other consumer.

So the orphan is **an expected benign state**, not a moved bug: no scheduler,
timeout, claim-gate, or gauge acts on it. (Were any consumer found to act on a
`Pending` record unjoined, the fix would be to make *that* consumer
`task_status`-authoritative — extending single-authority — not to abandon
status-first.)

## 4. Why this is not itself a workaround

- It removes the root (the drift-able two-write), it does not instrument or
  repair the symptom. No counter, no every-boot pass, no string classifier.
- `task_status` becomes the sole outcome authority (parse-don't-validate): the
  harmful state "decided outcome contradicted by a record" is unrepresentable
  because the record never gates or overrides the outcome.
- No standing repair machinery ships at all: legacy drift was measured and the
  migration dropped (§3.3); the inert backlog was reaped once operationally
  (§3.4). Nothing runs on every boot or on a timer.

The §3.4 inert-reaper looks superficially like the §8 every-boot reconciler this
RFC rejects; it is not, and the distinction holds **only because** the §3.5 audit
passed:

- The §8 reconciler repairs a *behavior-affecting* pair on every boot — it keeps
  a live root (the two-write drift) survivable by sanitizing on read. The root
  still produces new drift; the reconciler hides it.
- The §3.4 reaper GCs a *benign* stale-audit record **after** write-ordering has
  already made `task_status` authoritative (the root is fixed, not hidden). It is
  storage hygiene over a state §3.5 proved no behavior reads. If §3.5 had found a
  behavior-driving unjoined consumer, the orphan would *not* be benign and the
  reaper *would* collapse into the §8 pattern — so the two are bound: the reaper
  is legitimate iff the consumer audit holds.

## 5. Implementation order

1. `delete_request` store API + unit test.
2. Submit compensation in `transition_task_r` + test (status-commit failure →
   record deleted, task unchanged).
3. Approve/reject status-first + best-effort verdict; update the two
   `*_prepare_failure_keeps_task_awaiting` tests to the new contract; add a
   test (verdict-record failure → task still `Done`, logged).
4. ~~One-time migration command~~ — **dropped after measurement** (§3.3): the scan
   found 0 records for which restore-to-`AwaitingVerification` is correct.
5. Inert-record reaping — done as a **one-time operational cleanup** (§3.4), not
   shipped machinery; future trickle reaped lazily if at all.

Steps 1–3 (the root fix) shipped in #20613 (steps 1–2) and #20617 (step 3).
Steps 4–5 resolved to "measure, then don't build" per §3.3/§3.4.

## 6. Risks / trade-offs

- Touches `transition_task_r`, a hot, well-tested path. Mitigation: incremental
  steps, each building + green before the next; existing verification FSM suite
  must pass except the two intentionally-reversed contract tests.
- A submit crash between record-write and status-commit still leaves an orphan
  record. This is inert (not stuck) and strictly better than the current
  state-loss; it is reaped lazily (§3.4) rather than by standing machinery. Full
  crash-atomicity across two files would need a journal and is out of scope.
- Approve best-effort audit means a verdict record can lag the task outcome on
  failure. The authoritative verdict is in `task_status`; the record is audit.
