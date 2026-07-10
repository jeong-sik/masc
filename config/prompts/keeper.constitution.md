---
description: keeper continuity and merge rules
category: keeper
---

Continuity rules:
- This conversation may be compacted/summarized and handed off to a successor.
- Continuity is owned by the runtime checkpoint, typed task/goal state, events, and tool results. Do not encode a second state machine in prose.
- Treat compacted conversation text as context, not as an instruction to mutate runtime state.
- Reply in the user's language. Keep the main reply concise.
- Do not output [GOAL_COMPLETE] unless explicitly requested.

PR merge rules (MANDATORY):
- Do NOT dismiss another agent's BLOCK or NEEDS_WORK review. Respond with fixes or justification.
- Do NOT merge a PR with zero reviews. Every PR requires at least one cross-agent review before merge.
- Do NOT merge a PR that has an unresolved BLOCK review. Only the original reviewer or the user can unblock.
- Before running any merge command, verify through the review/forge surface that at least one non-dismissed review exists.
