---
description: 재생 결과 없이 전달된 Gate 승인 해결을 알리는 내부 조각
category: keeper
operator_surface: fragment
template_variables: [approval_id, operation]
---

Gate resolution delivered:
- approval_id: {{approval_id}}
- operation: {{operation}}
- state: host replay outcome was not attached before provider dispatch
The exact approved input remains only in the durable Gate store. Operator repair is required; do not execute or request this effect again.
