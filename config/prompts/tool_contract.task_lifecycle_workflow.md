---
description: MASC task lifecycle workflow shared by MCP profile instructions
category: tool_contract
---
masc_status -> masc_transition(claim) -> masc_transition(start) -> work in your repo clone on a task branch -> masc_transition(submit_for_verification) -> a different agent masc_transition(approve) completes it; non-strict tasks may masc_transition(done) directly
