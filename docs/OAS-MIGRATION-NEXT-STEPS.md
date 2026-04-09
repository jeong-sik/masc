# MASC → OAS Migration Next Steps

Updated: 2026-03-27
Scope: `masc-mcp` only

## Current Baseline

The migration is no longer blocked on “move major subsystems to OAS”.
The important migrations are already in place:

- keeper turn execution uses OAS runtime paths
- verifier/governance/dashboard provider runs use OAS execution helpers
- team-session execution goes through OAS Swarm
- OAS Event_bus custom events already flow into dashboard SSE
- context compaction already delegates to OAS `Context_reducer`

The remaining work is about **completeness and consolidation**, not broad adoption theater.

## Done In This Pass

- team-session state now persists a delivery contract and latest evaluator verdict
- session status/report/prove surfaces expose the contract/verdict directly
- worker verification consumes the persisted contract and records contract-aware verdicts
- anti-rationalization now defaults to `cross_verifier`, and `masc_transition` accepts `completion_contract` plus `evaluator_cascade`

## Priority 1: Finish Team-Session Fidelity

The biggest remaining product gap is not whether team sessions use OAS Swarm.
They do. The gap is that the bridge is still lossy.

### What remains

- preserve more `planned_worker` metadata in swarm entries
- preserve richer telemetry semantics beyond the current `trace_ref`/usage/turn_count baseline when the swarm runner needs more operator-facing detail
- decide whether the current single-pass success-ratio convergence policy should become a richer multi-iteration strategy driven by delivery verdicts
- decide whether the current event-level telemetry detail is enough, or whether dashboard consumers need first-class swarm telemetry views
- replace the current room-init `resource_check` with a broader runtime-health probe, then upstream the generic callback shape to OAS if a concrete failure mode appears
- decide whether the current single-pass success-ratio convergence policy should become a richer multi-iteration strategy
- broaden the runtime-health probe beyond room/session readiness only if a concrete failure mode appears
 - decide whether session-level budget needs token/cost enforcement beyond the current `duration_seconds` wall-clock budget

### Success criteria

- background swarm workers keep working after restart and can use real supported tools
- operator/dashboard can inspect more than just final swarm success/failure
- team-session bridge가 현재 loss budget과 omitted surfaces를 명시적으로 문서화한다

## Priority 2: Finish Runtime Consolidation

This pass reduced duplication, but one important path still remains outside the shared template.

### Done in this pass

- dashboard provider single-run now routes through `Oas_worker.run_model`
- initial local worker run now routes through `Worker_oas.run_worker_via_oas`
- local worker resume/continue now routes through `Worker_oas.resume_worker_via_oas`
- team-session bridge는 `worker_specs`와 prompt context만 유지하고 `collaboration_context`는 제거 개념으로 둔다
- swarm lifecycle events now include per-agent telemetry detail
- `resource_check` now validates persisted running-session state, not just room initialization

### Still remaining

- no known local worker resume-path config duplication remains in the current OAS path

### Success criteria

- initial run and resume share the same execution contract for:
  - guardrails
  - trace capture
  - checkpoint persistence
  - completion logging
  - cleanup on error

## Priority 3: Keep the Memory Bridge Honest and Complete

The old “5-tier” claim was misleading because episodic support was a no-op.
That is now fixed for institution episodes.

### Done in this pass

- episodic seed/flush are real
- `episode_limit` is real
- duplicate write-back is prevented by persisted-ID filtering
- the underlying `Institution_eio.load_recent_episodes_jsonl` limit bug is fixed

### Still remaining

- broader memory unification is still not done
- Working/Scratchpad remain intentionally runtime-only
- other historical memory sources are not automatically projected into OAS memory

### Success criteria

- no OAS memory helper may claim support for a tier that is still stubbed
- all supported tiers have tests that prove seed/flush/limit behavior

## Priority 4: Stop Reintroducing Documentation Drift

The following are now stale and should not reappear in migration docs:

- legacy ecosystem-loop migration targets
- “Event_bus bridge planned”
- “team_session still pending OAS migration”

## Upstream OAS Delegation Targets

These are worth upstreaming because they are generic runtime/harness primitives rather than MASC semantics:

- `Harness.case` / `Harness.result` / `Harness.repair_directive`
- richer swarm entry metadata for telemetry and routing provenance
- structured health-probe callback type

## Explicit Non-Priorities

These are not the next best use of time unless a concrete product need appears:

- broad “unused OAS modules” adoption
- big-bang `Model_spec` retirement
- moving MASC room/task/proof semantics into OAS

## Recommended Order

1. team-session bridge fidelity and telemetry
2. worker resume-path config consolidation
3. follow-up memory/documentation cleanup
