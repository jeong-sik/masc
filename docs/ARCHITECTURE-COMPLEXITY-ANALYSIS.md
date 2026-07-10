---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/
  - bin/
---

# MASC Architecture Complexity Analysis

Date: 2026-03-16
Version: 2.93.0

## Executive Summary

masc grew from a multi-agent workspace collaboration MCP server into a 34K-line system with
85 tool modules, 72 dispatch entries, and 371 MCP tools. A typical MCP server exposes
5-15 tools. This analysis identifies what is essential, what is experimental residue,
and proposes a phased reduction plan.

## Verified Metrics

| Metric | Value | Typical MCP server |
|--------|-------|--------------------|
| Dispatch entries | 72 | 5-15 |
| tool_*.ml files | 85 | 3-10 |
| Total tool lines | 34,667 | 1-3K |
| MCP tool schemas | ~371 | 5-15 |
| .masc/ state dir | 62MB (before cleanup) | <1MB |
| dune modules | 579 | 20-50 |
| Environment vars | 50+ | 5-10 |

## Module Tier Classification

### Tier 1: Core (5 modules, ~1.5K lines)

MASC's minimum viable feature set. join -> claim -> work -> done.

| Module | Lines | Role |
|--------|-------|------|
| tool_agent | 290 | Agent registration/profiles |
| tool_workspace | 291 | Workspace join/leave/broadcast |
| tool_task | 418 | Task CRUD + claim/done |
| tool_heartbeat | ~119 | Liveness tracking |
| tool_dispatch | ~200 | Generic fallback router |

### Tier 2: Production (12 modules, ~8K lines)

Modules that deliver real value in daily operation.

| Module | Lines | Role | Necessity |
|--------|-------|------|-----------|
| tool_operator | 856 | dispatch/assign/rebalance | High |
| retired command-plane tools | removed | former command-plane truth layer | Removed |
| tool_keeper | 624 | persistent agent runtime | High |
| tool_continuous | 643 | autonomous agent loops | Medium |
| tool_plan | 186 | planning context | High |
| repo isolation helpers | 40 | git isolation | High |
| tool_board/misc | ~770 | bulletin board | Medium |
| tool_auth | 122 | token auth | Medium |
| tool_cost | ~100 | cost tracking | Low |
| tool_cache | ~100 | cache management | Low |
| tool_goals | 643 | goal management | Medium |
| tool_vote | ~200 | voting/consensus | Low |

### Tier 3: Extensions (12 modules, ~8K lines)

Useful but not core to workspace collaboration.

| Module | Lines | Role | Status |
|--------|-------|------|--------|
| tool_team_session | 0 | Team session spawning | Retired and removed |
| tool_mdal | 1092 | Metric-Driven Agent Loop | Active |
| tool_llama | 1052 | llama.cpp runtime mgmt | Active |
| tool_voice | ~200 | TTS/voice | OFF by default |
| tool_portal | ~200 | 1:1 secret messaging | Active |
| tool_encryption | ~100 | AES-256 | OFF by default |
| tool_rate_limit | ~100 | Rate limiting | Active |
| tool_social | ~200 | Keeper Autonomy social | Active |
| tool_notifications | ~100 | Notifications | Active |
| tool_audit | ~100 | Audit logging | Active |

### Tier 4: Experimental/Game (18 modules, ~11K lines, 32% of total)

Not related to core workspace collaboration. Candidates for separation or removal.

| Module | Lines | Role | Verdict |
|--------|-------|------|---------|
| tool_trpg | **1934** | TRPG simulation | Separate package |
| tool_protocol_game_view | **1674** | Protocol game view | Separate package |
| tool_risc | **1070** | Role sampling campaigns | Experimental residue |
| tool_experiment | **898** | Sandbox | Experimental residue |
| retired_file_tool | ~200 | Code read/search | Utility |
| tool_tempo | ~200 | Tempo/rhythm | Experimental |
| tool_relay | ~200 | Relay | Experimental |
| tool_handover | ~200 | Handover | Experimental |
| tool_a2a | ~200 | Agent-to-Agent | Experimental |
| tool_hat | 39 | Role hat | Minimal |
| tool_agent_timeline | ~200 | Agent timeline | Utility |
| tool_library | ~200 | Library | Utility |
| tool_control | ~200 | Control | Utility |
| tool_suspend | ~200 | Suspend | Utility |
| tool_verification | ~200 | Verification | Utility |

