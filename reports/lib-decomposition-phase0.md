# lib/ Monolith Decomposition — Phase 0 Analysis

Date: 2026-03-29
Issue: #3593

## Current State

| Metric | Value |
|--------|-------|
| Sub-libraries extracted | 19 |
| Monolith modules remaining | 586 (in lib/dune) |
| Total dependency edges | 1,961 |
| Avg dependencies per module | 3.35 |
| Leaf modules (0 internal deps) | 170 |
| Root modules (nothing depends on them) | 109 |

## Critical Finding: 115-Module Cycle

The monolith contains 3 strongly connected components (cycles):

| SCC | Size | Composition |
|-----|------|-------------|
| SCC-1 | 115 modules | Tool_* (49), Keeper_* (17), + 49 others |
| SCC-2 | 2 modules | Keeper_toml_loader <-> Keeper_types_profile |
| SCC-3 | 2 modules | Drift_guard <-> Level2_config |

**SCC-1 is the primary obstacle to decomposition.** 20% of all modules are locked in a single cycle. The cycle is driven by:
- Tool modules calling Keeper for context
- Keeper calling Tool dispatch for execution
- Both depending on Room, Mcp_server, and Config

## Hub Modules (Dependency Bottlenecks)

These modules have the highest in-degree (most depended-upon):

| Module | Dependents | Role |
|--------|------------|------|
| Room | 139 | Central state container |
| Tool_args | 59 | Tool argument types |
| Keeper_types | 44 | Keeper type definitions |
| Mcp_server | 41 | MCP protocol server |
| Team_session_store | 38 | Session persistence |
| Sse | 30 | Server-sent events |
| Chain_types | 25 | Chain type definitions |

Room (139 dependents = 24% of all modules) is the gravity well.

## Extraction Candidates (by coupling ratio)

High coupling ratio = internal edges dominate over external deps = easier to extract.

| Prefix Group | Modules | Coupling | Ext Deps | Status |
|-------------|---------|----------|----------|--------|
| activity_graph | 4 | 1.000 | 0 | Ready |
| prompt_registry | 3 | 1.000 | 0 | Ready |
| swarm_status | 8 | 0.889 | 2 | Ready |
| tool_schemas | 18 | 0.875 | 1 | Ready |
| server_mcp | 10 | 0.667 | 8 | Medium |
| tool_command | 9 | 0.630 | 10 | Medium |
| dashboard_proof | 5 | 0.556 | 4 | Medium |
| tool_improve | 6 | 0.500 | 5 | Medium |
| masc_grpc | 5 | 0.429 | 4 | Medium |
| team_session | 13 | 0.415 | 24 | Hard (high ext deps) |

## vs. Issue #3593 Proposed Plan

| Phase | Issue Proposal | Analysis Verdict |
|-------|---------------|-----------------|
| Phase 1: masc_chain (47 files) | Lowest coupling | chain_* prefix not in top extraction candidates — Chain_types has 25 dependents, may be harder than expected |
| Phase 2: masc_command_plane (18 files) | cp_* prefix clear | Not enough cp_* in analysis. May have been renamed. Needs validation |
| Phase 3: masc_team_session (17 files) | OAS-heavy | team_session: coupling 0.415, 24 ext deps. Medium-hard |
| Phase 4: masc_dashboard (43 files) | server/keeper cross-ref | dashboard_* scattered. dashboard_proof (5) is extractable |
| Phase 5: masc_server (54 files) | Highest global deps | Mcp_server_eio_execute has 60 deps. Hardest extraction |
| Phase 6: masc_keeper (71 files) | Deferred | 17 keeper modules in SCC-1. Requires breaking Tool<->Keeper cycle first |

## Recommended Extraction Order (Data-Driven)

**Principle**: Extract leaf clusters first (high coupling, low external deps), then progressively tackle hub modules.

### Batch 1: Low-risk extractions (no SCC involvement)
1. **activity_graph** (4 modules, coupling 1.0) — zero external deps
2. **prompt_registry** (3 modules, coupling 1.0) — zero external deps
3. **swarm_status** (8 modules, coupling 0.889) — 2 external deps
4. **tool_schemas** (18 modules, coupling 0.875) — 1 external dep

**Total**: 33 modules extracted with minimal risk.

### Batch 2: Medium-risk extractions
5. **server_mcp** (10 modules, coupling 0.667)
6. **tool_command** (9 modules, coupling 0.630)
7. **dashboard_proof** (5 modules, coupling 0.556)
8. **masc_grpc** (5 modules, coupling 0.429)

### Batch 3: SCC-breaking (requires interface redesign)
9. Break Tool <-> Keeper cycle by introducing interface modules
10. Extract keeper_* as sub-library
11. Extract remaining tool_* modules
12. Extract server_* modules

## SCC-2 and SCC-3 (Quick Fixes)

- **SCC-2**: Keeper_toml_loader <-> Keeper_types_profile — likely a type definition cycle. Fix by merging or splitting the shared type.
- **SCC-3**: Drift_guard <-> Level2_config — similar pattern.

These should be fixed before Batch 2.

## Next Steps

1. Fix SCC-2 and SCC-3 (trivial cycles) in a quick PR
2. Extract Batch 1 (33 modules, 4 sub-libraries) — 1-2 sessions
3. Re-run analysis to validate reduced SCC-1 size
4. Plan Batch 2 based on updated graph
