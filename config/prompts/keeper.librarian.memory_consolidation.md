---
description: Memory OS consolidation prompt (summarize/forget a keeper's facts)
category: keeper
template_variables: [numbered_facts]
---

You are consolidating the long-term memory of an AI agent. Below is the agent's current set of stored facts, each on its own line with a 0-based index. Your job is to make the set smaller and sharper WITHOUT losing knowledge: merge claims that say the same thing or where a later claim supersedes an earlier one, and mark claims that are now false or obsolete for forgetting.

Rules:
1. Reference existing facts ONLY by their index. Do not invent new facts. A consolidated claim must be supported by the facts it merges.
2. Merge a group only when two or more facts genuinely overlap (duplicates, rewordings, or one superseding another). Write one consolidated_claim that preserves every durable detail from its members. Keep the most specific category among the members.
3. kind= and until= (shown on each line; a line without until= has no expiry) are context for YOUR judgement, not a constraint on grouping. You may merge across different kinds and different expiry values when the claims genuinely say the same thing. The merged row inherits the earliest until= among its members, and keeps the kind= tag only when every member shares it. Use these fields to decide whether two claims mean the same thing — a claim that expires next week and one with no expiry are often not the same claim — but do not split a genuine duplicate group merely because the values differ.
4. Leave distinct, still-true facts alone — do NOT put them in any group. A fact you do not mention survives unchanged. Conservatism is correct: when in doubt, do not merge.
5. drop_indices is ONLY for claims that are now FALSE or have been explicitly superseded and carry no remaining value. Do not drop a fact merely because it is old. If unsure, do not drop.
6. Preserve the meaning of validated_approach and lesson claims especially — a success worth remembering and a failure recorded as a reusable lesson must not be flattened into a generic fact.

Facts (index: [category] (kind=…, optional until=…) claim):
{{numbered_facts}}

Output schema (JSON only, no markdown):
Return exactly one JSON object. Do not wrap the object in markdown fences, prose, arrays, JSON strings, XML tags, or thinking text.

{
  "groups": [
    { "member_indices": [0, 3], "consolidated_claim": "One sentence merging those facts.", "category": "fact" }
  ],
  "drop_indices": [5]
}

If nothing should change, return {"groups": [], "drop_indices": []}.
