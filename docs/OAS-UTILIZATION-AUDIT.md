# MASC-MCP OAS Utilization Audit

Date: 2026-03-21
Snapshot: `fix/oas-improvements` on top of `main`

## Current Read

OAS adoption in `masc-mcp` is now structurally real, but still incomplete.
The main remaining problems are no longer “missing migration” at large. They are:

1. incomplete bridge fidelity,
2. a few remaining duplicated runtime paths,
3. stale docs that still describe already-removed or already-migrated systems.

## Status by Area

| Area | Status | Evidence |
|------|--------|----------|
| Single-agent runtime | Strong | `oas_worker`, keeper turn path, verifier, council, mitosis, router/judge flows use `Agent.run` through OAS wrappers |
| Context reduction | Real | `context_compact_oas.ml` delegates directly to OAS `Context_reducer` |
| Event bus / SSE | Real | `oas_events.ml` publishes `masc:*` events and `oas_sse_bridge.ml` relays them to SSE |
| Memory bridge | Partial but real | `memory_oas_bridge.ml` now seeds long-term, procedural, and episodic memory; Working/Scratchpad remain runtime-only |
| Team session swarm | Partial but real | `team_session_swarm_runner.ml` runs through OAS Swarm and now receives a real supported-tool dispatch bundle |
| Runtime dedupe | Improving | dashboard single-run and initial local worker run now reuse shared OAS execution helpers |

## What Changed In This Pass

- `memory_oas_bridge` is no longer lying about episodic support.
  - `seed_episodes` now loads recent institution episodes from `institution_episodes.jsonl`
  - `flush_episodes` now writes new OAS episodes back without duplicating already-persisted IDs
  - `create_memory_full` now honors `episode_limit`
- `team_session` no longer launches OAS Swarm with `masc_tools=[]` and `no dispatch`.
  - start/recovery paths now pass a real supported local-worker tool subset
  - bridge dispatch auto-injects worker identity fields where needed
  - heartbeat/tool dispatch can now work in background swarm workers
- runtime duplication was reduced.
  - dashboard provider single-run now uses `Oas_worker.run_model`
  - initial local worker execution now uses `Worker_oas.run_worker_via_oas`
- this work also exposed and fixed a real pre-existing bug:
  - `Institution_eio.load_recent_episodes_jsonl` ignored `limit` when the log was larger than the requested window

## Remaining Gaps

### 1. Team-session bridge is still lossy

The bridge still throws away part of MASC session semantics:

- `planned_worker` metadata is only partially projected into swarm entries
- `get_telemetry` remains `None`
- `convergence` and `resource_check` are still unset
- `budget` is still `no_budget`

This means the runner is now tool-capable, but not yet fidelity-complete.

### 2. Resume path still has its own direct OAS run logic

Direct OAS build/run sites now remain primarily in:

- `oas_worker.ml`
- `worker_oas.ml`
- `local/worker_container_runners.ml` resume/continue path

That is a much smaller surface than before, but the resume path still needs the same consolidation treatment as the initial run path.

### 3. Memory bridge scope is now honest, but not universal

The episodic source of truth is `Institution_eio` JSONL.
That is enough for current keeper/council/mitosis usage, but it does not mean every historical MASC memory source has been unified into OAS memory.

### 4. Some older docs are still stale by implication

The worst offenders were fixed in this pass, but any document still prioritizing:

- Gardener migration
- “Event_bus bridge planned”
- “team_session is still pre-OAS”

should be treated as outdated until refreshed.

## Recommended Priorities

1. Finish team-session bridge fidelity: telemetry, convergence/resource settings, and less-lossy worker/session projection.
2. Collapse the local worker resume path onto the same shared OAS execution template used by initial runs.
3. Keep docs synced to code after each OAS migration step; the documentation drift is currently more dangerous than the remaining missing code.
