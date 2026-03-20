# OAS Migration Audit: MASC Model_client → OAS Api

Date: 2026-03-16
Status: Audit complete, migration pending (Track A, separate session)

## Summary

36 MODEL call sites identified across MASC codebase.
- 7 direct `Model_client.run_prompt_cascade` calls
- 19 `Lodge_cascade.call` calls (wraps run_prompt_cascade)
- 10 `Model_client.complete` calls (low-level)

## Classification

### Directly Replaceable (8 sites)

Simple prompt→response, compatible with OAS `Api.create_message_cascade`.

| File | Line | cascade/function | Temp | Notes |
|------|------|-----------------|------|-------|
| dashboard_governance_judge.ml | 291 | run_prompt_cascade | 0.2 | Single prompt, JSON response |
| dashboard_operator_judge.ml | 296 | run_prompt_cascade | 0.2 | Same pattern as governance |
| context_router.ml | 197 | Lodge_cascade "context_router" | 0.1 | Intent classification |
| context_router.ml | 211 | Lodge_cascade "context_router" | 0.1 | Hybrid fallback |
| gardener.ml | 973 | run_prompt_cascade | 0.3 | Spawn evaluation |
| keeper_execution.ml | 1661 | run_prompt_cascade | 0.3 | Keeper decision |
| keeper_autonomy.ml | 248 | Model_client.complete | varies | Autonomous decision |
| capability_match.ml | 257 | Lodge_cascade "capability_match" | default | Agent matching |

### Adapter Needed (10 sites)

MASC-specific parameters (accept predicate, cascade_name, custom timeout).

| File | Line | Barrier | Migration Path |
|------|------|---------|---------------|
| sentinel.ml | 64 | JSON accept validator + dynamic cascade | Bridge: accept → post-parse validation |
| lodge_heartbeat.ml | 522 | context_rewrite, 60s timeout | Bridge: timeout config |
| lodge_heartbeat.ml | 1043 | trait gen | Standard conversion |
| lodge_heartbeat.ml | 1775 | comment gen, system prompt | Standard conversion |
| lodge_heartbeat.ml | 2054 | heartbeat_action, accept predicate | Bridge: accept → validator |
| spawn_eio.ml | 315 | High temp 0.7, user-provided timeout | Bridge: param passthrough |
| lodge_topic.ml | 281 | Dynamic cascade | Standard conversion |
| auto_responder.ml | 158 | Dynamic cascade | Standard conversion |
| lodge_tom.ml | 184 | tom cascade | Standard conversion |
| lodge_broadcast.ml | 119 | agent_match, temp 0.1 | Standard conversion |

### Retain in MASC (8 sites)

Deep integration, no OAS equivalent, or requires redesign.

| File | Line | Reason |
|------|------|--------|
| perpetual_loop.ml | 494 | Deep cascade + handoff logic |
| autoresearch.ml | 807 | Code generation + validation pipeline |
| keeper_turn.ml | 1765 | Conditional cascade with keeper state |
| keeper_execution.ml | 717,1067,2273,2441 | Multi-phase cascade, tightly coupled |
| verifier.ml | 157 | Low-cost verification, different model class |
| trpg_harness.ml | 118,213 | Game logic, separate domain |

## Key Differences: Model_client vs OAS Api

| Aspect | Model_client | OAS Api |
|--------|-----------|---------|
| Input | prompt:string + system:string | messages list |
| Cascade | model_spec list (ordered) | Provider.cascade (primary + fallbacks) |
| Validator | accept:(response → bool) | None built-in |
| HTTP | curl subprocess | Native Eio + Cohttp |
| Return | completion_response | api_response |

## Migration Roadmap

1. **Phase 1**: Lodge internal (heartbeat, broadcast, topic) — 10 sites
2. **Phase 2**: Dashboard judges + gardener — 4 sites
3. **Phase 3**: Sentinel + context_router — 3 sites
4. **Phase 4**: Keeper (heaviest, last) — 6 sites
5. **Retain**: perpetual_loop, autoresearch, verifier, trpg — 8 sites

Bridge module: `Oas_worker.ml` — adapts MASC cascade_name → OAS Provider.cascade,
wraps accept predicate as post-parse validation.
