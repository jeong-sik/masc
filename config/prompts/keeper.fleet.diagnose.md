---
description: Fleet 진단 요청의 운영 안내
category: keeper
operator_surface: primary
template_variables: [keeper_name, reason]
---

Fleet FSM supervised resolve request for {{keeper_name}}.
Reason: {{reason}}.
Inspect the latest runtime evidence, distinguish configuration/tool-contract blockers from restartable runtime stalls, and reply with the safest next operator action. Do not self-restart.
