# TLA+ Cascade/Model Selection FSM Gap Analysis

Date: 2026-04-13
Auditor: Claude Opus 4.6 (1M context)
Status: Audit-only (no spec modifications)

## Problem Statement

Keepers intermittently hit "cascade keeper_unified: all models failed" where
both GLM (cloud) and Ollama (local) fail simultaneously. The keeper then
enters a blocked state. The existing TLA+ specs should model cascade
exhaustion and recovery, but keepers still get stuck.

## Specs Audited

| Spec | Location | Clean cfg | Buggy cfg |
|------|----------|-----------|-----------|
| CascadeExhaustion | `specs/bug-models/CascadeExhaustion.tla` | ExhaustionSafetyLastOk | ExhaustionDiagnosticConsistency violated |
| CascadeLiveness | `specs/bug-models/CascadeLiveness.tla` | Safety invariants + EventualTermination | NoPhantomSlots violated |
| OllamaBodyIntegrity | `specs/bug-models/OllamaBodyIntegrity.tla` | BalancedNeverFails | BalancedNeverFails violated |
| SlotScheduler | `specs/bug-models/SlotScheduler.tla` | MutualExclusion + NeverStuck | NeverStuck violated |
| KeeperStateMachine | `specs/keeper-state-machine/KeeperStateMachine.tla` | 9 safety + 5 liveness | N/A (no buggy variant for cascade) |
| KeeperOASAdvanced | `specs/keeper-state-machine/KeeperOASAdvanced.tla` | AtomicCascadeFallback, CommittedSideEffectsRequireReconcile | CancelledNeverAbsorbed violated |
| KeeperCircuitBreaker | `specs/KeeperCircuitBreaker.tla` | TripOnlyWithStreak | class-change-no-reset violated |

Also reviewed:
- `lib/llm_provider/cascade_fsm.ml` (OAS): pure decision logic
- `lib/llm_provider/cascade_executor.ml` (OAS): try_next loop with slot/timeout
- `lib/keeper/keeper_unified_turn.ml` (MASC): retry_loop, transient detection, manual_reconcile
- `config/cascade.json` (MASC): 2-provider setup (GLM + Ollama)

---

## What Each Spec Verifies

### CascadeExhaustion.tla

**Scope**: Models a single cascade call with N providers and an accept validator.

**What it verifies**:
- When `accept_on_exhaustion=TRUE` and all providers return Ok (but rejected
  by accept), the last response is accepted rather than failing.
- The bug model proves that if the last provider returns Error instead of Ok,
  `accept_on_exhaustion` never fires, and `last_err` misleadingly reports
  "rejected by accept validator" from the previous provider.

**What it does NOT verify**:
- No concept of provider health (healthy/unhealthy).
- No concept of simultaneous failure of all providers.
- No concept of what happens to the keeper after the cascade returns
  `all_failed`.
- No concept of retry or recovery. The cascade is one-shot.

### CascadeLiveness.tla

**Scope**: Models N keepers competing for M providers with slot contention
and a turn timeout.

**What it verifies**:
- Slot capacity and non-negativity invariants.
- No phantom slots (slots match keepers in "trying" state).
- Admitted count consistency.
- EventualTermination: every keeper reaches "done" or "timeout" (requires
  strong fairness on TurnTimeout for stuck keepers).
- The bug model proves that timeout without slot release causes phantom slot
  leak.

**What it does NOT verify**:
- Provider health toggle is modeled (`HealthToggle`) but there is no invariant
  or liveness property about what happens when ALL providers are simultaneously
  unhealthy. The keeper can get stuck in "waiting" on the last unhealthy
  provider, but this is rescued only by `TurnTimeout` (SF fairness). The spec
  does not distinguish between "timeout after 300s of useful work" and
  "timeout after 300s of waiting for all-dead providers".
- No concept of cascade retry at the keeper level (`max_transient_retries=2`
  in real code).
- No concept of manual_reconcile_required.
- No concept of what happens AFTER the keeper finishes ("done"/"timeout").
  The spec's state space ends at terminal states.

### OllamaBodyIntegrity.tla

**Scope**: Models JSON serialization -> transmission -> Ollama parsing.

**What it verifies**:
- Balanced JSON from Yojson never causes parse errors in the clean model.
- The bug model proves that large body truncation during transmission causes
  Ollama parse errors.

**What it does NOT verify**:
- No connection to the cascade. This is a standalone transmission integrity
  model.
- No concept of retry or fallback after parse error.

### SlotScheduler.tla

**Scope**: Models FIFO slot scheduling with N keepers and 1 slot.

**What it verifies**:
- Mutual exclusion (at most 1 active keeper).
- No starvation in the clean model.
- The bug model proves that timeout without slot release permanently blocks
  all keepers.

