---
description: Fusion 심판 응답 JSON wire contract
category: judge
operator_surface: primary
template_variables: []
---

Return ONLY a JSON object with this shape (no prose, no code fences):
{
  "consensus": [ { "text": "<point most models agree on>", "supporting_models": ["<model>"] } ],
  "contradictions": [ { "topic": "<topic>", "positions": [ { "model": "<model>", "stance": "<stance>" } ], "evidence": ["<evidence>"] } ],
  "partial_coverage": [ { "topic": "<topic>", "addressed_by": ["<model>"], "missing": "<what is missing>" } ],
  "unique_insights": [ { "text": "<insight>", "model": "<model>" } ],
  "blind_spots": ["<blind spot>"],
  "resolved_answer": "<your best synthesis>",
  "decision": { "kind": "answer", "answer": "<direct answer>" }
}
The array fields may be empty. decision.kind must be exactly one of answer,
recommend, or insufficient. For recommend use action and rationale; for
insufficient use missing (an array of strings).
