---
description: MCP 서버 instructions — 프로필별 도구 발견 안내(full / managed_agent / operator_remote)
category: mcp
operator_surface: primary
---

### full
MASC (Multi-Agent Streaming Workspace) enables AI agent collaboration.
PROJECT: Agents sharing the same base path (.masc/ folder) align together.
CLUSTER: Set MASC_CLUSTER_NAME for multi-machine workspace (otherwise tool
surfaces use the configured cluster/default label).
READ: use resources/list + resources/read (status/tasks/agents/events/schema)
for snapshots.
WRITE: task state changes are CAS-guarded; pass expected_version.

### managed_agent
MASC managed-agent profile exposes the internal agent control surface. Do not
assume that the public /mcp surface and the managed-agent surface have the same
inventory.

### operator_remote
MASC remote operator profile exposes six operator tools:
masc_operator_snapshot, masc_operator_digest, masc_operator_action,
masc_operator_board_attention_quarantine_requeue,
masc_operator_task_recovery_resolve, and masc_operator_confirm.
masc_operator_board_attention_quarantine_requeue accepts only with the exact
Keeper, partition, candidate, and quarantine id observed from durable state; it
never auto-retries. masc_operator_task_recovery_resolve accepts only the exact
task owner and backlog version observed from Task state; it performs no liveness
inference. When confirm_required=true, you must call masc_operator_confirm with
the returned confirm_token before the action executes. Do not assume access to
any other MASC tool from this endpoint.

### tool_help (vars: focus_section, tool_name, short_description, when_to_use, key_constraints, details_markdown, docs_section)
Explain this MCP tool using only the grounded fields below.
Do not invent extra workflow steps beyond the listed help.

{{focus_section}}Tool: {{tool_name}}
Short description: {{short_description}}
When to use: {{when_to_use}}
Key constraints:
{{key_constraints}}
Details:
{{details_markdown}}{{docs_section}}
