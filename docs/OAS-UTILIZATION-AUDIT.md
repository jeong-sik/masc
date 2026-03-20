# MASC-MCP OAS Utilization Audit

Date: 2026-03-20
OAS Version: v0.77.0
MASC-MCP: main (624d9fcc5)

## OAS Adoption Score: 55/100

| Area | Max | Score | Evidence |
|------|-----|-------|----------|
| Agent.run lifecycle | 20 | 15 | 10+ files: perpetual_oas, oas_worker, worker_oas, keeper_agent_run |
| Types/Provider/Builder | 15 | 12 | 66 files (11.8%) reference Agent_sdk/Oas |
| Context_reducer | 10 | 8 | context_compact_oas.ml: 4 strategies mapped |
| Event_bus | 8 | 5 | oas_events.ml: 14 event types, oas_sse_bridge subscribes |
| Guardrails | 7 | 5 | AllowList/DenyList/AllowAll in 5+ files |
| Memory 3-tier | 10 | 2 | long_term_backend only. Scratchpad/Working unmapped |
| Swarm (lib_swarm) | 15 | 0 | 22 files (5,569 lines) fully independent |
| Advanced modules | 15 | 8 | Collaboration, Sessions, Handoff adopted. 17+ unused |

## Quantitative Metrics

| Metric | Value |
|--------|-------|
| MASC lib/ .ml files | 560 |
| MASC lib/ total lines | 190,889 |
| OAS-referencing files | 66 (11.8%) |
| Agent.run call sites | 14 files |
| Cascade.call residual | 0 (archive 1) |
| Model_spec coupled files | 39 |
| OAS .mli modules (total) | 144 (lib/ 138 + lib_swarm/ 6) |
| OAS modules used by MASC | ~20 |
| OAS modules unused | 52+ |

## Strengths

1. **Cascade.call fully retired** — 0 in active code
2. **Agent.run on critical path** — perpetual_oas, oas_worker, worker_oas, keeper_agent_run
3. **Context_reducer integrated** — 4 compaction strategies mapped via context_compact_oas.ml
4. **Event_bus connected** — 14 event types in oas_events.ml, oas_sse_bridge subscribes
5. **Hook system structural** — perpetual_oas_hooks.ml: 4 lifecycle hooks
6. **Clean adapter layer** — oas_type_adapters.ml (39 lines): Model_spec -> Provider.config
7. **Perpetual architecture is sound** — Not a dual implementation; proper 3-layer separation (types/OAS adapter/MCP dispatcher)

## Critical Gaps

### Gap 1: Swarm subsystem independent — CRITICAL

- lib/swarm/ (11 files, 2,750 lines) + agent_swarm_*.ml (11 files, 2,819 lines) = 22 files, 5,569 lines
- OAS lib_swarm/runner.mli provides 3-mode (Decentralized/Supervisor/Pipeline) + convergence loop
- MASC swarm_eio.ml (617 lines), swarm_goal_loop.ml (347 lines): independent state machines
- agent_swarm_swarm.ml uses Agent.run per-agent but not Runner for orchestration
- MASC swarm has features beyond OAS Runner (pheromone, emergent intelligence, custom fitness)

### Gap 2: verifier_oas.ml Provider bypass — FIXED (this PR)

- Was: direct provider cascade call (lines 160-165)
- Now: Oas_worker.run_named — OAS-only, cascade-aware, error-formatted

### Gap 3: Memory bridge incomplete — MEDIUM

- memory_oas_bridge.ml: long_term_backend only
- Missing: Scratchpad (per-turn), Working (session), Episodic (decay/salience), Procedural (confidence)
- MASC has all source data (memory_stream, context_manager, procedural_memory, institution_eio)
- Only the OAS integration glue is missing

### Gap 4: 52+ OAS modules unused — LOW-MEDIUM

Key unused modules with potential value:
- progressive_tools.mli — 371-tool progressive disclosure
- durable.mli — crash-recovery persistent workflows
- plan.mli — goal decomposition/replanning
- verified_output.mli — phantom-type compile-time output verification
- trajectory.mli — structured Think/Act/Observe/Respond
- cost_tracker.mli — model cost accounting
- otel_tracer.mli — OpenTelemetry tracing

## Migration Priorities

| Priority | Target | Effort | Status |
|----------|--------|--------|--------|
| P1 | verifier_oas.ml -> Oas_worker.run_named | 1 day | DONE (this PR) |
| P2 | Memory 3-tier completion | 3-5 days | Planned |
| P3 | Model_spec gradual retirement | 2-3 weeks | Incremental |
| P4 | Swarm -> OAS lib_swarm bridge | 3-4 weeks | Needs design |
| P5 | Advanced module selective adoption | Ongoing | Optional |

## Corrected Findings (vs initial plan)

1. **Perpetual Loop**: NOT a dual implementation. Proper 3-layer: Perpetual_loop (types) -> Perpetual_oas (OAS adapter) -> Tool_perpetual (MCP dispatcher). No code duplication.
2. **Swarm lines**: 5,569 (not 8,149 as initially estimated)
3. **OAS reference ratio**: 11.8% (66 files, not 62)
4. **Score**: 55/100 (up from 52, corrected for perpetual loop proper architecture)
