---
description: MASC task lifecycle rule shared by MCP tool schema descriptions
category: tool_contract
---
For normal task work, claim first, then call action='start'. Complete via action='submit_for_verification' — a verifier (not the assignee) then approves it to done. Strict-contract tasks reject direct done; only non-strict tasks may finish with action='done'.
