# lib/ Monolith Decomposition — Phase 0 Analysis

Date: 2026-03-29
Issue: #3593

## Current State

| Metric | Value |
|--------|-------|
| Sub-libraries extracted | 26 |
| Monolith modules remaining | 550 (in dependency graph) |
| Total dependency edges | 1,804 |
| Avg dependencies per module | 3.28 |
| Leaf modules (0 internal deps) | 158 |
| Root modules (nothing depends on them) | 111 |

## Critical Finding: 81-Module Cycle

After removing analysis false positives from comments and nested in-file modules,
the monolith contains 1 strongly connected component (cycle):

| SCC | Size | Composition |
|-----|------|-------------|
| SCC-1 | 81 modules | Tool_* (28), Keeper_* (14), Server_* (3), + 36 others |

**SCC-1 is the primary obstacle to decomposition.** 14% of all modules are locked in a single cycle. The cycle is driven by:
- Tool modules calling Keeper for context
- Keeper calling Tool dispatch for execution
- Both depending on Room, Mcp_server, and Config

## Hub Modules (Dependency Bottlenecks)

These modules have the highest in-degree (most depended-upon):

| Module | Dependents | Role |
|--------|------------|------|
| Room | 136 | Central state container |
| Tool_args | 59 | Tool argument types |
| Keeper_types | 44 | Keeper type definitions |
| Mcp_server | 35 | MCP protocol server |
| Team_session_store | 38 | Session persistence |
| Sse | 29 | Server-sent events |
| Chain_types | 25 | Chain type definitions |

Room (136 dependents = 25% of all modules) is the gravity well.

## Extraction Candidates (by coupling ratio)

High coupling ratio = internal edges dominate over external deps = easier to extract.
`tool_schemas`, `activity_graph`, `prompt_registry`, the `swarm_status`
core/helper set, and the `Mcp_session` / `Mcp_transport_protocol` /
`Response` leaf primitives are already extracted in this branch, so the
next candidates start at Batch 2 with a cleaner `server_mcp` boundary.
Recent prep also moved protocol-version parsing into
`masc_mcp.mcp_transport_protocol` and localized runtime/profile
conversion at the HTTP/H2 edges, so `server_mcp` now depends on only four
external clusters: `Ag_ui`, `Sse`, `Transport`, and `Transport_metrics`.

| Prefix Group | Modules | Coupling | Ext Deps | Status |
|-------------|---------|----------|----------|--------|
| server_mcp | 10 | 0.800 | 4 | Medium |
| tool_command | 9 | 0.630 | 10 | Medium |
| dashboard_proof | 5 | 0.556 | 4 | Medium |
| tool_improve | 6 | 0.500 | 5 | Medium |
| team_session | 13 | 0.436 | 22 | Hard (high ext deps) |
| masc_grpc | 5 | 0.429 | 4 | Medium |

## vs. Issue #3593 Proposed Plan

| Phase | Issue Proposal | Analysis Verdict |
|-------|---------------|-----------------|
| Phase 1: masc_chain (47 files) | Lowest coupling | chain_* prefix not in top extraction candidates — Chain_types has 25 dependents, may be harder than expected |
| Phase 2: masc_command_plane (18 files) | cp_* prefix clear | Not enough cp_* in analysis. May have been renamed. Needs validation |
| Phase 3: masc_team_session (17 files) | OAS-heavy | team_session: coupling 0.436, 22 ext deps. Medium-hard |
| Phase 4: masc_dashboard (43 files) | server/keeper cross-ref | dashboard_* scattered. dashboard_proof (5) is extractable |
| Phase 5: masc_server (54 files) | Highest global deps | Mcp_server_eio_execute has 60 deps. Hardest extraction |
| Phase 6: masc_keeper (71 files) | Deferred | 17 keeper modules in SCC-1. Requires breaking Tool<->Keeper cycle first |

## Recommended Extraction Order (Data-Driven)

**Principle**: Extract leaf clusters first (high coupling, low external deps), then progressively tackle hub modules.

### Batch 1: Low-risk extractions (no SCC involvement)
Completed in this branch:
1. **tool_schemas** (18 modules, coupling 1.0) — extracted as `masc_mcp.tool_schemas`
2. **activity_graph** (4 modules, coupling 1.0) — extracted as `masc_mcp.activity_graph`
3. **prompt_registry** (3 modules, coupling 1.0) — extracted as `masc_mcp.prompt_registry`
4. **swarm_status** core/helpers (6 modules) — extracted as `masc_mcp.swarm_status`
   with `Swarm_status` wrapper and `Swarm_status_inputs` left in the monolith to bridge
   `Command_plane_v2` and `Team_session_store`
5. **Mcp_session** (leaf primitive) — extracted as `masc_mcp.mcp_session`
6. **Mcp_transport_protocol** (leaf primitive) — extracted as `masc_mcp.mcp_transport_protocol`
   to reduce direct `server_mcp` transport dependencies before Batch 2
7. **Response** (leaf primitive) — extracted as `masc_mcp.response`
   to remove one more direct `server_mcp` dependency before Batch 2

**Batch 1 status**: complete. No remaining low-risk 3+ module clusters.

### Batch 2: Medium-risk extractions
8. **server_mcp** (10 modules, coupling 0.800, ext deps 4 after primitive extraction + profile/runtime boundary cleanup)
9. **tool_command** (9 modules, coupling 0.630)
10. **dashboard_proof** (5 modules, coupling 0.556)
11. **masc_grpc** (5 modules, coupling 0.429)

### Batch 3: SCC-breaking (requires interface redesign)
12. Break Tool <-> Keeper cycle by introducing interface modules
13. Extract keeper_* as sub-library
14. Extract remaining tool_* modules
15. Extract server_* modules

## Analysis Corrections Applied

- Previous SCC-2 (`Keeper_toml_loader <-> Keeper_types_profile`) was a false positive from module-like text in comments.
- Previous SCC-3 (`Drift_guard <-> Level2_config`) was a false positive from nested in-file module references such as `module Drift_guard = struct`.
- The analysis script now strips OCaml comments/strings and ignores locally defined nested modules before dependency extraction.

With those heuristics corrected, the graph collapses to one real SCC.

## Next Steps

1. Start `server_mcp` as the first Batch 2 extraction from the reduced 4-dependency boundary
2. Validate whether `tool_command` still follows `server_mcp` after that split
3. Plan the remaining Batch 2 order from the updated graph
4. Re-evaluate whether `masc_chain` is still a sensible Phase 1 target after Batch 2
