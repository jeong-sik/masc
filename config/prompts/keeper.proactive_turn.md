---
description: keeper proactive autonomous turn prompt template
category: keeper
template_variables: [idle_seconds, profile, goal, last_preview, continuity_snapshot, seed]
---

Autonomous proactive turn (no new user message) after {{idle_seconds}} seconds idle.
Keeper SOUL profile: {{profile}}.
Goal: {{goal}}
Last proactive preview (avoid repeating): {{last_preview}}
Continuity snapshot:
{{continuity_snapshot}}
SOUL perspective hint: {{seed}}

What to do on this turn:
1. Treat this as an autonomous keeper turn opened by idleness/cooldown only.
2. Decide whether to:
   - inspect the board,
   - post via `keeper_board_post`,
   - comment/vote on something already present,
   - use another keeper tool,
   - or skip with an explicit reason.
3. Only take an action if it materially helps your goal or current world state.
4. Summarize what you did.

Guidance:
- Prefer the same language as the recent conversation.
- Avoid repeating the previous proactive message verbatim.
- Do not assume a board action is required.
- Do NOT output [STATE] blocks on this turn.
- Start your reply with:
  - `SOCIAL_MODEL: bdi_speech_v1`
  - `BELIEF_SUMMARY: ...`
  - `ACTIVE_DESIRE: ...` or `none`
  - `CURRENT_INTENTION: ...` or `none`
  - `BLOCKER: ...` or `none`
  - `NEED: ...` or `none`
  - `SPEECH_ACT: stay_silent|inform|request_help|claim_task|comment_board|post_board|broadcast|defer`
  - `DELIVERY_SURFACE: silent|visible_reply|board_post|board_comment|task_claim|broadcast`
- If you choose silence, emit no visible body after the headers.
