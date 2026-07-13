---
status: reference
last_verified: 2026-04-23
code_refs:
  - lib/capability_registry.ml
---

# Capability Registry SSOT

This document defines the canonical split between:

- external MCP tools exposed to MCP clients
- internal tool surfaces exposed to MASC-managed agents
- internal and Keeper tool projections

## Core Rule

The canonical SSOT is the **capability registry**, not any single tool list.

Each capability may project into multiple surfaces:

- `public_mcp`
- `spawned_agent_mcp`
- `local_worker`
- `keeper`

Removed surfaces (historical record):

- `mdal_auditable` — removed in PR #4417 ("refactor: remove MDAL dead code")
- `managed_agent_mcp` — never a `capability_registry` surface variant;
  `Managed_agent` exists only as a `tool_profile` in `mcp_server_eio`

Some projections intentionally reuse the same tool name with a different schema.
Example:

- `masc_heartbeat`
  - public MCP projection: general MCP client schema
  - local worker projection: simplified internal schema

Some projections intentionally expose different tool names for the same
capability.
Example:

- capability `masc_board_post`
  - public MCP projection: `masc_board_post`
  - keeper projection: `keeper_board_post`

## Audience Split

### External MCP client

- sees only the public MCP surface
- discovers tools via `tools/list`
- should treat that inventory as the truthful public contract

### Managed agent MCP client

- uses `/mcp/managed`
- sees the managed-agent surface, including SDK-style aliases and curated passthrough tools
- is intended for repo-controlled agent SDK clients and managed swarm members

### Spawned managed agent

- currently uses a curated subset of the public MCP names because external
  MCP-connected CLIs still call server-discoverable MCP tools directly
- the allowlist is derived from the capability registry projection
- migrating those CLIs to `/mcp/managed` also requires client-side MCP server
  registration changes outside this repo

### Local worker / MDAL / Autonomy worker

- uses the internal local-worker projection
- may include:
  - internal-only worker helpers
  - selected public MCP capabilities approved for internal use

### Keeper

- receives the complete descriptor-declared Keeper projection
- excludes only exact transport aliases (which name their visible projection)
  and descriptors with missing or structurally invalid schemas
- has no standard/privileged surface split
- routes concrete external effects through the non-hierarchical Keeper Gate;
  tool visibility itself is not an authorization decision
