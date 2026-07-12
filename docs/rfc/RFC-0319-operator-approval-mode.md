# RFC-0319 — Operator Approval Mode (AUTO 승인 모드) with separation-of-duties invariant

- Status: Implemented
- Area: keeper HITL queue decision path: `lib/keeper/keeper_guards.ml` (`governance_approval_guard`), `lib/governance_pipeline.ml` (`to_oas_approval_callback`), `lib/keeper/keeper_approval_queue*.ml` (`submit_and_await`, `resolve_with_policy`, rule matching, audit), `lib/server/server_dashboard_http.ml` + `server_routes_http_routes_dashboard.ml` (dashboard resolve/mode API), and `dashboard/src/components/approvals/approvals-surface.ts` / `dashboard/src/components/governance-actions.ts`.
- Builds on / touches: RFC-0304 (HITL summary), the keeper-v2 approvals surface (#23603), the existing `Agent_sdk.Hooks.ApprovalRequired` callback path, `Keeper_approval_queue.submit_and_await`, `Keeper_approval_queue.resolve_with_policy`, and the per-request "항상 승인" rule (`respondToKeeperApproval(id, 'approve', rememberRule=true)`).
- Evidence base: keeper-v2 design mockup (`~/Downloads/Keeper Agent v2 (standalone) (3).html`) renders an **AUTO 승인 모드** panel with the note "비가역·파괴적(bad)은 항상 수동 결재 — 직무분리 원칙". Audit 2026-07-08: no runtime operator-toggleable keeper approval mode exists. `rg "approval_mode|approval-mode" lib/server/ dashboard/src` returns **zero** dashboard/governance mode endpoints; current auto paths are fixed keeper metadata/rule paths in `Governance_pipeline.to_oas_approval_callback` (`always_approve`, `find_matching_rule`) plus the legacy SDK-local `operator_approval.ml` policy, not a global operator mode.

## Problem (audited)

The v2 design promises an operator control the runtime does not have: a **mode** that lets the operator run the HITL queue in *auto* (low-risk keeper actions clear without a human) or *manual* (every gated action waits), with a hard invariant that destructive/irreversible actions are **never** auto-approved.

At the 2026-07-08 design audit (before implementation):

- `governance_approval_guard` now decides when a keeper tool call needs approval; the real approve/queue decision is in `Governance_pipeline.to_oas_approval_callback`. Critical risk or a structured runtime blocker establishes an operator-only floor: it bypasses automatic flags/rules/mode and enters the ordinary HITL continuation path instead of becoming a terminal policy rejection.
- The dashboard can approve, approve+always (a per-request rule persisted through `resolve_with_policy`), or reject via `respondToKeeperApproval` -> `/api/v1/dashboard/governance/approvals/resolve`. There is **no mode**: the operator cannot say "auto-clear low-risk for the next hour" and they cannot see or change a global posture.
- Building the design's toggle as UI-only would be a **dead/dangerous stub**: a switch that reads as "auto-approving keeper actions" while gating nothing. A governance control that does not actually gate is worse than absent — it manufactures false assurance. This violates the workspace no-stub / no-silent-failure bar and is safety-relevant.

## Boundary and principles

- **MASC owns this; OAS is untouched.** Approval mode is a keeper-workspace governance concept. No dependency is added to OAS.
- **Judgment stays deterministic, not LLM.** Whether a request is auto-eligible is decided by a **typed risk projection** (`Classified critical|high|medium|low` or `Unclassified reason`), never by an LLM or a string classifier. The LLM boundary is the *context summary* (RFC-0304), which advises the operator; it never decides auto-approval.
- **Separation-of-duties invariant (hard floor).** In any mode, an action whose risk band is `bad` (critical) — and, by default, `warn` (high) — is **never** auto-approved. Auto mode can only clear the auto-eligible band set. This mirrors the existing `high_risk_gate` and the design's stated principle. The invariant is enforced at the decision point, not by UI, so a misconfigured or malicious mode value cannot bypass it.
- **Fail-closed.** An unclassified / unknown / missing risk band is treated as **manual** (never auto-eligible). Auto-eligibility requires a positive, known low-risk classification.
- **Everything is observed.** Every auto-approval emits an attributed resolved-approval record (actor = `auto_mode`, with the mode + risk band that authorized it) into the same stream the manual decisions use, so the dashboard 최근 처리 / 이력 shows auto-clears exactly like human decisions. No auto-approval is silent.

## Proposal

### 1. Typed mode (closed variant, not bool/string)

```ocaml
type approval_mode =
  | Manual              (* every gated action waits for an operator decision *)
  | Auto_low_risk       (* auto-approve the auto-eligible band set; all else waits *)
```

- A `bool "auto_on"` or a string is rejected: a closed variant makes an unhandled mode a compile error at the decision site and forbids drift (e.g. an "auto_all" that bypasses the invariant can never be represented).
- `Auto_low_risk` carries no free-form scope. The auto-eligible band set is a single named constant (default: `{ low }`; `medium` is opt-in via a separate follow-up if operators ask). `high` and `critical` are **structurally excluded** — not a config value, a type-level absence.

### 2. Mode state (single source of truth)

- Operator-set, persisted under the operator control plane (`lib/operator/operator_control*`), default `Manual`.
- Read/write only through a typed accessor; no scattered readers. One SSOT constant for the auto-eligible band set.
- The keeper callback (`Governance_pipeline.to_oas_approval_callback`) reads this accessor directly; the dashboard is only a control/view over the same state.

### 3. Typed risk projection (fail-closed surface)

Current backend queue risk is a closed `risk_level = Low | Medium | High | Critical` in `Keeper_approval_queue_rules_types`; it has no representation for missing, decode-failed, or future/unknown risk. The auto-mode decision must not collapse those cases into `Low`.

```ocaml
type approval_risk_projection =
  | Classified of Keeper_approval_queue.risk_level
  | Unclassified of { reason : string }
```

- `Governance_pipeline.assess_risk` and `queue_risk_level` feed `Classified risk`.
- Any dashboard/API decode, persisted queue decode, future wire value, or classifier/downcast failure that cannot produce the closed risk type becomes `Unclassified`, not a default `Low`/`Medium`.
- `Unclassified` is manual-only in every mode and is rendered as "미분류" in the dashboard. It is not hidden behind the `info` visual band.

### 4. Decision integration

At the keeper approval callback decision point (`Governance_pipeline.to_oas_approval_callback`), apply the operator-only floor before `always_approve`, remembered rules, and approval mode:

```
decide(request):
  risk = approval_risk_projection(request)
  if manual_approval_required(request):       (* critical/runtime blocker *)
      -> Manual HITL continuation             (* never an automatic decision *)
  if soft_forbidden(request):                (* destructive tool/op signal today *)
      -> Manual (submit_and_await)            (* mode must not bypass it *)
  if risk ∈ {Classified Critical, Classified High, Unclassified _}:
      -> Manual (submit_and_await)            (* invariant + fail-closed *)
  else match mode with
      | Manual        -> Manual (submit_and_await)
      | Auto_low_risk -> if risk ∈ auto_eligible_bands
                         then Auto_approved { mode; risk }    (* attributed audit *)
                         else Manual (submit_and_await)
```

- The `{Critical, High} | Unclassified -> Manual` line is evaluated **before** the mode branch, so no mode can reach a destructive action. Exhaustive `match` over the projection and mode; a new band or mode fails to compile until handled.
- Existing always/rule auto-approval remains orthogonal but shares the same floor: operator-only requests skip every auto path, mode never overrides `soft_forbidden`, and `High | Critical | Unclassified` never auto-approves by mode. An explicit one-shot operator grant is consumed before the floor is re-evaluated so a resolved continuation can actually run.
- `Keeper_approval_queue.audit_approval_event` records mode auto-clears with a distinct `event_type` such as `auto_approved_mode_low_risk`, `auto_approved=true`, `created_by=auto_mode`, and the authorizing mode/risk fields.

### 5. Operator API

- `GET /api/v1/dashboard/governance/approval-mode` → current mode + auto-eligible bands + invariant floor.
- `POST /api/v1/dashboard/governance/approval-mode { mode }` → set mode; operator-authenticated, audited (who/when/from→to). Rejects any value outside the closed variant.

### 6. Dashboard

- The AUTO 승인 모드 panel binds to this typed state (read the mode, POST on toggle). The "비가역·파괴적(bad)은 항상 수동" line is not decoration — it states the enforced invariant.
- Auto-approved items appear in 최근 처리 / 이력 with an `auto` decision class distinct from human `approve`, so the operator can audit what the mode cleared.

## Non-goals

- **LLM-judged auto-approval.** Auto-eligibility is band-deterministic only.
- **Auto-approving destructive/high-risk actions.** Forbidden by the invariant; not a configurable option.
- **Per-tool auto rules.** That is the existing per-request always-rule (`rememberRule`); this RFC is the global posture, orthogonal to it.
- **Time-boxed / scheduled auto windows.** Possible follow-up; out of scope here.

## Verification

- **Mode round-trip**: GET/POST reflect the set mode; an out-of-variant POST is rejected.
- **Queue integration**: `governance_approval_guard` raises `ApprovalRequired`; `to_oas_approval_callback` chooses exactly one of operator continuation, mode auto-approve, always/rule auto-approve, or ordinary threshold approval.
- **Invariant (must-fail model)**: in `Auto_low_risk`, a `critical` and a `high` request are queued/rejected according to the existing hard floor, never auto. TLA+ `NextBuggy = Next \/ AutoApprovesDestructive` must violate `NoDestructiveAutoApproval`; clean `Next` must satisfy it (per the workspace TLA+ bug-model pattern).
- **Classifier/downcast bug cases**: a destructive request that a buggy classifier/downcast reports as low but still carries the existing destructive tool/op signal is manual-only; a missing risk field and an unknown future wire value become `Unclassified`; assert no `Auto_approved` record is emitted for any of these cases.
- **Fail-closed**: an unclassified/missing band is queued, not auto-approved, in every mode.
- **Observability**: an auto-approval emits a resolved-approval record attributed to `auto_mode` with the authorizing band; it appears in the dashboard history.
- **Exhaustiveness**: adding a risk band or mode variant fails to compile at the decision site and the projection until handled.

## Rollback

Mode defaults to `Manual`; the decision point falls through to today's always-queue behavior. Removing the API + mode state reverts to the current fixed pipeline with no data migration. The invariant floor (`{critical, high} -> Manual`) is retained regardless, matching the existing `high_risk_gate`.
