# Lib Dependency Decomposition Report

- Source: `reports/lib-dependency-graph.json`
- Baseline: none

## Summary

| Metric | Current | Delta |
| --- | --- | --- |
| total_modules | 572 | - |
| total_edges | 2150 | - |
| avg_out_degree | 3.76 | - |
| scc_count | 2 | - |
| largest_scc_size | 134 | - |

## Room/Coordination Dependents

| Module | Dependents | Delta |
| --- | --- | --- |
| Coord | 111 | - |

## Top Hub Modules

| Rank | Module | Dependents |
| --- | --- | --- |
| 1 | Coord | 111 |
| 2 | Keeper_types | 74 |
| 3 | Keeper | 54 |
| 4 | Tool_dispatch | 45 |
| 5 | Mcp_server | 35 |
| 6 | Sse | 30 |
| 7 | Oas | 30 |
| 8 | Tool_args | 30 |
| 9 | Prometheus | 27 |
| 10 | Tool_catalog | 27 |

## Heaviest Importers

| Rank | Module | Dependencies |
| --- | --- | --- |
| 1 | Server_bootstrap_loops | 59 |
| 2 | Keeper_agent_run | 51 |
| 3 | Server_runtime_bootstrap | 43 |
| 4 | Dashboard_http_keeper | 39 |
| 5 | Server_dashboard_http_keeper_api | 38 |
| 6 | Keeper_keepalive | 36 |
| 7 | Mcp_server_eio_execute | 35 |
| 8 | Keeper_unified_turn | 33 |
| 9 | Keeper_turn | 32 |
| 10 | Server_routes_http_routes_dashboard | 27 |

## Batch 2 Extraction Candidates

| Prefix | Modules | Coupling | External Deps | Internal Edges |
| --- | --- | --- | --- | --- |
| server_mcp | 10 | 0.789 | 4 | 15 |
| meta_cognition | 7 | 0.636 | 4 | 7 |
| keeper_social | 7 | 0.600 | 2 | 3 |
| masc_grpc | 5 | 0.429 | 4 | 3 |
| tool_autoresearch | 6 | 0.375 | 10 | 6 |
| keeper_exec | 14 | 0.311 | 42 | 19 |
| tool_local | 7 | 0.267 | 11 | 4 |
| operator_digest | 4 | 0.250 | 6 | 2 |
| mcp_server | 10 | 0.233 | 56 | 17 |
| server_routes | 16 | 0.230 | 67 | 20 |

## Regeneration

```sh
python3 scripts/analyze_lib_deps.py --json
python3 scripts/lib_dep_report.py --graph reports/lib-dependency-graph.json --output reports/lib-dependency-summary.md
python3 scripts/lib_dep_report.py --graph reports/lib-dependency-graph.json --baseline reports/lib-dependency-graph.baseline.json --format json
```
