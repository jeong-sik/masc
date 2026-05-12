# God File Inventory — 2026-05-12

## Methodology

Files with >1000 lines of OCaml (.ml + .mli) under lib/.

## Summary

| Metric | Count | Lines |
|--------|-------|-------|
| Total .ml/.mli files in lib/ | 2031 | 437,559 |
| Files >1000 lines | 67 | ~96,789 |
| Files >2000 lines | 9 | ~23,856 |

## Top 20 God Files

| Rank | File | Lines | Proposed Action |
|------|------|-------|-----------------|
| 1 | lib/prometheus.ml | 3,195 | Extract sub-lib lib/prometheus/; split constants + built-ins |
| 2 | lib/keeper/keeper_unified_turn.ml | 3,037 | Follow RFC-0072 pattern; extract sub-lib |
| 3 | lib/keeper/keeper_hooks_oas.ml | 2,697 | Partially done in history; complete extraction |
| 4 | lib/keeper/keeper_registry.ml | 2,659 | Extract sub-lib |
| 5 | lib/keeper/keeper_supervisor.ml | 2,618 | Extract sub-lib |
| 6 | lib/dashboard/dashboard_http_keeper.ml | 2,391 | Extract sub-lib |
| 7 | lib/tool_board.ml | 2,162 | Split into lib/tool_board/ sub-lib |
| 8 | lib/tool_shard.ml | 2,152 | Split into lib/tool_shard/ sub-lib |
| 9 | lib/dashboard/dashboard_goals.ml | 1,998 | Extract into lib/dashboard/ sub-lib |
| 10 | lib/server/server_runtime_bootstrap.ml | 1,996 | Extract into lib/server/ sub-lib |
| 11 | lib/runtime_catalog.ml | 1,982 | Follow RFC-0072; extract sub-lib |
| 12 | lib/keeper/keeper_types_profile.ml | 1,937 | Move into keeper sub-lib |
| 13 | lib/keeper/keeper_heartbeat_loop.ml | 1,851 | Move into keeper sub-lib |
| 14 | lib/keeper/keeper_unified_metrics.ml | 1,781 | Move into keeper sub-lib |
| 15 | lib/cascade/cascade_transport.ml | 1,772 | Extract lib/cascade/ sub-lib |
| 16 | lib/keeper/keeper_run_tools.ml | 1,725 | Move into keeper sub-lib |
| 17 | lib/operator/operator_control_snapshot.ml | 1,714 | Extract lib/operator/ sub-lib |
| 18 | lib/tool_keeper.ml | 1,696 | Split into sub-lib |
| 19 | lib/keeper/keeper_agent_run.ml | 1,690 | Move into keeper sub-lib |
| 20 | lib/server/server_dashboard_http_core.ml | 1,684 | Extract into server sub-lib |

## Progress (PR #14941)

- **tool_board.ml**: 2162 → 1706 lines (-456)
- **tool_shard.ml**: 2152 → 2094 lines (-58)
- **lib/ide/**: extracted as `masc_mcp.ide` sub-library
- **Total lines removed from god files**: ~530
- **Build status**: dune build lib/masc_mcp.cma passes

## Phase Plan

### Phase 1: Root-level god files (highest impact)
- [x] lib/tool_board.ml → tool_board_schemas extracted (469 lines, 2162→1706)
- [x] lib/tool_shard.ml → tool_shard_schemas extracted (61 lines, 2152→2094)
- [ ] lib/prometheus.ml → lib/prometheus/ sub-lib
- [ ] lib/tool_board.ml → lib/tool_board/ sub-lib
- [ ] lib/tool_shard.ml → lib/tool_shard/ sub-lib
- [ ] lib/runtime_catalog.ml → follow RFC-0072

### Phase 2: Directory extraction (directories without dune files)
- [x] lib/ide/ (7 files) → masc_mcp.ide sub-lib (zero flat-namespace deps)
- [ ] lib/keeper/ (500 files) → masc_mcp.keeper sub-lib
- [ ] lib/server/ (142 files) → masc_mcp.server sub-lib
- [ ] lib/dashboard/ (104 files) → masc_mcp.dashboard sub-lib
- [ ] lib/cascade/ (83 files) → masc_mcp.cascade sub-lib

### Phase 3: Remaining directories
- [ ] lib/operator/ (18 files) → sub-lib
- [ ] lib/goal/ (10 files) → sub-lib
- [ ] lib/grpc/ (10 files) → sub-lib
- [ ] lib/local/ (10 files) → sub-lib
- [ ] lib/otel/ (10 files) → sub-lib
- [ ] lib/voice/ (8 files) → sub-lib
- [ ] lib/ide/ (7 files) → sub-lib
- [ ] lib/memory/ (2 files) → sub-lib or merge
