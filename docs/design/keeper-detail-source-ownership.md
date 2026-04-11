# Keeper Detail Source Ownership

**Status**: Draft  
**Date**: 2026-04-02  
**Scope**: Keeper detail modal and adjacent panels in the dashboard  
**One sentence**: Separate authored keeper config, derived effective config, and live runtime observation so the detail modal does not map fields across the wrong source class.

## Why This Exists

Keeper detail currently reads from more than one projection:

- `/api/v1/dashboard/shell` keeper summary
- `/api/v1/dashboard/mission` keeper briefs
- `/api/v1/keepers/:name/config`
- keeper-scoped detail APIs such as chat history and trajectory

Those projections do not carry the same truth class.

- Some values are authored and should be stable until edited.
- Some values are derived from authored config and registry state.
- Some values are live runtime snapshots and can change every refresh.
- Some values are observed audit signals and may be empty, stale, or missing even when config is valid.

The detail modal must not treat those as interchangeable.

## Source Classes

| Source class | Meaning | Typical change cadence | Example fields |
| --- | --- | --- | --- |
| Authored config | Human-authored keeper intent and policy | On explicit edit only | `goal`, `tool_preset`, `tool_denylist` |
| Derived effective config | Deterministic resolution of authored config | On config edit or registry/tool-policy logic change | `resolved_allowlist`, `active_model`, `effective_allowed_paths` |
| Runtime summary | Live keeper/process state | Every refresh / heartbeat / turn | `status`, `context_ratio`, `last_turn_ago_s` |
| Observed tool audit | What the keeper actually used recently | Event-driven, may be absent | `latest_tool_names`, `tool_audit_source`, `tool_audit_at` |
| Detailed event/history | High-cardinality per-keeper drill-down data | Event-driven | trajectory, chat history |

## Ownership Table

| Field group | Example fields | Truth class | Authoritative HTTP surface | Backend producer | Durable / raw source | Primary dashboard consumer | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Keeper identity and header runtime | `name`, `emoji`, `koreanName`, `status`, `pipeline_stage`, `agent_name`, `trace_id`, `generation` | Runtime summary | `/api/v1/dashboard/shell` | `lib/dashboard/dashboard_http_keeper.ml` via `keepers_dashboard_json` | live keeper meta, agent status, registry status | `dashboard/src/components/keeper-detail.ts` | Header and KPI shell should read from the keeper summary projection. |
| Runtime freshness and continuity | `last_heartbeat`, `last_turn_ago_s`, `last_handoff_ago_s`, `last_compaction_ago_s`, `last_proactive_ago_s`, `handoff_count_total`, `compaction_count` | Runtime summary | `/api/v1/dashboard/shell` | `lib/dashboard/dashboard_http_keeper.ml` | live keeper meta + metrics + trace history | `dashboard/src/components/keeper-detail.ts`, `dashboard/src/components/keeper-detail-panels.ts` | These are volatile and must not be cached as config. |
| Runtime context | `context_ratio`, `context_tokens`, `context_max`, `context_source`, `context.*` | Runtime summary | `/api/v1/dashboard/shell` | `lib/dashboard/dashboard_http_keeper.ml` | latest metrics line or checkpoint-derived context | `dashboard/src/components/keeper-detail.ts`, `dashboard/src/components/keeper-detail-runtime.ts` | `context_source` is runtime provenance, not authored config provenance. |
| Runtime quality window | `metrics_window.*`, `metrics_series`, `metrics_24h_summary`, `recent_tool_names` | Runtime summary | `/api/v1/dashboard/shell` | `lib/dashboard/dashboard_http_keeper_detail.ml` + `lib/dashboard/dashboard_http_keeper.ml` | metrics jsonl / dated jsonl | `dashboard/src/components/keeper-detail-runtime.ts`, `dashboard/src/components/keeper-detail-panels.ts` | Window aggregates are observational, not policy. |
| Runtime conversation summary | `recent_input_preview`, `recent_output_preview`, `conversation_tail_count`, `k2k_count`, `k2k_mentions` | Runtime summary | `/api/v1/dashboard/shell` | `lib/dashboard/dashboard_http_keeper.ml` | history jsonl | `dashboard/src/components/keeper-detail.ts`, `dashboard/src/components/keeper-detail-runtime.ts` | Preview emptiness does not imply keeper inactivity. |
| Supervisor/process health | `registry_state`, `supervisor_diagnostics.*`, `keepalive_running`, `agent.*` | Runtime summary | `/api/v1/dashboard/shell` | `lib/dashboard/dashboard_http_keeper.ml` | registry state + crash persistence + agent status | `dashboard/src/components/keeper-detail.ts` | These are operational snapshots and must stay out of authored config. |
| Authored execution/coordination | `execution_scope`, `allowed_paths`, `room_scope` (`current` only compatibility), `mention_targets` | Authored config | `/api/v1/keepers/:name/config` | `lib/dashboard/dashboard_http_keeper.ml` via `keeper_config_json` | keeper live meta | `dashboard/src/components/keeper-config-panel.ts` | Stable until edited. |
| Derived effective execution | `execution.models`, `execution.active_model`, `effective_allowed_paths` | Derived effective config | `/api/v1/keepers/:name/config` | `lib/dashboard/dashboard_http_keeper.ml` via `keeper_config_json` | resolved cascade config + path policy | `dashboard/src/components/keeper-config-panel.ts` | Derived from authored config, but should still be sourced from config API. |
| Authored tool policy | `tools.tool_policy_mode`, `tools.tool_preset`, `tools.tool_also_allow`, `tools.tool_custom_allowlist`, `tools.tool_denylist` | Authored config | `/api/v1/keepers/:name/config` | `lib/dashboard/dashboard_http_keeper.ml` via `keeper_config_json` | `meta.tool_access`, `meta.tool_denylist` | `dashboard/src/components/keeper-config-panel.ts`, `dashboard/src/components/keeper-detail-runtime.ts` | This is the SSOT for editor seed values. |
| Derived effective tool policy | `tools.resolved_allowlist`, `tools.active_masc_tool_count`, `tools.active_keeper_tool_count`, `tools.total_active` | Derived effective config | `/api/v1/keepers/:name/config` | `lib/dashboard/dashboard_http_keeper.ml` via `keeper_config_json` | `Keeper_exec_tools.keeper_allowed_tool_names` over meta | `dashboard/src/components/keeper-config-panel.ts`, `dashboard/src/components/keeper-detail-runtime.ts` | Derived allowlist is not the same thing as authored preset/custom lists. |
| Observed tool audit | `latest_tool_names`, `latest_tool_call_count`, `tool_audit_source`, `tool_audit_at` | Observed tool audit | Prefer `/api/v1/dashboard/mission`; fallback `/api/v1/dashboard/shell` when parity exists | `lib/dashboard/dashboard_mission_assembly.ml` via `keeper_tool_audit_json_fields`; fallback `lib/keeper/keeper_exec_status_metrics.ml` | heartbeat task/result, decision log, metrics log | `dashboard/src/components/keeper-detail-runtime.ts` | Audit data answers “what recently happened”, not “what is allowed.” |
| Trajectory detail | trajectory entries and gate/result rows | Detailed event/history | `/api/v1/keepers/:name/trajectory` | dashboard keeper trajectory API | trajectory / tool-call log | `dashboard/src/components/keeper-trajectory-timeline.ts` | High-cardinality detail view only. |
| Direct chat history | chat thread history | Detailed event/history | `/api/v1/keepers/:name/chat/history` | dashboard keeper chat history route | history jsonl | `dashboard/src/components/keeper-chat-panel.ts` | Keep separate from summary previews. |

