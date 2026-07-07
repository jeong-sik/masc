# RFC-0319 — Operator Approval Mode (AUTO 승인 모드) with separation-of-duties invariant

- Status: Draft
- Area: `lib/operator_approval.ml` (approval pipeline), `lib/operator/operator_control*` (mode state + operator API), governance dashboard `dashboard/src/components/approvals/approvals-surface.ts` + `governance-store.ts`
- Builds on / touches: RFC-0304 (HITL summary), the keeper-v2 approvals surface (#23603), the existing `Agent_sdk.Approval` pipeline (`auto_approve_known_tools` + `high_risk_gate`), the per-request "항상 승인" always-rule (`respondToKeeperApproval(id, 'approve', rememberRule=true)`)
- Evidence base: keeper-v2 design mockup (`~/Downloads/Keeper Agent v2 (standalone) (3).html`) renders an **AUTO 승인 모드** panel with the note "비가역·파괴적(bad)은 항상 수동 결재 — 직무분리 원칙". Audit 2026-07-08: no runtime operator-toggleable approval mode exists. `rg "auto_approve|approval_mode" lib/server/` returns **zero** governance API endpoints; the only auto-approval is `operator_approval.ml:40` `auto_approve_known_tools` (a fixed compile-time policy) plus per-request always-rules.

## Problem (audited)

The v2 design promises an operator control the runtime does not have: a **mode** that lets the operator run the HITL queue in *auto* (low-risk keeper actions clear without a human) or *manual* (every gated action waits), with a hard invariant that destructive/irreversible actions are **never** auto-approved.

Today:

- `operator_approval.ml` builds a fixed pipeline: `auto_approve_known_tools <safe list>` then a `high_risk_gate` that rejects high-risk tools to the operator. This is compile-time, not operator-controlled at runtime.
- The dashboard can approve, approve+always (a per-request rule), or reject. There is **no mode**: the operator cannot say "auto-clear low-risk for the next hour" and they cannot see or change a global posture.
- Building the design's toggle as UI-only would be a **dead/dangerous stub**: a switch that reads as "auto-approving keeper actions" while gating nothing. A governance control that does not actually gate is worse than absent — it manufactures false assurance. This violates the workspace no-stub / no-silent-failure bar and is safety-relevant.

## Boundary and principles

- **MASC owns this; OAS is untouched.** Approval mode is a keeper-workspace governance concept. No dependency is added to OAS.
- **Judgment stays deterministic, not LLM.** Whether a request is auto-eligible is decided by its **typed risk band** (`critical|high|medium|low`), never by an LLM or a string classifier. The LLM boundary is the *context summary* (RFC-0304), which advises the operator; it never decides auto-approval.
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

### 3. Decision integration

At the approval decision point (`operator_approval.ml` pipeline), consult the mode:

```
decide(request):
  band = risk_band(request)                 (* typed; unknown -> Unclassified *)
  if band ∈ {critical, high} or band = Unclassified:
      -> Manual (queue for operator)         (* invariant + fail-closed *)
  else match mode with
      | Manual        -> Manual (queue)
      | Auto_low_risk -> if band ∈ auto_eligible_bands
                         then Auto_approved { mode; band }   (* attributed *)
                         else Manual (queue)
```

- The `{critical, high} | Unclassified -> Manual` line is evaluated **before** the mode branch, so no mode can reach a destructive action. Exhaustive `match` over the band and mode; a new band or mode fails to compile until handled.

### 4. Operator API

- `GET /api/v1/governance/approval-mode` → current mode + auto-eligible bands.
- `POST /api/v1/governance/approval-mode { mode }` → set mode; operator-authenticated, audited (who/when/from→to). Rejects any value outside the closed variant.

### 5. Dashboard

- The AUTO 승인 모드 panel binds to this typed state (read the mode, POST on toggle). The "비가역·파괴적(bad)은 항상 수동" line is not decoration — it states the enforced invariant.
- Auto-approved items appear in 최근 처리 / 이력 with an `auto` decision class distinct from human `approve`, so the operator can audit what the mode cleared.

## Non-goals

- **LLM-judged auto-approval.** Auto-eligibility is band-deterministic only.
- **Auto-approving destructive/high-risk actions.** Forbidden by the invariant; not a configurable option.
- **Per-tool auto rules.** That is the existing per-request always-rule (`rememberRule`); this RFC is the global posture, orthogonal to it.
- **Time-boxed / scheduled auto windows.** Possible follow-up; out of scope here.

## Verification

- **Mode round-trip**: GET/POST reflect the set mode; an out-of-variant POST is rejected.
- **Invariant (must-fail model)**: in `Auto_low_risk`, a `critical` and a `high` request are queued (never auto), including when the band is deliberately misclassified upward — assert no `Auto_approved` record is ever emitted for `{critical, high}`. TLA+ `NextBuggy = Next \/ AutoApprovesDestructive` must violate `NoDestructiveAutoApproval`; clean `Next` must satisfy it (per the workspace TLA+ bug-model pattern).
- **Fail-closed**: an unclassified/missing band is queued, not auto-approved, in every mode.
- **Observability**: an auto-approval emits a resolved-approval record attributed to `auto_mode` with the authorizing band; it appears in the dashboard history.
- **Exhaustiveness**: adding a risk band or mode variant fails to compile at the decision site and the projection until handled.

## Rollback

Mode defaults to `Manual`; the decision point falls through to today's always-queue behavior. Removing the API + mode state reverts to the current fixed pipeline with no data migration. The invariant floor (`{critical, high} -> Manual`) is retained regardless, matching the existing `high_risk_gate`.
