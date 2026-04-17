---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/capability_registry.ml
---

# Capability Registry SSOT

This document defines the canonical split between:

- external MCP tools exposed to MCP clients
- internal tool surfaces exposed to MASC-managed agents
- privileged internal executor tools

## Core Rule

The canonical SSOT is the **capability registry**, not any single tool list.

Each capability may project into multiple surfaces:

- `public_mcp`
- `managed_agent_mcp`
- `spawned_agent_mcp`
- `local_worker`
- `keeper_standard`
- `keeper_privileged`
- `mdal_auditable`
- `privileged_executor`

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

- uses keeper-specific projected tools
- safe/default keeper tools and privileged keeper tools are tracked separately

## Privileged Internal Tools

The privileged executor class is internal-only.

Examples:

- `keeper_bash`
- `keeper_fs_edit`
- `keeper_edit`
- `keeper_github`

These tools are:

- not part of public MCP discovery
- separated from standard keeper surfaces
- expected to remain behind explicit policy and audit gates
