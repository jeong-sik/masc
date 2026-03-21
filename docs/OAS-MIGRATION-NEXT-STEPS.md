# MASC → OAS Migration Next Steps

Updated: 2026-03-21
Scope: `masc-mcp` only

## Current Baseline

The migration is no longer blocked on “move major subsystems to OAS”.
The important migrations are already in place:

- keeper turn execution uses OAS runtime paths
- verifier/council/mitosis/dashboard provider runs use OAS execution helpers
- team-session execution goes through OAS Swarm
- OAS Event_bus custom events already flow into dashboard SSE
- context compaction already delegates to OAS `Context_reducer`

The remaining work is about **completeness and consolidation**, not broad adoption theater.

## Priority 1: Finish Team-Session Fidelity

The biggest remaining product gap is not whether team sessions use OAS Swarm.
They do. The gap is that the bridge is still lossy.

### What remains

- preserve more `planned_worker` metadata in swarm entries
- add real per-agent telemetry instead of `get_telemetry = None`
- replace `convergence = None` with an explicit swarm convergence policy
- replace `max_concurrent_agents = None` with a deliberate concurrency setting
- decide whether session-level budget should remain `no_budget` or derive from MASC session settings

### Success criteria

- background swarm workers keep working after restart and can use real supported tools
- operator/dashboard can inspect more than just final swarm success/failure
- team-session bridge no longer describes itself as a heavily lossy projection

## Priority 2: Finish Runtime Consolidation

This pass reduced duplication, but one important path still remains outside the shared template.

### Done in this pass

- dashboard provider single-run now routes through `Oas_worker.run_model`
- initial local worker run now routes through `Worker_oas.run_worker_via_oas`

### Still remaining

- local worker resume/continue path still directly resumes an OAS agent and manually handles run/checkpoint/output lifecycle

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

- Gardener as an active migration target
- “Event_bus bridge planned”
- “team_session still pending OAS migration”

## Explicit Non-Priorities

These are not the next best use of time unless a concrete product need appears:

- broad “unused OAS modules” adoption
- big-bang `Model_spec` retirement
- upstream OAS issue work as part of this `masc-mcp` pass

## Recommended Order

1. team-session bridge fidelity and telemetry
2. worker resume-path runtime consolidation
3. follow-up memory/documentation cleanup
