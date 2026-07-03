# RFC-0304 — HITL Critical Bounded Escalation (typed `Escalated` phase, fiber-free suspension, operator-must-decide preserved)

- Status: Draft
- Area: `lib/keeper/` (`keeper_approval_queue`, world observation, turn outcomes), `lib/server/server_bootstrap_loops.ml` (approval janitor), `lib/governance_pipeline.ml`, `docs/security/approval-rules.md`, dashboard approval queue
- Resolves: the direct contradiction between `docs/security/approval-rules.md` ("Critical approvals must not auto-cancel, auto-expire, or requeue") and Draft PR #22971 (3600s timeout → auto-Reject)
- Builds on: RFC-0303 (stimulus-gated wake — the resume stimulus), RFC-0232 (producer-typed turn outcome precedent), `specs/keeper-state-machine/KeeperApprovalQueue.tla` (existing FSM spec + bug-model pattern)
- Incident anchor: gh issue #20525 (2026-06-08) — `taskmaster` turn 536 called `keeper_task_force_done`, governance classified it Critical, the only surfacing was an SSE broadcast with no dashboard open, and the keeper fiber stayed parked for 70+ minutes until server SIGTERM. `rg '20525'` over the repo returns zero hits; this RFC is the first in-repo cross-reference.
- Evidence (code, main `3540d7d9aa4`):
  - Critical park site: `lib/keeper/keeper_approval_queue.ml:835` — `| Some _, Critical | None, _ -> Eio.Promise.await promise` (no timeout, agent fiber suspended indefinitely)
  - Non-critical bounds exist and work: per-call 600s (`default_noncritical_approval_timeout_s`, `keeper_approval_queue.ml:727`, raced via `Eio.Fiber.first` at `:806-833` → Reject + `approval_timeout` audit) plus the 1800s janitor sweep (`expire_stale ~max_wait_s:1800.0`, `lib/server/server_bootstrap_loops.ml:767-786`, 60s cadence)
  - Critical is deliberately skipped by the sweep: `keeper_approval_queue.ml:1141` `| Critical -> acc`; the doc comment at `:1111-1133` names the two indefinite-wait operator gates (`keeper_continue_after_reconcile`, `keeper_supervisor_restore_reconcile_gate.ml:56`; `keeper_continue_after_partial_commit`, `keeper_turn_runtime_budget.ml:970`) and the observed failure mode of auto-reject: the supervisor Phase-2 sweep re-enqueues the same approval next tick → a 30-minute expire/re-enqueue cycle flooding the audit log, or a permanent `paused = true` no autonomous logic can recover
  - Fiber-free substrate already present: `pending_approval.on_resolution : (approval_decision -> unit) option` (`lib/keeper_contract/keeper_approval_queue_rules_types.mli`), and the cycle-level gate `blocked Approval_pending` (`lib/keeper/keeper_world_observation.ml:1102-1103`, closed `skip_reason` sum)
  - Policy checklist is already written: `docs/security/approval-rules.md:31-34` — "Bounded Critical timeout behavior requires runtime work before it can be used in production: typed timeout/escalation state, cancel/requeue semantics, dashboard state badges, audit events, and tests for each transition."

## Summary

Two requirements are in tension and both are legitimate:

