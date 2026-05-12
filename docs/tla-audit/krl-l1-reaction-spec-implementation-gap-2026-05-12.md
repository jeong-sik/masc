# KRL L-1 — KeeperReactionLiveness spec vs OCaml implementation gap (audit)

**Iteration**: /loop iter 58 — first entry to Phase L (`KeeperReactionLiveness.tla`).
**Date**: 2026-05-12.
**Scope**: audit-only.  No spec or OCaml mutation in this PR.
**MASC tracking**: `goal-world-reaction-liveness / task-134` (spec preamble line 11).

## Discovery

KRL preamble lists five OCaml "mirror" entry points; **three of them do not exist in the codebase today**:

| Spec citation (KRL preamble) | Exists? | Notes |
|------------------------------|---------|-------|
| `lib/keeper/keeper_event_queue.ml` | ✅ 91 LOC | Stimulus queue: `type stimulus`, `enqueue`, `dequeue`, `classify`, `drain_board_window`.  No `receipt_issued` concept. |
| `lib/keeper/keeper_unified_turn.ml` | ✅ 3037 LOC | Heavy `terminal_reason` machinery (`Keeper_turn_terminal.t`).  Maps loosely to KRL's `IssueTerminalReason`.  No `verification_state` / `goal_phase` / `task_state` concepts. |
| `lib/keeper/goal_store.ml` | ❌ MISSING | No file. |
| `lib/keeper/keeper_task_dispatch.ml` | ❌ MISSING | No file. |
| `lib/keeper/keeper_board_observer.ml` | ❌ MISSING | No file. |

Cross-checked with `rg` across all 251 `.ml` files under `lib/keeper/`: none of the spec's modeled concepts (`goal_phase`, `task_state`, `board_cursor`, `verifier_reaction`, `receipt_issued`) appear *anywhere* in the codebase. The spec is pure design ground.

## Comparison to iter 56 KAL audit

