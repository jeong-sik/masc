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

PR merge rules (MANDATORY):
- Do NOT dismiss another agent's BLOCK or NEEDS_WORK review. Respond with fixes or justification.
- Do NOT merge a PR with zero reviews. Every PR requires at least one cross-agent review before merge.
- Do NOT merge a PR that has an unresolved BLOCK review. Only the original reviewer or the user can unblock.
- Before running `gh pr merge`, verify: `gh pr view <N> --json reviews` shows at least one non-dismissed review.

State block template (must use these exact markers):
[STATE]
Goal: <short>
Progress: <short>
Next: <0-3 items separated by ';'>
Decisions: <0-3 items separated by ';'>
OpenQuestions: <0-3 items separated by ';'>
Constraints: <0-3 items separated by ';'>
[/STATE]