**What it does NOT verify**:
- Single-slot model only. Does not compose with the multi-provider cascade.
- No concept of cascade fallback when the slot is stuck.

### KeeperStateMachine.tla

**Scope**: The 11-state keeper lifecycle (Running, Failing, Crashed,
Restarting, Dead, etc.).

**What it verifies**:
- Terminal permanence (Dead/Stopped are forever).
- Budget monotonicity (restart_budget never revives).
- Liveness: Failing eventually resolves to a stable phase.
- Running clears manual_reconcile.

**What it does NOT verify**:
- The `TurnFailed` event sets `turn_healthy=FALSE`, which drives the keeper
  to `Failing`. But there is no event corresponding to "cascade exhausted,
  all providers dead". The spec treats all turn failures identically.
- No distinction between transient cascade failure (recoverable) and
  persistent all-provider-down (not recoverable without external change).
- No model of how `manual_reconcile_required` gets SET by cascade failure
  (it is an independent event in the spec, disconnected from cascade
  outcomes).

### KeeperOASAdvanced.tla

**Scope**: The OAS bridge timeout/error boundary, including Eio cancellation
and committed side effects.

**What it verifies**:
- No zombie fibers after termination.
- Atomic cascade fallback: clean fallback implies context not polluted and
  no committed external mutation.
- Committed side effects require reconcile.
- Cancellation is never absorbed (bug model).

**What it does NOT verify**:
- `OASApiError` is a single event. There is no distinction between "one
  provider failed, cascade moved to next" and "all providers failed, cascade
  exhausted". The spec models the OAS call as a black box that either
  succeeds or fails.
- No concept of the cascade's internal provider-by-provider progression.
- No concept of partial cascade success (e.g., GLM returns a response
  rejected by accept, then Ollama errors).

### KeeperCircuitBreaker.tla

**Scope**: Circuit breaker for tool failure recovery (class-isolated
consecutive failure counting).

**What it verifies**:
- Count bounded, trip only with same-class streak.
- Bug model: class change not resetting count causes false trips.

**What it does NOT verify**:
- No connection to cascade exhaustion. This is a tool-level circuit breaker,
  not an LLM provider circuit breaker.

---

## Identified Gaps

### Gap 1: No spec models "all providers simultaneously failed -> keeper recovery"

**Severity**: High. This is the exact production bug.

CascadeLiveness models individual keeper termination (done/timeout) but
does not model what happens next. The keeper's "done" state in
CascadeLiveness maps to a single cascade invocation, but in reality:

1. Cascade returns `Error (All models failed: ...)`.
2. `keeper_unified_turn.ml` checks `is_transient_network_error` (true for
   NetworkError).
3. Retry loop fires up to `max_transient_retries=2` times with 1s, 2s
   backoff.
4. If all 3 attempts fail (initial + 2 retries), the turn fails.
5. KeeperStateMachine `TurnFailed` fires -> `turn_healthy=FALSE` -> `Failing`.
6. If consecutive persistent failures reach `keeper_max_turn_failures`, the
   keeper crashes.

**The gap**: No spec models the retry_loop across cascade invocations.
The cascade specs model a single pass. The keeper specs model lifecycle
transitions. Nothing connects them: "cascade exhausted" -> "retry with
backoff" -> "still exhausted" -> "keeper Failing" -> "eventual recovery
when providers come back".

**Proposed addition**: A `CascadeKeeperRecovery.tla` spec that models:
- A keeper running repeated turns.
- Each turn invokes the cascade (2 providers).
- Both providers can fail simultaneously (environment action).
- The keeper retries (bounded), then enters Failing.
- When providers recover, the keeper's next turn succeeds and it exits
  Failing.
- Safety: the keeper never gets permanently stuck when providers
  eventually recover (liveness).
- Safety: manual_reconcile is triggered when committed tools precede
  cascade failure.

### Gap 2: CascadeLiveness does not verify recovery from simultaneous provider failure

**Severity**: High.

`HealthToggle` can set all providers to "unhealthy" simultaneously. When
this happens, a keeper at `kcascade[k] = NumProviders` (last provider)
transitions to "waiting". If the last provider is unhealthy, `Unblock`
is not enabled. The keeper stays in "waiting" until either:

- `HealthToggle` restores the last provider (no fairness on HealthToggle).
- `TurnTimeout` fires (requires SF fairness, which is only in SpecLive,
  not the default Spec).

The default `CascadeLiveness.cfg` uses `SPECIFICATION Spec` (without
SF on TurnTimeout) and only checks safety invariants. The liveness
property `EventualTermination` is mentioned in comments but not in the
cfg file.