| Aspect | KAL (iter 56 #14895) | KRL (this audit) |
|--------|----------------------|------------------|
| OCaml LOC matching spec concepts | 845 (7 modules) | ~3128 (2 modules) but **0 spec concept hits** |
| Activation status | dormant — `MASC_ADMISSION_USE_NEW=1` flag-gated | **non-existent** — no flag, no code path |
| Drift class | *flag-gated dormancy* | *design ground without runtime* |
| Risk severity (today) | LOW (flag off by default) | LOW (no caller, no harm) |
| Risk severity (on activation) | HIGH (K-2.a bucket leak) | UNKNOWN (no implementation to assess) |

KAL has actual code waiting to be activated; KRL has only a TLA+ specification of the *intended* world-reaction contract.  Both share the same root: a spec landed before its OCaml runtime.

## Liveness claim coverage

| Claim | Spec action | Nearest OCaml | Coverage |
|-------|-------------|---------------|----------|
| **L1** BoardEnqueueLeadsToReceipt | `EnqueueStimulus → StartTurn → IssueReceipt` | `keeper_event_queue.enqueue/dequeue` (queue only) | Partial — queue exists, no per-stimulus receipt FSM |
| **L2** VerificationLeadsToReaction | `RequestVerification → VerifierReaction → TimeoutEscalate` | none | Missing |
| **L3** GoalVerificationLeadsToResolution | spec `goal_phase` transitions | none | Missing |
| **L4** TaskTransitionLeadsToReceipt | spec `task_state` transitions | none | Missing |
| **L5** CursorAdvancementRequiresAck | spec `cursor_advanced`/`cursor_acked` | none | Missing |

Only **L1 partial** has any OCaml representation today, and even that is one-level abstraction higher (a generic queue, not the per-stimulus FSM the spec models).

## Recommended follow-up RFCs (L-2.*)

These are call-outs, **not fixes in this audit**.

1. **L-2.a (LOW, doc-only)** — Mirror iter 57 K-2.d: add a "Runtime status" block to KRL preamble explaining that this is a pure design ground for MASC task `goal-world-reaction-liveness/task-134`, not the running runtime.  Cross-reference this audit memo.  Honest-doc pattern, 11th datapoint candidate.

2. **L-2.b (LOW, doc-only)** — Replace the 3 broken module citations with the truthful state.  Options:
   - (b.1) Remove the citations entirely until the modules exist.
   - (b.2) Mark them with a `TBD:` prefix and a forward-reference to the design RFC.

3. **L-2.c (MED, design)** — Author the RFC that defines the runtime layer matching this spec.  Should specify which existing modules (`keeper_event_queue.ml`, `keeper_unified_turn.ml`) get extended vs which new modules are created.  Not in /loop scope — needs explicit user direction.

4. **L-2.d (MED, fixture)** — Add a `BugAction_SilentDrop` paired buggy cfg for L1 — the spec's "Bug-Model contract" comment promises a buggy variant that violates `BoardEnqueueLeadsToReceipt`, but the `KeeperReactionLiveness-buggy.cfg` (already present) was not verified to actually fail.  Re-run TLC to confirm the buggy fixture catches the silent drop.

## Out-of-scope follow-ups

- **L-3** TLC verification refresh — clean `.cfg` and `-buggy.cfg` haven't been run in this loop.  Comment-only KRL changes (L-2.a, L-2.b) are TLC-transparent per the 10-datapoint honest-doc precedent; design or implementation changes (L-2.c, L-2.d) are not.

## Pattern observation: spec-ahead-of-runtime is a new sub-class

iter 1/22/38/47/56 first-entry audits each found existing OCaml↔spec drift in *both directions* — sometimes the spec was stale (Zombie, 6th drift class), sometimes the runtime was missing the spec's discipline (KCAF call_err).  KRL is the first first-entry audit where the runtime simply does not exist.

This widens the audit-only first-entry pattern's findings vocabulary:
- iter 1 (KSM A-1) — coverage gap (3 specs cover same OCaml inconsistently)
- iter 22 (KCR C-1) — drift (#14668 spec-only cap fix)
- iter 38 (KCL E-1) — cross-spec staleness (Phase H entry)
- iter 47 (KCtxL H-1) — doc-layer drift (Zombie mapping missing)
- iter 56 (KAL K-1) — dormancy (flag-gated runtime)
- **iter 58 (KRL L-1) — design-ground (no runtime)**

Each is a distinct first-entry class.  Cataloguing them lets future first-entries triage faster.

## Verification (this audit)

- `wc -l specs/keeper-state-machine/KeeperReactionLiveness.tla` → 327 LOC.
- `ls lib/keeper/{goal_store,keeper_task_dispatch,keeper_board_observer}.ml*` → all three "no matches".
- `rg -l 'goal_phase|task_state|board_cursor|verifier_reaction|receipt_issued' lib/` → 0 matches across 251 `.ml` files.
- `keeper_event_queue.mli` surface: `stimulus` / `enqueue` / `dequeue` / `classify` / `drain_board_window` — pure queue, no receipt FSM.
- `keeper_unified_turn.ml` surface: heavy `terminal_reason` usage (line 25, 31, 87, 96, 98, 339, 361, 369 ...), no `goal_phase` / `verification_state` / `task_state`.

No spec, OCaml, or .cfg mutation by this PR.

## RFC trail

RFC-WAIVED — audit-only memo. Recommended follow-up RFCs:
- L-2.a (preamble Runtime status note, doc-only, honest-doc 11th datapoint candidate)
- L-2.b (broken module citations, doc-only)
- L-2.c (design RFC for runtime layer — needs explicit user direction)
- L-2.d (buggy cfg verification refresh — TLC re-run)
- L-3 (clean TLC verify after L-2.a/b)

Picked up by iter 59+ when reaction-liveness becomes active scope, or as opportunistic finds in the FSM queue.
