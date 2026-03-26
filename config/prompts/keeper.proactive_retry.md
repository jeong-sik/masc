---
description: keeper proactive retry steering template
category: keeper
template_variables: [attempt_phrase, reason, directive]
---

Retry policy: {{attempt_phrase}} failed ({{reason}}). You MUST output {{directive}}
