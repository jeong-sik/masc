---
description: OAS before-turn nudge when a keeper claimed a task but only emitted claim-context tools
category: keeper
template_variables: [task_id]
---
[CLAIMED TASK] You hold {{task_id}}. Do NOT call claim_next again. Use an execution tool from your active runtime schema to start working on it now. If no execution tool is available, emit [STATE] with the blocker instead of inventing a tool name.
