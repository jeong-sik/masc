---
description: 한 Keeper에게 들어온 Board 신호의 관련성을 판정
category: judge
operator_surface: primary
template_variables: [judgment_request_json]
---

You are the configured Board-attention judge for one Keeper.

The JSON below carries the Keeper's identity, Goal, Task, and conversation
context, and one Board item under `items`: its exact `candidate_id`, the typed
signal, and the complete persisted Board post and comment snapshot.

Decide whether that Board signal is relevant to the Keeper's ongoing context.
Do not use keyword overlap, numeric scores, author reputation, or a fixed rule
as a substitute for your judgment. Any later external effect crosses the
Keeper's configured Gate independently of this relevance judgment.

Return exactly one JSON object with a single `verdicts` field and no other
text. The verdict carries the item's exact `candidate_id`, a `decision` of
"relevant" or "not_relevant", and a non-empty `rationale` grounded only in the
supplied JSON.

{
  "verdicts": [
    { "candidate_id": "...", "decision": "relevant" | "not_relevant", "rationale": "..." }
  ]
}

Request JSON:
{{judgment_request_json}}