**Proposed addition**:
- Add a `CascadeLiveness-liveness.cfg` that uses `SpecLive` and checks
  `EventualTermination`.
- Add an invariant: `AllUnhealthyImpliesNoWaitingWithoutTimeout` that
  verifies keepers waiting on all-unhealthy providers are rescued by
  timeout.
- Add a property for recovery: `AllUnhealthyEventuallyHealthy ~>
  WaitingKeeperUnblocked`.

### Gap 3: No spec models the cascade-level FSM decisions from cascade_fsm.ml

**Severity**: Medium.

`Cascade_fsm.decide` is the pure decision core of the cascade. Its logic
is well-tested with inline tests but never formally verified. The
CascadeExhaustion spec models a related but different concern (accept
validator semantics), not the `decide` function itself.

Critical decision paths not modeled:
- `Call_err` where `should_cascade_to_next` returns `false` -> immediate
  `Exhausted` (non-cascadeable error like HTTP 404 or EMFILE). This short-
  circuits the cascade even when other providers are healthy.
- `Slot_full` always returns `Try_next`, even for `is_last=true`. This
  means a slot-full condition on the last provider does NOT block (unlike
  CascadeLiveness which models blocking on the last provider). The real
  code at `cascade_executor.ml:464-473` blocks on the last provider via
  `with_permit_priority`, but the FSM `Slot_full -> Try_next` suggests
  otherwise. This is because the executor handles the blocking before
  calling the FSM. The specs should document this explicitly.

**Proposed addition**: A `CascadeFSMDecision.tla` spec that models the
`decide` function as a pure state machine over `(outcome, is_last,
accept_on_exhaustion)` inputs, verifying exhaustive coverage and the
impossibility of both `Accept` and `Exhausted` for the same input.

### Gap 4: No spec models interaction between cascade failure and manual_reconcile_required

**Severity**: Medium-High.

In `keeper_unified_turn.ml`, the path from cascade failure to
manual_reconcile is:

1. Cascade returns Error.
2. If mutating tools already committed -> `classify_post_commit_failure`.
3. If tools are NOT reconcile-safe -> `manual_reconcile_required = true`.
4. The keeper enters `Failing` with `manual_reconcile_required`.
5. To exit `Failing`, either:
   a. A human clears the manual_reconcile file (`keeper_clear_manual_reconcile`).
   b. The keeper's next successful turn clears it (KeeperStateMachine
      `TurnSucceeded` sets `manual_reconcile_required = FALSE`).

`KeeperStateMachine.tla` has `ManualReconcileRequired` as an independent
event. `TurnSucceeded` clears it. But there is no composition that ties
cascade failure with committed tools to `ManualReconcileRequired` and then
verifies that the keeper can actually recover (via external clearance or
successful turn).

`KeeperOASAdvanced.tla` verifies that committed side effects require
reconcile (`CommittedSideEffectsRequireReconcile`), but at a different
abstraction level (fiber/OAS boundary, not keeper lifecycle).

**Proposed addition**: Extend or compose `KeeperStateMachine.tla` with
a `CascadeOutcome` variable that feeds into `ManualReconcileRequired`
and `TurnFailed`, verifying that:
- Cascade failure with committed non-reconcile-safe tools -> Failing
  with manual_reconcile.
- Cascade failure with committed reconcile-safe tools -> Failing without
  manual_reconcile (auto-recoverable).
- Cascade failure with no committed tools -> Failing, recoverable on
  next turn.

### Gap 5: CascadeExhaustion does not model simultaneous provider failure

**Severity**: Medium.

The spec models providers sequentially: provider 1 runs, then provider 2.
Each provider independently returns Ok or Error. But the model does not
capture the real-world scenario where both providers fail due to a shared
cause (e.g., network partition, GLM rate limit + Ollama crash).

In the current spec, `ProviderError(1)` and `ProviderError(2)` are
independent events. There is no action for "environment event that makes
all providers fail simultaneously". `CascadeLiveness.tla` has
`HealthToggle` for this purpose, but `CascadeExhaustion` does not.

**Proposed addition**: Add a `CorrelatedFailure` action to
CascadeExhaustion that forces all remaining providers to Error, and verify
that the diagnostic message correctly reflects the failure mode (provider
error, not accept rejection).

---

## Answers to the 5 Questions

### Q1: Does CascadeLiveness model the "all models failed -> keeper blocked -> recovery" path?

**Partially.** CascadeLiveness models the cascade running within a single
turn and reaching a terminal state ("done" for success/all-failed, "timeout"
for wall-clock). However:
- The "done" state is terminal. No recovery is modeled.
- "All models failed" results in `ProviderErrorFinal` -> "done", which is
  the same terminal state as "success". The spec does not distinguish between
  them.
