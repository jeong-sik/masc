# Projection Map: MASC Session -> OAS Swarm

Current field map for `team_session_oas_bridge.ml`.

**Current truth**: the bridge projects into OAS `swarm_config` / `agent_entry`
and keeps `collaboration_context = None`. Session/worker semantics survive
mainly through typed swarm fields plus `worker_specs` metadata JSON.

## planned_worker (23 fields) -> agent_entry (4 fields)

| # | Source Field | Type | Target | Disposition |
|---|-------------|------|--------|-------------|
| 1 | spawn_agent | string | name | Direct |
| 2 | spawn_role | string option | role | Via role_of_spawn_role |
| 3 | worker_class | worker_class option | role | Fallback for spawn_role |
| 4 | max_turns | int option | (closure) | Captured in run closure |
| 5 | spawn_model | string option | (closure) | Used in cascade_of_worker |
| 6 | runtime_actor | string option | metadata | worker_specs JSON |
| 7 | execution_scope | execution_scope option | metadata | worker_specs JSON |
| 8 | thinking_enabled | bool option | metadata | worker_specs JSON |
| 9 | thinking_budget | int option | metadata | worker_specs JSON |
| 10 | timeout_seconds | int option | metadata | worker_specs JSON |
| 11 | parent_actor | string option | metadata | worker_specs JSON |
| 12 | capsule_mode | capsule_mode option | metadata | worker_specs JSON |
| 13 | runtime_pool | string option | metadata | worker_specs JSON |
| 14 | lane_id | string option | metadata | worker_specs JSON |
| 15 | controller_level | controller_level option | metadata | worker_specs JSON |
| 16 | control_domain | control_domain option | metadata | worker_specs JSON |
| 17 | supervisor_actor | string option | metadata | worker_specs JSON |
| 18 | model_tier | model_tier option | metadata | worker_specs JSON |
| 19 | task_profile | task_profile option | metadata | worker_specs JSON |
| 20 | risk_level | risk_level option | metadata | worker_specs JSON |
| 21 | routing_confidence | float option | metadata | worker_specs JSON |
| 22 | routing_reason | string option | metadata | worker_specs JSON |
| 23 | routing_escalated | bool | metadata | worker_specs JSON |

Summary: 5 fields participate directly in agent_entry construction
(`spawn_agent`, `spawn_role`, `worker_class`, `max_turns`, `spawn_model`);
the remaining 18 are metadata-only in `worker_specs`, and 0 are truly dropped.

## session (47 fields) -> swarm_config (12 fields)

### Direct to swarm_config

| Session Field | swarm_config Field | Conversion |
|--------------|-------------------|------------|
| goal | prompt | Direct |
| orchestration_mode | mode | mode_of_orchestration |
| duration_seconds | timeout_sec | float_of_int, None if 0 |
| duration_seconds | budget | budget_of_session_timeout |
| planned_workers | entries | planned_worker_to_entry per worker |
| planned_workers (count) | max_parallel | max 1 (List.length) |
| planned_workers (count) | max_concurrent_agents | Some (max 1 (List.length)) |
| (computed) | convergence | make_convergence_metric |
| (hardcoded) | max_agent_retries | 1 |
| (hardcoded) | enable_streaming | false |
| (runtime) | resource_check | Health check closure |
| (constant) | collaboration_context | Always `None` in current bridge |

### Preserved outside typed swarm_config fields

The bridge no longer builds a `Collaboration.t` payload.

The following session semantics are still carried through other surfaces:

| Key | Session Field |
|-----|--------------|
| worker_class_counts | Aggregated from planned_workers |
| runtime_pool_counts | Aggregated from planned_workers |
| lane_counts | Aggregated from planned_workers |
| controller_level_counts | Aggregated from planned_workers |
| control_domain_counts | Aggregated from planned_workers |
| model_tier_counts | Aggregated from planned_workers |
| worker_specs | Full per-worker metadata JSON |

Additional session/runtime semantics survive via:

- `prompt`, `timeout_sec`, `budget`, `convergence`, `resource_check`
- per-agent telemetry exported by the swarm runner / proof surfaces
- persisted MASC session state updated by `apply_swarm_result`

### Dropped (no OAS equivalent)

| Session Field | Reason |
|--------------|--------|
| operation_id | MASC-internal operation tracking |
| report_formats | Post-swarm report control |
| broadcast_count | Runtime metric |
| portal_count | Runtime metric |
| cascade_attempted/success/failed | Runtime metric |
| fallback_task_created | Runtime metric |
| min_agents_violation_streak | Runtime metric |
| policy_violations | Runtime metric |
| baseline_done_counts | Outcome metric |
| final_done_delta_total | Outcome metric |
| final_done_delta_by_agent | Outcome metric |
| planned_end_at | Implicit in timeout_sec |
| generated_report | Post-execution flag |
| delivery_contract | Post-execution |
| latest_delivery_verdict | Post-execution |
| artifacts_dir | MASC filesystem path |

Note: stopped_at, last_checkpoint_at, last_event_at, last_turn_at,
stop_reason, turn_count, created_at_iso, updated_at_iso are updated
by apply_swarm_result after swarm execution completes.

## Compression Summary

| Projection | Source | Target (typed) | In metadata / side surfaces | Truly dropped |
|-----------|--------|----------------|-----------------------------|---------------|
| planned_worker -> agent_entry | 24 | 4 | `worker_specs` JSON | 0 |
| session -> swarm_config | 47 | 12 | worker metadata + runtime/proof/session surfaces | 16 (metrics/post-exec) |
| collaboration_context | 1 | 0 | none | 1 (`None` in current bridge) |
