# RFC-0323 — Done via verification + linked re-run tasks (retire Done-reclaim)

- Status: Draft
- Decision driver: operator (2026-07-08) — "승인-반려 스텝을 안 거친 것은 Done이 되면 안 된다. 반려되면 안 하든가, 승인되면 하든가. 다시 하려면 태스크를 만들고 연관으로 걸어라."
- Area: `lib/workspace/workspace_task_lifecycle.ml` (`decide`, `resolve_claim`), `lib/types/types_core.ml` (`task` record, `task_claim_decision`), `lib/task/tool_task*.ml` (tool surface + schema text), `lib/workspace/workspace_task_create.ml`
- Builds on / supersedes:
  - **Implements RFC-0308** (verification-required done guard — currently a dead scaffold: error variant `Verification_required_use_submit` at `workspace_task_lifecycle.ml:9` and `task_requires_verification` at `tool_task_contract_gate.ml:26-29` both have zero producers/callers).
  - **Supersedes the Done-reclaim mechanism of #23632** (merged as `6bbcecf52f`) including the interim same-actor guard (`8fce078b2c`, labeled `removal target: RFC-0323 merge`).
  - Complements RFC-0311 (evidence-ref gate), RFC-0220/0221 (verification FSM/atomicity), RFC-0267 (task-goal linkage precedent), RFC-0314 (recurrence).
- Evidence base: 4-scout census 2026-07-08 (Done producers / verification lane / task relations / reclaim consumers), file:line cited inline.

## Problem (audited)

Fake completions are structural, not accidental. The FSM has two completion lanes and the weak one is cheaper:

