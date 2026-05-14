# Lib Dependency Decomposition Report

- Source: `reports/lib-dependency-graph.json`
- Baseline: none

## Summary

| Metric | Current | Delta |
| --- | --- | --- |
| total_modules | 766 | - |
| total_edges | 3566 | - |
| avg_out_degree | 4.66 | - |
| scc_count | 1 | - |
| largest_scc_size | 186 | - |

## Room/Coordination Dependents

| Module | Dependents | Delta |
| --- | --- | --- |
| Coord | 149 | - |

## Top Hub Modules

| Rank | Module | Dependents |
| --- | --- | --- |
| 1 | Prometheus | 165 |
| 2 | Coord | 149 |
| 3 | Keeper_types | 142 |
| 4 | Keeper_metrics | 91 |
| 5 | Tool_result | 56 |
| 6 | Keeper_registry | 51 |
| 7 | Keeper_id | 50 |
| 8 | Keeper_cascade_profile | 49 |
| 9 | Tool_dispatch | 47 |
| 10 | Tool_args | 42 |

## Heaviest Importers

| Rank | Module | Dependencies |
| --- | --- | --- |
| 1 | Server_bootstrap_loops | 72 |
| 2 | Server_runtime_bootstrap | 59 |
| 3 | Keeper_unified_turn | 56 |
| 4 | Dashboard_http_keeper | 49 |
| 5 | Keeper_run_tools | 47 |
| 6 | Mcp_server_eio_execute | 45 |
| 7 | Server_dashboard_http_keeper_api | 43 |
| 8 | Keeper_agent_run | 42 |
| 9 | Server_routes_http_routes_dashboard | 42 |
| 10 | Keeper_heartbeat_loop | 36 |

## Batch 2 Extraction Candidates

| Prefix | Modules | Coupling | External Deps | Internal Edges |
| --- | --- | --- | --- | --- |
| tool_call | 7 | 0.818 | 2 | 9 |
| server_mcp | 10 | 0.682 | 7 | 15 |
| meta_cognition | 7 | 0.583 | 5 | 7 |
| keeper_admission | 5 | 0.500 | 6 | 6 |
| masc_grpc | 5 | 0.429 | 4 | 3 |
| keeper_social | 7 | 0.385 | 8 | 5 |
| tool_autoresearch | 6 | 0.333 | 12 | 6 |
| dashboard_keeper | 5 | 0.333 | 4 | 2 |
| keeper_sandbox | 7 | 0.312 | 11 | 5 |
| docker_client | 3 | 0.286 | 5 | 2 |

## Regeneration

```sh
python3 scripts/analyze_lib_deps.py --json
python3 scripts/lib_dep_report.py --graph reports/lib-dependency-graph.json --output reports/lib-dependency-summary.md
python3 scripts/lib_dep_report.py --graph reports/lib-dependency-graph.json --baseline reports/lib-dependency-graph.baseline.json --format json
```
