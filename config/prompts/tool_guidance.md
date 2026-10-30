---
description: Generic tool-result guidance that is not tied to one domain — Tool_guidance.t closed variant picks the slot
category: tool
operator_surface: fragment
---
### broadcast_delivery_rejected (vars: request_id)
Broadcast persisted, but the explicit Keeper delivery was rejected; do not resend; request_id={{request_id}}

### broadcast_content_required
content is required. Good: content='Build complete, all tests pass.'.

### workspace_message_delivery_rejected
Workspace message persisted, but Keeper delivery was rejected; do not resend

### post_execution_hook_failed
Tool completed, but its post-execution hook failed; do not retry

### mcp_outcome_unknown
MCP tool outcome is unknown; do not retry this call id

### reject_verdict_requires_reason
REJECT verdict requires a non-empty reason

### no_metrics_found_for_agent (vars: agent)
no metrics found for agent: {{agent}}

### invalid_agent_card_action (vars: action_quoted, valid_actions)
invalid action {{action_quoted}}; expected one of: {{valid_actions}}
