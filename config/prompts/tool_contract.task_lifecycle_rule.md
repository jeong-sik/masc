---
description: MASC task lifecycle rule shared by MCP tool schema descriptions
category: tool_contract
---
For normal task work, claim first, then call action='start'. Every completion request is judged by the configured LLM using the Task, context, notes, and evidence. A structured pass reaches done; a structured reject leaves work nonterminal; an unavailable evaluator returns an explicit error. submit_for_verification is an asynchronous scheduling state, not an actor-approval hierarchy.
