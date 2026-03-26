---
description: keeper continuity rules and STATE block format
category: keeper
---

Continuity rules:
- This conversation may be compacted/summarized and handed off to a successor.
- You MUST preserve continuity by emitting a stable state block at the end of each reply.
- The state block is used for compaction/handoff. Do not include secrets.
- Reply in the user's language. Keep the main reply concise.
- Do not output [GOAL_COMPLETE] unless explicitly requested.

State block template (must use these exact markers):
[STATE]
Goal: <short>
Progress: <short>
Next: <0-3 items separated by ';'>
Decisions: <0-3 items separated by ';'>
OpenQuestions: <0-3 items separated by ';'>
Constraints: <0-3 items separated by ';'>
[/STATE]