## Legacy Loop Cleanup

Older cleanup, patrol, and ecosystem-control loops should not shape current architecture decisions.
They have been retired from the active runtime surface, so the current complexity discussion should stay centered on workspace, keeper, command-plane, and operator layers.

## Continuous Keepers Problem

### Before cleanup (Phase 1 complete)

| Path | Size before | Size after | Action |
|------|------------|------------|--------|
| keepers/*.metrics.jsonl | 25MB | 0 (deleted) | Stale idle heartbeat logs |
| continuous/trace-17716*,17724* | 1.2MB | 0 (deleted) | Ended experiment traces |
| **Total .masc/** | **63MB** | **36MB** | **27MB freed** |

### Root cause

- No retention/rotation on metrics files -> unbounded growth (~2MB/day)
- Historical idle-heartbeat samples reported derived goal-drift/alignment values
  without downstream consumers. Those semantic metrics are no longer emitted;
  current diagnostics use typed lifecycle, context-capacity, and turn evidence.

### Fix applied

- Size-based rotation added to `append_jsonl_line` (keeper_types.ml)
- Config: `MASC_KEEPER_METRICS_MAX_BYTES` (default 10MB), `MASC_KEEPER_METRICS_MAX_ROTATED` (default 1)
- At threshold: current -> .1, .1 -> .2, etc.

## tool_team_session.ml Split Plan (4412 lines)

> **Obsolete.** The entire `tool_team_session` surface was retired rather than
> split; the module and its dispatcher no longer exist. Kept below as historical
> context for the decision path that led from "split the 4412-line module" to
> "remove the swarm-start front door entirely".

Recommended 4-module split:

| New module | Lines | Content |
|-----------|-------|---------|
| tool_team_session_types.ml | ~90 | Type definitions (leaf) |
| tool_team_session_parse.ml | ~700 | JSON parsers + OAS converters (pure) |
| tool_team_session_spawn.ml | ~1050 | Risk routing + spawn logic |
| tool_team_session_handlers.ml | ~1570 | Request handlers + orchestration |
| tool_team_session.ml | ~670 | Dispatcher + schema definitions |

Dependency graph (no cycles):
```
types (leaf) <- parse <- spawn <- handlers <- tool_team_session (entry)
```

## Complexity Root Causes

1. **Features accumulate, never removed** — feature flags OFF = "done"
2. **Experiments land in lib/ directly** — no plugin/package boundary
3. **TRPG/games cohabitate with workspace collaboration** — unrelated concerns in one binary
4. **No metrics retention** — logs grow without bound (fixed in this PR)

## Phased Reduction Plan

### Phase 1: Immediate (this PR)

- [x] Delete stale .masc/ data (27MB freed)
- [x] Add metrics rotation to append_jsonl_line
- [ ] Architecture analysis document (this file)

### Phase 2: Separation (separate PRs)

- [ ] TRPG + protocol_game_view -> `masc-games` library (3600+ lines)
- [ ] risc + experiment -> `masc-experiments`
- [ ] dune optional library separation

### Phase 3: Structural improvements (separate PRs)

- [ ] Mode/profile system: core (5) / standard (17) / full (72) dispatchers
- [ ] Environment variables -> config file consolidation

## TRPG as Agent Play (Design Note)

TRPG is not "waste" — it represents non-deterministic agent activity.

```
Agent life = Work (tasks) + Social (board) + Play (TRPG)
```

Current problems:
- dm-keeper runs always-on with zero output
- No participation mechanism (who joins when?)
- TRPG sessions not linked to MASC tasks

Proposed changes:
- dm-keeper -> on-demand (start when game needed)
- Agent idle time + interests -> participation probability (Thompson sampling)
- TRPG experience feeds back into agent interests/traits