## Non-Negotiable Rules

1. `tool_preset`, `tool_also_allow`, `tool_custom_allowlist`, and `tool_denylist` must be seeded from `/api/v1/keepers/:name/config`.
2. `allowed_tool_names` / `resolved_allowlist` must be treated as derived effective policy, not as authored policy.
3. `latest_tool_names`, `latest_tool_call_count`, `tool_audit_source`, and `tool_audit_at` must be treated as observed runtime evidence only.
4. `mission keeper brief` is an operations projection. It may override observed audit freshness, but it must not override authored tool policy.
5. If authored config has not loaded yet, the UI should show `loading` for static policy rather than inventing a default such as `preset/full`.
6. Empty observed audit data must not be interpreted as “no tools allowed”.
7. Empty authored policy data must not be backfilled from mission or runtime audit projections.

## Current Dashboard Touchpoints

| Dashboard file | Role | Expected source class |
| --- | --- | --- |
| `dashboard/src/components/keeper-detail.ts` | modal shell, header, top-level sections | Runtime summary |
| `dashboard/src/components/keeper-detail-runtime.ts` | neighborhood, tool audit, allowlist editor seed | Mixed: authored tool policy + observed audit + runtime summary |
| `dashboard/src/components/keeper-config-panel.ts` | structured config view and editor | Authored config + derived effective config |
| `dashboard/src/keeper-store-normalize.ts` | keeper summary normalization | Runtime summary only |
| `dashboard/src/mission-normalizers-entities.ts` | mission keeper brief normalization | Observed audit / mission projection |

## Backend Touchpoints

| Backend file | Role | Exposes |
| --- | --- | --- |
| `lib/dashboard/dashboard_http_keeper.ml` | keeper shell summary + keeper config JSON | Runtime summary, config projection |
| `lib/dashboard/dashboard_http_keeper_detail.ml` | metrics window aggregation | Runtime summary aggregates |
| `lib/dashboard/dashboard_mission_assembly.ml` | mission keeper brief assembly | Observed tool audit and mission projection |
| `lib/keeper/keeper_exec_status_metrics.ml` | latest tool audit snapshots from files | Observed tool audit fallback |
| `lib/keeper/keeper_tool_policy.ml` | effective allowlist resolution | Derived effective tool policy |
| `lib/server/server_routes_http_routes_dashboard.ml` | HTTP routing for shell/config/chat history | surface routing |

## Known Anti-Patterns To Avoid

- Seeding the tool editor from `keeper.tool_preset ?? 'full'` when config has not loaded.
- Using `missionBrief.allowed_tool_names` as if it were authored policy.
- Using `latest_tool_names` as if it were the allowlist.
- Inferring `tool_policy_mode` from the presence or absence of recent audit data.
- Treating `context_source` as keeper config provenance.

## Recommended Cleanup Sequence

1. Introduce explicit source-resolution helpers in the detail modal for:
   - authored tool policy
   - derived effective tool policy
   - observed tool audit
2. Preload `/api/v1/keepers/:name/config` when the detail modal opens.
3. Render `loading` instead of fallback defaults for static policy fields until config resolves.
4. Keep `dashboard/src/keeper-store-normalize.ts` limited to shell/runtime summary fields.
5. Add unit tests that lock the precedence:
   - config beats shell for authored policy
   - mission beats shell for observed audit freshness
   - loading state does not invent defaults
