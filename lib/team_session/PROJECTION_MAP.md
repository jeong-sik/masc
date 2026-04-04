# Projection Map: MASC Session -> OAS Swarm

Field-by-field mapping for the two lossy projections in `team_session_oas_bridge.ml`.

**Key distinction**: data loss vs type loss. Most fields are preserved in
`Collaboration.t.metadata` as JSON, losing compile-time type safety but
retaining the values at runtime.

## planned_worker (24 fields) -> agent_entry (4 fields)

| # | Source Field | Type | Target | Disposition |
|---|-------------|------|--------|-------------|
| 1 | spawn_agent | string | name | Direct |
| 2 | runtime_actor | string option | metadata | worker_specs JSON |
| 3 | spawn_role | string option | role | Via role_of_spawn_role |
| 4 | runtime_binding_ref | string option | metadata | worker_specs JSON |
| 5 | spawn_model | string option | metadata | Compatibility only, not authoritative |
| 6 | execution_scope | execution_scope option | metadata | worker_specs JSON |
| 7 | thinking_enabled | bool option | metadata | worker_specs JSON |
| 8 | thinking_budget | int option | metadata | worker_specs JSON |
| 9 | max_turns | int option | (closure) | Captured in run closure |
| 10 | timeout_seconds | int option | metadata | worker_specs JSON |
| 11 | worker_class | worker_class option | role | Fallback for spawn_role |
| 12 | parent_actor | string option | metadata | worker_specs JSON |
| 13 | capsule_mode | capsule_mode option | metadata | worker_specs JSON |
| 14 | runtime_pool | string option | metadata | worker_specs JSON |
| 15 | lane_id | string option | metadata | worker_specs JSON |
| 16 | controller_level | controller_level option | metadata | worker_specs JSON |
| 17 | control_domain | control_domain option | metadata | worker_specs JSON |
| 18 | supervisor_actor | string option | metadata | worker_specs JSON |
| 19 | task_profile | task_profile option | metadata | worker_specs JSON |
| 20 | risk_level | risk_level option | metadata | worker_specs JSON |
| 21 | artifact_scope | string list | metadata | worker_specs JSON |
| 22 | routing_confidence | float option | metadata | worker_specs JSON |
| 23 | routing_reason | string option | metadata | worker_specs JSON |
| 24 | routing_escalated | bool | metadata | worker_specs JSON |

Summary: 4 fields participate directly in agent_entry construction
(`spawn_agent`, `spawn_role`, `worker_class`, `max_turns`).
`runtime_binding_ref` and `artifact_scope` are preserved in metadata, while the legacy `spawn_model` compatibility shadow is intentionally ignored at the OAS boundary.

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
| (via Collaboration.t) | collaboration | collaboration_of_session |

### Via Collaboration.t

| Session Field | Collaboration.t Field | Notes |
|--------------|----------------------|-------|
| session_id | id | Direct |
| goal | goal | Direct |
| status | phase | session_status_to_phase |
| planned_workers | participants | planned_worker_to_participant |
| started_at | created_at | Direct |
| last_event_at / started_at | updated_at | Fallback chain |
| stop_reason | outcome | Direct (may be None) |

### Preserved in Collaboration.t.metadata

| Key | Session Field |
|-----|--------------|
| room_id | room_id |
| created_by | created_by |
| origin_kind | origin_kind |
| execution_scope | execution_scope |
| orchestration_mode | orchestration_mode |
| control_profile | control_profile |
| scale_profile | scale_profile |
| instruction_profile | instruction_profile |
| fallback_policy | fallback_policy |
| communication_mode | communication_mode |
| alert_channel | alert_channel |
| duration_seconds | duration_seconds |
| checkpoint_interval_sec | checkpoint_interval_sec |
| min_agents | min_agents |
| auto_resume | auto_resume |
| planned_worker_count | List.length planned_workers |
| runtime_policy_ref | runtime_policy_ref |
| model_cascade | model_cascade |
| worker_class_counts | Aggregated from planned_workers |
| runtime_pool_counts | Aggregated from planned_workers |
| lane_counts | Aggregated from planned_workers |
| controller_level_counts | Aggregated from planned_workers |
| control_domain_counts | Aggregated from planned_workers |
| worker_specs | Full per-worker metadata JSON |

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

| Projection | Source | Target (typed) | In metadata (JSON) | Truly dropped |
|-----------|--------|----------------|-------------------|---------------|
| planned_worker -> agent_entry | 24 | 4 | 20 | 0 |
| session -> swarm_config | 47 | 12 | 24 | 16 (metrics/post-exec) |
| session -> Collaboration.t | 47 | 7 direct | 24 | 0 (all preserved) |