- The keeper-level retry loop (up to 3 attempts) is not modeled.
- The keeper entering "Failing" and eventually recovering is not modeled.

### Q2: Does CascadeExhaustion model what happens AFTER exhaustion at the keeper level?

**No.** CascadeExhaustion models a single cascade pass with accept validators.
It ends at `cascade_outcome = "all_failed"`. No keeper-level consequences
are modeled (retry, Failing phase, manual_reconcile, restart).

### Q3: Is there a gap between cascade-level recovery (OAS retry) and keeper-level recovery (FSM transition)?

**Yes, there are two distinct gaps:**

1. **OAS internal retry** (cascade_retry_config: max_retries=1 per provider)
   is invisible to all TLA+ specs. The cascade specs model each provider as
   succeeding or failing once. The actual retry inside OAS (Complete.complete_with_retry)
   is abstracted away.

2. **MASC keeper retry** (max_transient_retries=2 with backoff) exists in
   keeper_unified_turn.ml but is not modeled in any spec. This is the loop
   that retries the ENTIRE cascade call when the cascade returns a transient
   error. The gap is:
   - Cascade returns `NetworkError "All models failed: timeout after 30s"`.
   - `is_transient_network_error` returns `true` (it is a NetworkError).
   - The keeper retries with 1s backoff, then 2s backoff.
   - If all 3 attempts fail, the turn fails.
   - No spec verifies that 3 attempts with backoff are sufficient for
     transient failures, or that the keeper correctly gives up after 3.

### Q4: Does any spec model the interaction between cascade failure and manual_reconcile_required?

**No.** KeeperOASAdvanced models `external_side_effect_committed` ->
`NeedsReconcile` at the OAS bridge level. KeeperStateMachine has
`ManualReconcileRequired` as an independent event. But no spec ties cascade
exhaustion with committed mutating tools to the manual_reconcile flag.

The real code path (keeper_unified_turn.ml lines 1331-1393) has complex
logic: if committed tools are all reconcile-safe AND the error is transient
or a parse rejection, skip manual_reconcile. Otherwise, set it. This
decision tree is not formally verified.

### Q5: Does any spec model simultaneous provider failure for the 2-provider cascade?

**Only CascadeLiveness**, and even there it is implicit. `HealthToggle`
can independently flip each provider to "unhealthy", which means both can
be unhealthy at the same time. However:
- The HealthToggle for each provider is independent (no correlated failure
  action).
- CascadeExhaustion does not model provider health at all.
- No spec models the 2-provider cascade from `config/cascade.json`
  specifically (GLM cloud + Ollama local) where failure modes differ
  (GLM: HTTP 429/auth, Ollama: TCP stall/parse error).

---

## Summary of Proposed Additions

| Priority | Spec | Description |
|----------|------|-------------|
| P0 | `CascadeKeeperRecovery.tla` | Composed model: cascade exhaustion -> keeper retry loop -> Failing -> recovery when providers come back. The missing link between cascade specs and keeper lifecycle specs. |
| P1 | `CascadeLiveness-liveness.cfg` | Enable liveness checking (SpecLive + EventualTermination) in the cfg. Currently only safety invariants are checked by default. |
| P1 | `CascadeFSMDecision.tla` | Formal model of cascade_fsm.ml `decide` function. Verify exhaustive coverage, no unreachable states, and correct Accept vs Exhausted partitioning. |
| P2 | Extend CascadeExhaustion | Add CorrelatedFailure action + verify diagnostic accuracy under simultaneous provider error. |
| P2 | Compose KeeperStateMachine + CascadeOutcome | Connect cascade failure types to manual_reconcile_required and verify recovery paths. |

## Root Cause Hypothesis

The "keeper gets stuck" scenario is not a single bug but a composition of
behaviors that no single spec captures:

1. GLM returns HTTP 429 (rate limit) or authentication error.
2. Ollama returns timeout or parse error.
3. Both fail in the same cascade call -> `All models failed`.
4. The error is a `NetworkError`, classified as transient.
5. The keeper retries 2 more times (1s, 2s backoff).
6. If the underlying cause persists (e.g., GLM quota depleted, Ollama
   crashed), all retries fail.
7. The turn fails. `turn_healthy = false`. Keeper enters `Failing`.
8. If `keeper_max_turn_failures` (configurable) consecutive persistent
   failures are reached, the keeper crashes.
9. The supervisor may restart the keeper (if restart budget permits).
10. The restarted keeper hits the same all-providers-down condition.
11. Eventually restart budget exhausts -> `Dead`.

The gap is between steps 7 and 9: no spec verifies that the keeper's
recovery path (Failing -> supervisor restart -> Running) eventually
succeeds when providers come back online. The current specs verify each
step in isolation but not the end-to-end recovery loop.
