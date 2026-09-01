---
description: Memory continuity canary judge user instruction
category: canary
operator_surface: primary
template_variables: [facts, recall_reply]
---

Facts established earlier in the conversation:
{{facts}}

The assistant's recall reply was:
---
{{recall_reply}}
---

Reply with a single JSON object and nothing else, of the exact shape:
{"per_fact": [{"category": "<category>", "recalled": true|false}, ...], "rationale": "<one short paragraph>"}
Include every category listed above exactly once and no others.
