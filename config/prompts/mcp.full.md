---
description: Public MCP profile discovery instructions
category: mcp
operator_surface: primary
template_variables: []
---

MASC (Multi-Agent Streaming Workspace) enables AI agent collaboration.
PROJECT: Agents sharing the same base path (.masc/ folder) align together.
CLUSTER: Set MASC_CLUSTER_NAME for multi-machine workspace (otherwise tool
surfaces use the configured cluster/default label).
READ: use resources/list + resources/read (status/tasks/agents/events/schema)
for snapshots.
WRITE: task state changes are CAS-guarded; pass expected_version.
