# MCP Surface Audit

Current-state audit of `masc-mcp` MCP exposure, public design, and documentation boundaries.

As of `2026-03-12`, the server shape is broadly sound, but its explanation surface is split across multiple docs and two prompt systems.

## Evidence

- Local contract tests:
  - `_build/default/test/test_mcp_server_eio.exe`
  - `_build/default/test/test_mode_tool_count.exe`
- Live inventory diagnostics:
  - `_build/_tests/mode_tool_count/diagnostics.000.output`
- Public entrypoints:
  - [README.md](../README.md)
  - [MERGED-ARCHITECTURE-SSOT.md](./MERGED-ARCHITECTURE-SSOT.md)
  - [REMOTE-MCP-OPERATOR.md](./REMOTE-MCP-OPERATOR.md)
- MCP implementation:
  - [mcp_server.ml](../lib/mcp_server.ml)
  - [mcp_server_eio.ml](../lib/mcp_server_eio.ml)
  - [mcp_prompt_surface.ml](../lib/mcp_prompt_surface.ml)
  - [CAPABILITY-REGISTRY-SSOT.md](./CAPABILITY-REGISTRY-SSOT.md)

## Inventory Summary

| Surface | Count | Source | Notes |
|--------|------:|--------|-------|
| Raw tool schemas | 449 | `Config.raw_all_tool_schemas` | Includes hidden, deprecated, placeholder, and compatibility aliases |
| Visible tool schemas | 403 | `Config.visible_tool_schemas ()` | Default `tools/list` public surface |
| MCP prompts | 3 | `lib/mcp_prompt_surface.ml` | `tool_help`, `team_session_proof`, `command_truth` |
| Fixed MCP resources | 21 | `lib/mcp_server.ml` | Status, tasks, messages, events, worktrees, schema, institution, library, tool-help index |
| MCP resource templates | 7 | `lib/mcp_server.ml` | Message/event ranges, library docs, per-tool help |
| Internal prompt templates | 18 | `data/prompts/` + `config/prompts/` | Chain/runtime prompt registry plus markdown-managed operator prompts, not MCP-discoverable |

The key split is intentional:

- `prompts/list/get` exposes a very small human-facing MCP prompt surface.
- `Prompt_registry` serves chain/runtime internals and should not be described as the public MCP prompt API.

## Public Surface Groups

| Group | Public Discovery Path | Canonical Examples | Notes |
|------|------------------------|--------------------|-------|
| Canonical MCP tools | `tools/list` | `masc_transition`, `masc_team_session_step`, `decision.create`, `experiment.start`, `trpg.dice.roll` | Default surface for normal clients |
| Managed agent MCP | `/mcp/managed` | `masc_room_status`, `masc_list_tasks`, `masc_claim_task`, `masc_plan_set_task` | Internal managed-agent surface with SDK aliases such as `masc_set_current_task` plus curated passthrough tools |
| Compatibility aliases | Deprecated and excluded from default `tools/list` | `masc_claim`, `experiment_start`, `masc_trpg_dice_roll` | Still callable for compatibility; not part of the truthful default inventory |
| MCP prompts | `prompts/list`, `prompts/get` | `tool_help`, `team_session_proof`, `command_truth` | Explanation/proof layer, not runtime prompt registry |
| MCP resources | `resources/list/read` | `masc://status`, `masc://tasks`, `masc://tool-help-index` | Snapshot/read layer |
| Remote operator | `/mcp/operator` | `masc_operator_snapshot`, `masc_operator_digest` | Separate 4-tool remote-safe profile |
| Internal prompt/runtime plane | Not MCP-discoverable | `Prompt_registry`, `data/prompts/*.json`, `config/prompts/*.md` | Used by chains, keepers, dashboard judges, and runtime execution |

`masc_web_search` public contract note:

- Public tool name remains `masc_web_search`.
- Request contract remains `query` + optional `limit`.
- Response contract remains `{status:"ok", result:{query, engine, search_url, result_count, results[]}}`, with normalized per-result metadata (`source`, `rank`, optional `published_at`) added inside `results[]`.
- Runtime selection is config/env driven: official APIs first when configured, scraping fallback second.

## Public Surface Map

```mermaid
flowchart TD
  Client[MCP Client] --> MCP[/mcp/]
  Client --> Operator[/mcp/operator/]

  MCP --> TL[tools/list]
  MCP --> PL[prompts/list get]
  MCP --> RL[resources/list read templates]

  TL --> Canon[Canonical tool surface]
  TL --> Hidden[Hidden aliases not listed]

  Canon --> Core[Namespace task session managed-op]
  Canon --> GameView[decision.* experiment.* trpg.* client.*]
  Canon --> Ecosystem[keeper always-on autonomy]

  PL --> PromptSurface[MCP prompt surface: 3 prompts]
  RL --> ResourceSurface[MCP resources and tool-help views]

  Operator --> Remote4[4 remote-safe operator tools]

  Hidden -. direct call only .-> Compat[Compatibility aliases]
  PromptSurface -. separate from .-> InternalPrompts[Prompt_registry data/prompts]
```

## Workflow Pipelines

### 1. Project Scope and Task Hygiene

```mermaid
flowchart LR
  Start[masc_start] --> Status[masc_status]
  Status --> Claim[masc_transition or masc_claim_next]
  Claim --> Plan[masc_plan_set_task when needed]
  Plan --> Worktree[masc_worktree_create]
  Worktree --> Heartbeat[masc_heartbeat]
  Heartbeat --> Done[masc_transition done]
```

