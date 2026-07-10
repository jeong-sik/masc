# Lib Dependency Decomposition Report

- Source: `reports/lib-dependency-graph.json`
- Baseline: none

## Summary

| Metric | Current | Delta |
| --- | --- | --- |
| total_modules | 1056 | - |
| total_edges | 4438 | - |
| avg_out_degree | 4.2 | - |
| scc_count | 1 | - |
| largest_scc_size | 224 | - |

## Workspace Dependents

| Module | Dependents | Delta |
| --- | --- | --- |
| Workspace | 193 | - |

## Top Hub Modules

| Rank | Module | Dependents |
| --- | --- | --- |
| 1 | Otel_metric_store | 230 |
| 2 | Keeper_types | 224 |
| 3 | Workspace | 193 |
| 4 | Keeper_metrics | 151 |
| 5 | Keeper_registry | 81 |
| 6 | Keeper_id | 66 |
| 7 | Keeper_state_machine | 59 |
| 8 | Mcp_server | 51 |
| 9 | Keeper_runtime_profile | 48 |
| 10 | Tool_dispatch | 47 |

## Heaviest Importers

| Rank | Module | Dependencies |
| --- | --- | --- |
| 1 | Server_bootstrap_loops | 76 |
| 2 | Server_runtime_bootstrap | 58 |
| 3 | Keeper_agent_run | 51 |
| 4 | Keeper_run_tools | 48 |
| 5 | Keeper_unified_turn | 44 |
| 6 | Mcp_server_eio_execute | 43 |
| 7 | Keeper_supervisor | 40 |
| 8 | Server_dashboard_http_keeper_api | 39 |
| 9 | Dashboard_http_keeper | 38 |
| 10 | Keeper_turn | 36 |

## Batch 2 Extraction Candidates

| Prefix | Modules | Coupling | External Deps | Internal Edges |
| --- | --- | --- | --- | --- |
| model_inference | 6 | 0.889 | 1 | 8 |
| otel_metric_store_builtin | 7 | 0.833 | 2 | 10 |
| server_mcp | 13 | 0.690 | 9 | 20 |
| keeper_state | 4 | 0.667 | 1 | 2 |
| tool_board | 10 | 0.650 | 7 | 13 |
| runtime_transport | 13 | 0.600 | 8 | 12 |
| tool_shard | 18 | 0.583 | 5 | 7 |
| runtime_config | 9 | 0.500 | 11 | 11 |
| runtime_catalog | 8 | 0.500 | 11 | 11 |

## Regeneration

```sh
python3 scripts/analyze_lib_deps.py --json
python3 scripts/lib_dep_report.py --graph reports/lib-dependency-graph.json --output reports/lib-dependency-summary.md
python3 scripts/lib_dep_report.py --graph reports/lib-dependency-graph.json --baseline reports/lib-dependency-graph.baseline.json --format json
```
