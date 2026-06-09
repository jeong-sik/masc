---
rfc: "0221"
title: "Atomic verification submission — task_status as the sole outcome authority"
status: Draft
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

This **reverses a deliberate, tested contract**: `test_approve_prepare_failure_keeps_task_awaiting`
and `test_reject_prepare_failure_keeps_task_awaiting` assert "if the verdict
cannot be recorded, do not transition". Under single-authority that contract is
wrong — it makes an audit-write failure block a decided outcome and re-admits
the drift (record `Completed`, task `AwaitingVerification`). The tests are
updated to the new contract: the outcome commits; the audit write is
best-effort.

### 3.3 One-time migration (legacy task-628 / task-629)

Existing drift predates this fix. A documented, one-time migration (a CLI /
guarded single run, **not** startup machinery) honors each non-terminal record
whose task is `Todo | Claimed | InProgress` by restoring it to
`AwaitingVerification { assignee = R.worker; submitted_at = iso8601 R.created_at;
verification_id = R.id; phase = (R.verifier ? Verifier_assigned : Awaiting_verifier) }`.
It does **not** adjudicate (no auto-pass). This is the RFC-0220 §8 pseudocode,
run once as migration rather than every boot.

### 3.4 Inert-record reaping (optional, follow-up)

A non-terminal record whose task is terminal (`Done` / `Cancelled`) or absent is
inert. Reap lazily (on the next read of that task's verification view) or in a
documented sweep. Not load-bearing for correctness — purely storage hygiene.

## 4. Why this is not itself a workaround

- It removes the root (the drift-able two-write), it does not instrument or
  repair the symptom. No counter, no every-boot pass, no string classifier.
- `task_status` becomes the sole outcome authority (parse-don't-validate): the
  harmful state "decided outcome contradicted by a record" is unrepresentable
  because the record never gates or overrides the outcome.
- The migration is a one-time legacy step with a removal point (after it runs),
  not standing machinery.

## 5. Implementation order

1. `delete_request` store API + unit test.
2. Submit compensation in `transition_task_r` + test (status-commit failure →
   record deleted, task unchanged).
3. Approve/reject status-first + best-effort verdict; update the two
   `*_prepare_failure_keeps_task_awaiting` tests to the new contract; add a
   test (verdict-record failure → task still `Done`, logged).
4. One-time migration command + test (seed 628/629 shape → `AwaitingVerification
   { Awaiting_verifier }`, record intact, no verdict fabricated, idempotent).
5. (Follow-up) inert-record reaping.

## 6. Risks / trade-offs

- Touches `transition_task_r`, a hot, well-tested path. Mitigation: incremental
  steps, each building + green before the next; existing verification FSM suite
  must pass except the two intentionally-reversed contract tests.
- A submit crash between record-write and status-commit still leaves an orphan
  record until the migration/reaper. This is inert (not stuck) and strictly
  better than the current state-loss; full crash-atomicity across two files
  would need a journal and is out of scope.
- Approve best-effort audit means a verdict record can lag the task outcome on
  failure. The authoritative verdict is in `task_status`; the record is audit.
