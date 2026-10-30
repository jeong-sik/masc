---
description: Exec-policy block reasons and cwd hint — the short model-facing rejections surfaced via block_reason_to_string
category: tool
operator_surface: fragment
---
### block_reason.empty_command
command must not be empty

### block_reason.process_substitution
Process substitution (<(...) or >(...)) is not allowed.

### block_reason.pipes_not_allowed
Pipes are not allowed. Run one command per call.

### cwd_existing_siblings_hint (vars: ancestor, dirs, suffix)
(existing directories under {{ancestor}}/: {{dirs}}{{suffix}})
