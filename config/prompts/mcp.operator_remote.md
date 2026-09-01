---
description: Remote operator MCP profile discovery instructions
category: mcp
operator_surface: primary
template_variables: []
---

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
