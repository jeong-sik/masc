---
status: reference
---

# Capability Registry SSOT

This document defines the canonical split between:

- external MCP tools exposed to MCP clients
- internal tool surfaces exposed to MASC-managed agents
- internal and Keeper tool projections

## Core Rule

The canonical SSOT is the **capability registry**, not any single tool list.

Each capability may project into one or more capability-registry surfaces:

- `public_mcp`
- `spawned_agent_mcp`
- `keeper`

At the MCP server layer (`lib/mcp_server_eio_tool_profile.mli`), connections
select a `tool_profile`: `Full`, `Managed_agent`, `Operator_remote`, or `Seat`.

Some projections reuse the same capability or tool name across surfaces:
Example:

- capability `masc_board_post`
  - public MCP projection: `masc_board_post`
  - keeper projection: `masc_board_post`

## Audience Split

### External MCP client (`Full` / `Operator_remote` / `Seat` tool profile)

- sees the public MCP surface (or the profile-filtered subset such as the 6
  remote operator tools on `/mcp/operator` or seat-bound tools)
- discovers tools via `tools/list`
- treats that inventory as the public contract

### Managed agent MCP client (`Managed_agent` tool profile)

- uses `/mcp/managed`
- sees the managed-agent surface, including SDK-style aliases and curated passthrough tools
- is intended for repo-controlled agent SDK clients and managed swarm members

### Spawned managed agent (`spawned_agent_mcp` surface)

- uses a curated subset of the public MCP names so external MCP-connected CLIs
  can call server-discoverable MCP tools directly
- the allowlist is derived from the capability registry projection

### Keeper (`keeper` surface)

- receives the complete descriptor-declared Keeper projection
- excludes only exact transport aliases (which name their visible projection)
  and descriptors with missing or structurally invalid schemas
- has no standard/privileged surface split
- routes concrete external effects through the non-hierarchical Keeper Gate;
  tool visibility itself is not an authorization decision
