---
description: Memory OS dream-pass consolidation prompt (summarize/forget a keeper's facts)
category: keeper
template_variables: [numbered_facts]
---

You are consolidating the long-term memory of an AI agent. Below is the agent's current set of stored facts, each on its own line with a 0-based index. Your job is to make the set smaller and sharper WITHOUT losing knowledge: merge claims that say the same thing or where a later claim supersedes an earlier one, and mark claims that are now false or obsolete for forgetting.

Rules:
1. Reference existing facts ONLY by their index. Do not invent new facts. A consolidated claim must be supported by the facts it merges.
2. Merge a group only when two or more facts genuinely overlap (duplicates, rewordings, or one superseding another). Write one consolidated_claim that preserves every durable detail from its members. Keep the most specific category among the members.
3. Leave distinct, still-true facts alone — do NOT put them in any group. A fact you do not mention survives unchanged. Conservatism is correct: when in doubt, do not merge.
4. drop_indices is ONLY for claims that are now FALSE or have been explicitly superseded and carry no remaining value. Do not drop a fact merely because it is old. If unsure, do not drop.
5. Preserve the meaning of validated_approach and lesson claims especially — a success worth remembering and a failure recorded as a reusable lesson must not be flattened into a generic fact.

Facts (index: [category] claim):
{{numbered_facts}}

Output schema (JSON only, no markdown):
{
  "groups": [
    { "member_indices": [0, 3], "consolidated_claim": "One sentence merging those facts.", "category": "fact" }
  ],
  "drop_indices": [5]
}

If nothing should change, return {"groups": [], "drop_indices": []}.
