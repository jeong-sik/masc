# Lib Dependency Decomposition Report

- Source: `reports/lib-dependency-graph.json`
- Baseline: none

## Summary

| Metric | Current | Delta |
| --- | --- | --- |
| total_modules | 613 | - |
| total_edges | 2508 | - |
| avg_out_degree | 4.09 | - |
| scc_count | 1 | - |
| largest_scc_size | 92 | - |

## Room/Coordination Dependents

| Module | Dependents | Delta |
| --- | --- | --- |
| Coord | 125 | - |

## Top Hub Modules

| Rank | Module | Dependents |
| --- | --- | --- |
| 1 | Coord | 125 |
| 2 | Keeper_types | 98 |
| 3 | Oas | 92 |
| 4 | Keeper | 60 |
| 5 | Tool_dispatch | 45 |
| 6 | Mcp_server | 35 |
| 7 | Prometheus | 33 |
| 8 | Tool_args | 31 |
| 9 | Sse | 30 |
| 10 | Keeper_registry | 29 |

## Heaviest Importers

| Rank | Module | Dependencies |
| --- | --- | --- |
| 1 | Server_bootstrap_loops | 61 |
| 2 | Keeper_agent_run | 60 |
| 3 | Server_runtime_bootstrap | 46 |
| 4 | Dashboard_http_keeper | 45 |
| 5 | Server_dashboard_http_keeper_api | 39 |
| 6 | Keeper_keepalive | 37 |
| 7 | Keeper_unified_turn | 36 |
| 8 | Mcp_server_eio_execute | 35 |
| 9 | Keeper_turn | 32 |
| 10 | Server_routes_http_routes_dashboard | 31 |

## Batch 2 Extraction Candidates

| Prefix | Modules | Coupling | External Deps | Internal Edges |
| --- | --- | --- | --- | --- |
| tool_call | 7 | 0.900 | 1 | 9 |
| server_mcp | 10 | 0.789 | 4 | 15 |
| meta_cognition | 7 | 0.583 | 5 | 7 |
| keeper_social | 7 | 0.500 | 3 | 3 |
| masc_grpc | 5 | 0.429 | 4 | 3 |
| tool_autoresearch | 6 | 0.353 | 11 | 6 |
| keeper_exec | 14 | 0.250 | 57 | 19 |
| tool_local | 7 | 0.250 | 12 | 4 |
| operator_digest | 4 | 0.250 | 6 | 2 |
| oas_worker | 7 | 0.242 | 25 | 8 |

## Regeneration

```sh
python3 scripts/analyze_lib_deps.py --json
python3 scripts/lib_dep_report.py --graph reports/lib-dependency-graph.json --output reports/lib-dependency-summary.md
python3 scripts/lib_dep_report.py --graph reports/lib-dependency-graph.json --baseline reports/lib-dependency-graph.baseline.json --format json
```