1. **Operator-must-decide** (policy): a Critical approval is a human decision. Auto-expiry either denies a required recovery action or requeues dangerous work without a human. The ban in `approval-rules.md` was written after the expire/re-enqueue death spiral was observed in production.
2. **Bounded liveness** (incident #20525): parking a keeper agent fiber on a raw `Eio.Promise.await` for 70+ minutes is a resource leak and an availability hole — one undecided approval freezes the keeper's entire turn pipeline.

The resolution is to stop conflating the two: **bound the fiber, not the decision.** The decision remains unbounded and belongs to the operator forever. The *fiber* and the *visibility* get bounded, typed treatment:

- A typed pending phase `Awaiting_operator → Escalated` that adds visibility after a bounded interval and **never decides** (no auto-Approve, no auto-Reject, no cancel, no requeue).
- Fiber-free suspension: the Critical path stops parking fibers. The turn ends with a typed parked outcome; operator resolution delivers a typed resume stimulus (RFC-0303).

#22971's timeout-Reject is rejected as-is: it verbatim violates the policy ban, reuses the untyped `Approval_expired of string` audit shape as a decision channel, and reintroduces the exact death spiral documented at `keeper_approval_queue.ml:1111-1133` for the two gate approvals.

## Motivation

### The two documents prescribe opposite fixes

The incident issue (#20525) proposed "3600s + `Fiber.first`" — which #22971 implements. The policy doc (merged after the death-spiral incident, #22740) forbids exactly that until the typed machinery exists. #22971's own diff confirms the conflict: it deletes the mli comment "*Critical approvals are exempt, matching expire_stale's operator-must-decide policy*" while leaving `expire_stale`'s Critical-skip and its rationale comment intact, and does not touch `approval-rules.md`. The review thread (7 comments, `review:basic-done`) never raised the policy conflict. An RFC is the only artifact that can resolve a policy-vs-implementation split; landing either side silently loses the other's invariant.

### Why auto-reject cannot work here (the death spiral, restated as a type problem)

The two Critical gate approvals are *state-reconciliation* gates, not model tool calls. If the system auto-rejects them:

1. The gate's precondition is still unmet, so the supervisor re-enqueues the same approval on the next tick — unbounded audit/event traffic with no state advance; or
2. The gate gives up and parks the keeper `paused = true` — the documented permanent state no autonomous logic recovers from.

Both are the system deciding — badly — something only an operator can decide. A timeout that produces a *decision* is a category error; a timeout that produces *visibility* is exactly what the policy checklist asks for.

### The fiber park is a separate bug, fixable without deciding anything

`submit_and_await` couples "a decision is pending" (durable state) to "a fiber is suspended" (runtime resource). The coupling is unnecessary: `pending_approval` already carries `on_resolution` callbacks, and the world-observation gate `blocked Approval_pending` already prevents new turns while an approval is pending. What is missing is a typed way for the *current* turn to end without a decision and to resume when one arrives.

## Design

### 1. Typed pending phase (state machine, no new decision paths)

```ocaml
(* keeper_approval_queue_rules_types *)
type pending_phase =
  | Awaiting_operator                                  (* since requested_at *)
  | Escalated of { escalated_at : float }              (* visibility raised; still pending *)
```

`pending_approval` gains `phase : pending_phase` (initial `Awaiting_operator`). Transitions:

| From | To | Trigger | Effect |
|---|---|---|---|
| `Awaiting_operator` | `Escalated` | janitor sweep, `now - requested_at > critical_escalation_after_s` | audit + SSE + badge + log marker; entry stays pending |
| `Awaiting_operator` \| `Escalated` | resolved (removed) | operator Approve/Reject/Edit via dashboard HTTP | existing `Resolve` semantics, unchanged |

- `critical_escalation_after_s = 1800.0` — a **code constant**, following the janitor `max_wait_s` precedent ("Code constant: changes need code review (policy), not a runtime knob", `server_bootstrap_loops.ml`). No env knob: #22971's `MASC_HITL_CRITICAL_TIMEOUT_S` is dropped.
- The transition is **monotone**: `Escalated` never returns to `Awaiting_operator`, escalation fires at most once per entry, and escalation of an already-resolved entry is a no-op (the sweep re-checks presence under the queue lock before transitioning).
- **What never happens**: no transition resolves the promise/callback. `expire_stale`'s `| Critical -> acc` skip is retained verbatim. The phase machine adds exactly one state and zero decision paths.

### 2. Escalation effects (visibility only)

- Audit JSONL (`.masc/audit-approvals/`): new `event_type:"approval_escalated"` alongside existing pending/resolved/expired.
- SSE: `approval:escalated` alongside existing `approval:pending` / `approval:resolved`.
- Dashboard approval queue (the live SSOT per `approval-rules.md:26-29`): render the phase as a badge (Pending / Escalated), sorted escalated-first.
- Keeper log marker: `HITL_APPROVAL_ESCALATED` alongside the existing three markers.
- The supervisor per-sweep warn (`keeper_supervisor.ml:237-251`) is already cadence-bounded and stays as-is. No reminder re-escalation cadence: one transition, one set of events — the audit-flood failure mode is what the death-spiral comment documents.

### 3. Fiber-free suspension (bounded liveness, decision still unbounded)

Two call families park fibers today; each gets a typed, non-deciding exit:

**(a) Model tool calls (governance HITL via `to_oas_approval_callback`, `governance_pipeline.ml:462-480`).**
The OAS approval hook gains a generic fourth decision (OAS-side API change, no coordinator vocabulary — a host-agnostic SDK concept):

```ocaml
(* oas lib/base/hooks.mli *)
type approval_decision = Approve | Reject of string | Edit of Yojson.Safe.t
                       | Defer   (* host will resolve later; end the run without executing the tool *)
```

On `Defer`, OAS finishes the run with a typed stop reason (e.g. `Approval_deferred of { tool_name : string }` in the run-outcome family) without executing the tool. MASC's callback returns `Defer` for Critical instead of awaiting; the pending entry (which already persists the tool name and request fingerprint — the exact thing the operator approves) keeps the decision. On operator resolution, `on_resolution` fires a typed resume stimulus (RFC-0303 wake carrier): the resume turn injects the deferred call's `tool_result` — the real execution result if approved (executing the operator-approved fingerprint at resolution time is the semantic HITL already has today, since the blocking path also executes after the approval delay), or a typed rejection result if rejected. No dangling `tool_use` reaches the provider: the pairing happens before the next dispatch.

**(b) Supervisor/restore gates (`keeper_continue_after_reconcile`, `keeper_continue_after_partial_commit`).**
These fibers stop calling `submit_and_await` and instead `submit_pending` + return. The gate's precondition is re-checked on the next supervisor tick; `blocked Approval_pending` (already in `keeper_cycle_decision`) keeps the keeper from turning meanwhile. Resolution delivers the same typed resume stimulus. The gate never re-enqueues while an entry for the same fingerprint is pending (present-entry check, which also kills the re-enqueue storm by construction rather than by cooldown).

### 4. Race semantics

Operator resolution and janitor escalation race on the same entry: resolution always wins. Both run under the queue's existing lock; escalation re-reads the entry and no-ops if it is gone. Resolution of an `Escalated` entry is indistinguishable from resolution of an `Awaiting_operator` entry except for the audit trail.

## Invariants (TLA+, extending `KeeperApprovalQueue.tla`)

Following the repo's bug-model pattern (clean spec must pass, bug spec must violate):

| Invariant | Statement | Bug action that must violate it |
|---|---|---|
| `NoAutoDecision` | only operator `Resolve` removes a Critical entry | `EscalationDecides` (escalation resolves the promise) |
| `EscalationMonotone` | phase never regresses; at most one escalation per entry | `ReEscalate` |
| `CriticalNeverExpired` | `ExpireStale` never selects a Critical entry | existing `ExpireStaleNoResolve` extended to Critical |
| `NoPendingDuplicate` | at most one pending entry per (keeper, fingerprint) | `GateReenqueue` (gate submits while pending exists) |
| `BoundedSuspension` (phase 2) | no agent fiber is suspended on an approval promise | `CriticalParks` (the current `:835` behavior, modelled as the bug) |

`SuspensionMatchesPending` / `QuiescentImpliesResolved` from the existing spec are preserved.

## Rollout

| Phase | Scope | Liveness effect |
|---|---|---|
| 1 | `pending_phase` + escalation transition + audit/SSE/badge/marker + TLA invariants 1-4 | none yet (visibility only; `:835` unchanged) |
| 2 | OAS `Defer` + typed parked outcome + resume stimulus + gate `submit_pending` conversion + `BoundedSuspension` | fiber park eliminated |
| 3 | notification channels beyond SSE (board post / push) for `Escalated` | operator latency ↓ |

Phase 1 is shippable alone and already satisfies the visibility half of the policy checklist. Phase 2 is the liveness fix and requires an OAS release + pin bump (the `Defer` variant is generic SDK surface; OAS remains coordinator-agnostic). `approval-rules.md`'s ban paragraph is rewritten in the phase-1 PR to describe escalation semantics and to keep the auto-decision ban permanent (it is no longer "until that work exists" — the ban becomes unconditional, because escalation removes the reason anyone wanted a timeout-decision).

## Disposition of #22971

Do not merge as-is. Specifically:

- Drop: `MASC_HITL_CRITICAL_TIMEOUT_S` / `[hitl].critical_timeout_s`, the `| Some clock, Critical when critical_timeout_s > 0.0 -> use_timeout ...` branch, and the reuse of `Approval_expired` as a Critical decision channel.
- Salvageable in phase 2: `keeper_llm_bridge.with_hitl_approval_headroom`'s OAS-timeout floor logic becomes unnecessary once `Defer` ends the run (no long-lived OAS call to keep alive) — evaluate and most likely delete rather than port.
- Restore the deleted mli comment ("Critical approvals are exempt ...") in phase 1, updated to reference the phase machine.

## Tests (per transition — the policy checklist item)

1. Escalation fires after the bound (fake clock), exactly once, entry still pending, audit `approval_escalated` recorded.
2. Resolution before the bound → no escalation event ever.
3. Race: resolution concurrent with sweep → resolved wins, no escalation-after-resolve.
4. `expire_stale` with Critical entries beyond any bound → untouched (regression pin on `| Critical -> acc`).
5. Gate re-entry while pending exists → no duplicate entry (`NoPendingDuplicate`).
6. Phase 2: Critical approval callback returns `Defer`; run ends with the typed parked outcome; no fiber remains suspended (assert via the queue's suspension count); operator Approve → resume turn carries the executed `tool_result`; operator Reject → resume turn carries the typed rejection.
7. TLA: clean cfg passes all invariants; each bug cfg violates its paired invariant.

## Alternatives considered

- **#22971 timeout-Reject (3600s):** violates the written policy; re-creates the documented death spiral for gate approvals; converts an operator decision into a system decision with an untyped string reason. Rejected.
- **Status quo:** unbounded fiber park; #20525 recurs whenever no operator is watching. Rejected.
- **Auto-pause the keeper at the bound:** trades a parked fiber for `paused = true` — the documented permanent state autonomy cannot recover. Rejected.
- **Reminder re-escalation cadence:** re-introduces bounded-interval event flooding (the audit-flood symptom of the original spiral) for marginal visibility gain over the dashboard badge + existing per-sweep supervisor warn. Deferred; can be added later without a state change.