### 2. Managed Operation + Team Session

```mermaid
flowchart LR
  Unit[masc_unit_define] --> OpStart[masc_operation_start]
  OpStart --> Dispatch[masc_dispatch_tick]
  Dispatch --> Session[masc_team_session_start]
  Session --> Step[masc_team_session_step]
  Step --> Observe[masc_observe_* and masc_team_session_status]
  Observe --> Proof[masc_team_session_prove]
  Proof --> Finalize[masc_operation_finalize and masc_team_session_stop]
```

### 3. Game View and Legacy Alias Lane

```mermaid
flowchart LR
  Canonical[decision.* experiment.* trpg.* client.*] --> PGV[tool_protocol_game_view]
  Legacy[experiment_start masc_trpg_*] --> Alias[legacy_alias_to_canonical]
  Alias --> PGV
  PGV --> Runtime[experiment and TRPG handlers]
```

## Architecture Layers

```mermaid
flowchart TD
  Runtime[Runtime substrate<br/>local64 llama pool voice storage] --> Control[Managed-operation command plane]
  Control --> Orchestration[Native chain plane]
  Orchestration --> Workflow[Team Session and Supervisor]
  Workflow --> Operator[Operator digest and confirm flow]

  Secondary1[Keeper Autonomy ecosystem] -. attached subsystem .-> Workflow
  Secondary2[Game-view dotted tools] -. canonical public alias layer .-> Workflow
  Secondary3[SWARM-RISC research modules] -. merged but not canonical .-> Control
```

## Findings

### What is working

- MCP server capabilities are exposed correctly for `tools`, `resources`, and `prompts`.
- `tools/list`, `prompts/list/get`, `resources/list/read/templates/list`, pagination, and resource subscriptions are covered by passing local tests.
- The dotted canonical names for `decision.*`, `experiment.*`, and `trpg.*` are real public tools, not just documentation fiction.
- `/mcp/operator` is properly separated as a remote-safe reduced profile.

### What was confusing

- `resources/list` previously generated per-tool help resources from raw schemas, which leaked hidden/deprecated/placeholder inventory through a standard MCP discovery path.
- `resources/read` returned `-32602` for missing resources, which is an argument error, not a resource-miss error.
- `Prompt_registry` and `Mcp_prompt_surface` describe two different prompt systems; without an explicit note, they look like one broken or incomplete system.
- `docs/SPEC.md` reads like a current full spec, but large portions no longer match the merged architecture or module graph.

### What this change fixes

- Standard MCP resource discovery now uses only the visible tool inventory for tool-help resources and the tool-help index.
- Missing or hidden `masc://tool-help/...` lookups now resolve as `Resource not found`.
- Documentation now has a dedicated audit/SSOT for public surface boundaries.

## Orphan Classification

| Type | Examples | Status |
|------|----------|--------|
| Intentional compatibility | `masc_claim`, `experiment_start`, `masc_trpg_*` | Deprecated/default-off aliases; keep if compatibility matters |
| Intentional internal-only | `Prompt_registry`, `data/prompts/*.json`, `config/prompts/*.md` | Real runtime feature, not public MCP surface |
| Experimental but documented | `SWARM-RISC`, `GAME-VIEW-PROTOCOL` draft | Keep clearly labeled as non-canonical or draft |
| Placeholder / review-needed | none | Dead hidden placeholder removed from the MCP schema inventory |
| Documentation orphan | old count claims, old module lists, stale “full spec” prose | Should be downgraded to historical or refreshed |

## Requirements Coverage

| Question | Best Source |
|---------|-------------|
| What tools are truly public? | `tools/list` plus [README.md](../README.md) |
| What hidden or deprecated tools still exist? | `masc_tool_admin_snapshot`, `masc_tool_help`, `Tool_catalog` |
| What prompts are public MCP prompts? | `prompts/list`, [mcp_prompt_surface.ml](../lib/mcp_prompt_surface.ml) |
| What prompt templates exist internally? | `data/prompts/`, `config/prompts/`, `Prompt_registry` |
| What resources exist? | `resources/list`, `resources/templates/list`, [mcp_server.ml](../lib/mcp_server.ml) |
| What is the canonical architecture? | [MERGED-ARCHITECTURE-SSOT.md](./MERGED-ARCHITECTURE-SSOT.md) |
| What is the canonical managed-operation flow? | [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md) |
| What is the canonical implementation-swarm flow? | [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md) |
| What is safe to expose remotely? | [REMOTE-MCP-OPERATOR.md](./REMOTE-MCP-OPERATOR.md) |

## Design Judgment

- Fundamentally, the design is good enough to explain and operate.
- The main weakness is not missing architecture; it is overlapping explanation layers.
- The repo already has a real operating spine:
  - `Namespace / task hygiene`
  - `Team Session + Supervisor`
  - optional managed-operation compatibility lane
  - optional dotted game-view aliases
- The biggest remaining risk is documentation drift, not core protocol shape.

## SSOT Rewrite Order

1. `README.md`
2. `docs/MERGED-ARCHITECTURE-SSOT.md`
3. `docs/COMMAND-PLANE-RUNBOOK.md`
4. `docs/SUPERVISOR-MODE.md`
5. `docs/REMOTE-MCP-OPERATOR.md`
6. `docs/GAME-VIEW-PROTOCOL.md` as explicit draft
7. `docs/SPEC.md` as historical snapshot, not current SSOT
