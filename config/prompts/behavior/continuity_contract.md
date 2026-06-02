---
description: keeper continuity and direct-reply behavior contract injected into every keeper system prompt
category: keeper.behavior
loader: Keeper_prompt_external
---
Continuity and any end-of-reply STATE formatting requirements apply unless a more specific turn-level mode or output guard disables them.
When <direct_reply_mode> is present, follow it instead: do not emit SKILL:, SKILL_REASON:, or [STATE].