- **Weak lane (always legal)**: `(Claimed|InProgress, Done_action)` by the owner — `workspace_task_lifecycle.ml:146-153`. Tool-layer gates exist (RFC-0311 evidence refs at `tool_task.ml:445-467`, LLM review) but no second agent ever looks at the work, and the RFC-0199 deterministic probe (`keeper_tool_task_runtime.ml:630` → `force_done_task_r`, System authority) bypasses every tool-layer gate.
- **Strong lane (optional)**: `Submit_for_verification` (non-empty notes required, `workspace_task_transitions.ml:239-247`) → cross-agent verifier binding (self-block #19314, `workspace_task_lifecycle.ml:113-128`) → `Approve_verification → Done` / `Reject_verification → InProgress{assignee}` (`workspace_task_lifecycle.ml:206-239`).
- The tool schema actively teaches the weak lane: "Tasks created through masc_add_task complete via action='done' … they do not route normal completion through the verifier agent" (`tool_task_schemas.ml:227-229`).

#23632 (task-1869) responded to the *symptom* — completed coordination tasks that need to run again — by making `Done + Allow_reclaim` claimable in place. That (a) weakens what `Done` means, (b) required a same-actor livelock guard, and (c) is **unreachable in production anyway**: the only `Allow_reclaim` writer is the supervisor pause policy (`keeper_supervisor_pause_policy.ml:52,75`), which feeds `Release → Todo`, and claiming wipes the reclaim fields (`workspace_task_claim.ml:16-20`) — so no task actually reaches `Done` with `Allow_reclaim` set. The "6 TaskError fingerprints" taxonomy (`task_transition_state.ml:42,89,261`) has no production caller either.

## Decision

1. **Done is reached only through the verification lane.** `Done_action` on a verification-required task returns `Verification_required_use_submit` (the RFC-0308 error that already exists). Approve → `Done`; Reject → `InProgress{assignee}` (already implemented; unchanged).
2. **A verified Done is terminal for every actor.** No reclaim-on-Done. To run the work again, **create a new task linked to the completed predecessor** (`predecessor_task_id`), or register a cadence via RFC-0314 recurrence that creates new task instances.
3. **Retire the #23632 Done-reclaim mechanism** (both the `task_claim_decision` Done arm and the `resolve_claim` Done arm, including the interim same-actor guard).

## Workstreams

### W1 — Implement the RFC-0308 guard (close the weak lane)

`Workspace_task_lifecycle.decide`, `Done_action` arms (`workspace_task_lifecycle.ml:146-157`): when the task requires verification, return `Verification_required_use_submit` instead of `Done`. Rollout in two phases:

- **Phase A (scoped, immediate):** required = task has a `completion_contract`/`required_evidence` contract or its goal sets a verifier policy — exactly RFC-0308's original scope; wire the existing `task_requires_verification` seam.
- **Phase B (default-on, the operator's end state):** verification required for **all** tasks; `Done_action` survives only as the degenerate no-op on already-`Done`. Flip is a single default change guarded by the Phase-A plumbing; fleet-readiness gate: verifier latency must be observed in Phase A (a submit with no verifier is a wake signal today — `keeper_world_observation.ml:1248-1251` — so pending verifications already pull keepers).
- **The RFC-0199 deterministic probe** (`force_done_task_r`) must not remain a bypass. Option (i): probe result becomes a *submit* + System-actor approve (System ≠ assignee, so the self-approval check holds — machine verifier, deterministic evidence attached). Option (ii): probe is demoted to advisory (posts evidence, human/keeper verifier approves). Decide in W1 review; (i) preserves current automation.
- Schema text fix (`tool_task_schemas.ml:220-248`): stop teaching the weak lane; describe submit→approve as the completion path.

### W2 — Linked re-run tasks ("다시 하려면 태스크 만들고 연관")

- Add `predecessor_task_id : string option` to `Masc_domain.task` (beside `created_by`, `types_core.ml:595`) — write-once provenance. Hand-rolled codec (`task_to_yojson`/`of_yojson` at `types_core.ml:681,729`) means absent key → `None`; existing backlog JSON parses unchanged.
- `masc_add_task` gains optional `predecessor_task_id`; validation mirrors the `Unknown_goal` pattern (`tool_task_handlers.ml:302-316`): unknown id → typed error; for re-run linkage the predecessor must be terminal (`Done`/`Cancelled`).
- Not a goal-registry clone: RFC-0267's side-registry rationale (many-to-many, relink-after-create) doesn't apply to an immutable one-shot pointer. `contract.links` (`task_execution_links`) is scoped to runtime evidence producers — not overloaded.
- RFC-0314 recurrence integration (follow-up, not blocking): a recurring action variant that creates a task instance may carry `predecessor_task_id` of the previous instance, giving cadenced re-runs the same provenance chain.

### W3 — Retire Done-reclaim (#23632 mechanism)

- `types_core.ml` `task_claim_decision` `Done` arm (653-665) → unconditional `Claim_unavailable (Claim_block_not_todo …)`.
- `workspace_task_lifecycle.ml` `resolve_claim` `Done` arm (74-91) → `Held_by_other assignee` (pre-#23632 shape); delete the interim same-actor WORKAROUND guard (`8fce078b2c`).
- `Blocked_by_reclaim_policy` stays only if the `Todo + Block_reclaim` hard-stop keeps producing it; `reclaim_policy` itself **survives with its original meaning** — an operator hard-stop on re-claiming a *recycled Todo* (`Block_reclaim`, set on release: `workspace_task_claim.ml:330-361`). Only the Done semantics retire.
- Safe by census: zero production writers produce a claimable `Done+Allow_reclaim` task today, so no behavior regresses; the task-1869 need is served by W2 (+ RFC-0314).

## Invariants (end state)

- `Done` is producible only by `Approve_verification` (plus W1's probe disposition). No status other than `AwaitingVerification` transitions to `Done`.
- `Reject_verification → InProgress{assignee}` — rejected work is not done and returns to the submitter.
- Terminal tasks are never re-claimed; re-running work creates a new task with `predecessor_task_id` provenance.
- Verifier ≠ assignee (existing #19314 block, identity-normalized).

## Out of scope (recorded, separate follow-ups)

Census surfaced verification-lane gaps that this RFC does not fix but which matter for Phase B integrity:
- Verifier binding is advisory — any non-submitter can approve even when another verifier is bound (`workspace_task_lifecycle.ml:207-208` matches phase with `_`).
- Approve accepts empty notes (asymmetric with submit; `workspace_task_lifecycle.ml:217-223`) and the approve-side contract gate is a no-op seam (`tool_task_contract_gate.ml:66-76`).
- Dashboard operator verdicts run as `operator:<actor>` (`server_dashboard_http.ml:469-471`), an identity namespace that sidesteps the self-approval check for a human who also drives an assignee keeper.
- Verification timeout sweep is neutered (`verification_protocol.ml:380-394`).

## Verification

- W1-A: unit — contracted task + `Done_action` → `Verification_required_use_submit`; uncontracted task unchanged. W1-B: default flip test set; probe disposition test (System approve is not self-approval).
- W2: codec round-trip with/without `predecessor_task_id`; unknown-id rejection; non-terminal predecessor rejection for re-run links.
- W3: `Done` never `Claim_available` for any (policy, actor); existing `Todo + Block_reclaim` hard-stop still blocks; removal of the same-actor guard test replaced by "Done is terminal" tests.
