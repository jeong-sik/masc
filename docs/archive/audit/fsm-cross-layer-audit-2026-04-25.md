---
status: reference
last_verified: 2026-04-25
code_refs:
  - lib/keeper/keeper_registry.ml
  - dashboard/src/api/schemas/keeper-composite.ts
  - scripts/ci/check-tla-harness-coverage.sh
---

# FSM Cross-Layer Audit (2026-04-25)

## Scope

Cross-layer review of the currently active FSM surfaces:

| Axis | Runtime source | Operator/read-model surface | Spec/test surface |
| --- | --- | --- | --- |
| Keeper lifecycle | `Keeper_state_machine.phase` | transition audit, runtime trust, `keeper_phase_changed` | `KeeperStateMachine.tla`, `test_keeper_state_machine*` |
| Composite FSM | `Keeper_composite_observer` + registry turn fields | `/api/v1/keepers/:name/composite`, FSM Hub, fleet matrix | `KeeperCompositeLifecycle.tla`, dashboard schema/tests |
| Cascade | `Cascade_fsm.decide`, cascade runtime/strategy | cascade dashboard, execution receipt | `KeeperCascadeLifecycle.tla`, cascade tests |
| Task/verification | `Verification.request_status`, `verification_protocol` | board posts, SSE verification events | `TaskLifecycle.tla`, `test_verification_fsm` |
| Goal/product state | `Goal_store`, `Goal_phase`, state-product modules | dashboard goal tree, goal tools | `StateProduct.tla`, `CoordinationProduct.tla` |
| Social ledger | `keeper_social_model_magentic_ledger_fsm` | social-model belief summary | `KeeperSocialModelMagenticLedger.tla`, ledger tests |
| Server/product state | server startup/state-product modules | runtime/bootstrap surfaces | `ServerState.tla`, `StateProduct.tla` |

Validation was direct source inspection plus targeted checks. Full TLC was not run in this pass.

## Findings and Fixes

### 1. Dashboard composite schema hid backend-ahead FSM states

**Severity**: High
**Status**: fixed in this PR

`dashboard/src/api/schemas/keeper-composite.ts` used `fallback(picklist(...), Stable/idle/clean)` for FSM state fields. That meant a new backend state was parsed successfully but rendered as a harmless default. This was inconsistent with `keeper-transitions.ts`, which intentionally keeps phase names open strings so operator diagnostics preserve drift.

Fix:
- Changed composite FSM state schemas to `string()`.
- Updated tests to assert unknown phase/turn/decision/cascade/breaker values are preserved.
- Left only the rollout-era missing `circuit_breaker` key fallback in component code (`missing key -> clean`), because absent data from an older backend is different from an explicit unknown value.

### 2. Direct turn sub-FSM mutations changed the composite read model without a composite tick

**Severity**: High
**Status**: fixed in this PR

`Keeper_registry.dispatch_event_with_audit` emitted `keeper_composite_changed`, but direct live-turn helpers also mutate fields consumed by `Keeper_composite_observer`: `current_turn_observation`, turn phase, decision stage, cascade state, selected model, and `last_completed_turn`.

Fix:
- Added one shared `broadcast_composite_changed` helper in `keeper_registry.ml`.
- Emitted the signal after direct turn-helper mutations when a live turn actually changes.
- Reused the helper in `dispatch_event_with_audit` to avoid duplicate literal envelopes.
- Added an OCaml test proving `mark_turn_started`, `set_turn_cascade_state`, and `mark_turn_finished` each produce `keeper_composite_changed`.
- Updated `docs/SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md` so the operator SSOT now matches code.

### 3. TLA+ harness coverage could silently drift

**Severity**: Medium
**Status**: guarded in this PR; existing debt documented

`scripts/tla-check.sh` is explicit for most directories and dynamic only for `specs/bug-models/`. Several cfg-backed specs exist outside that harness. The prior drift class was "spec present but unguarded"; the general case still needed a cheap gate.

Fix:
- Added `scripts/ci/check-tla-harness-coverage.sh`.
- CI now runs the gate after `check-tla-variant-sync.sh`.
- Existing unchecked cfg-backed specs are explicitly allowlisted as known debt; future cfg-backed `.tla` files must be wired into `scripts/tla-check.sh` or consciously added to the allowlist with an audit note.

Known unchecked cfg-backed specs as of this audit:

```text
specs/boundary/CascadeKeeperRecovery.tla
specs/boundary/CascadeStrategy.tla
specs/boundary/CascadeStrategyStateful.tla
specs/boundary/KeeperRecoveryOrchestration.tla
specs/boundary/KeeperTurnScheduler.tla
specs/checkpoint-trim/CheckpointTrim.tla
specs/closure/ContractClosure.tla
specs/keeper-state-machine/KeeperConditionsGovernPhase.tla
specs/keeper-state-machine/KeeperCounterCausality.tla
specs/keeper-state-machine/KeeperDwellMonotone.tla
specs/keeper-state-machine/KeeperMemoryLifecycle.tla
specs/keeper-state-machine/KeeperOutcomesConservation.tla
specs/keeper-state-machine/KeeperReconcileLiveness.tla
specs/keeper-state-machine/KeeperSocialModelMagenticLedger.tla
specs/keeper-state-machine/KeeperWorkPipeline.tla
specs/server-state/ServerState.tla
specs/social-state-cap/SocialStateCap.tla
```

### 4. CFG-level variants still need a stricter follow-up

**Severity**: Medium
**Status**: follow-up

The new coverage gate is spec-level, not cfg-variant-level. It catches a new `.tla` with cfg files that is not harnessed, but it does not yet prove every non-standard cfg variant is executed. Examples worth sweeping next:

- `KeeperCompositeLifecycle-buggy-cascade.cfg`
- `KeeperCompositeLifecycle-buggy-compaction.cfg`
- `KeeperStateMachine-overflow-buggy.cfg`
- `KeeperDecisionPipeline-cap2.cfg`
- `KeeperContextLifecycle-ci.cfg`
- `KeeperWorktreeContainment-*-buggy.cfg`

Recommended follow-up: teach `scripts/tla-check.sh` a generic cfg-discovery mode for selected directories, or add a cfg-level coverage manifest that distinguishes clean, buggy, liveness, and reduced-CI configs.

## Verification Commands

Focused checks for this PR:

```bash
bash scripts/ci/check-tla-harness-coverage.sh
scripts/dune-local.sh build test/test_keeper_composite_observer.exe
cd dashboard && pnpm vitest run src/api/schemas/keeper-composite.test.ts src/components/fsm-hub-types.test.ts --no-file-parallelism --maxWorkers=1
cd dashboard && pnpm typecheck
```

Full formal verification remains CI/nightly scope:

```bash
scripts/tla-check.sh
```
