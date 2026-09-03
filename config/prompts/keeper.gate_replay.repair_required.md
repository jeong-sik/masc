---
description: Gate 재생이 provider dispatch 전 운영자 복구를 요구함을 알리는 내부 조각
category: keeper
operator_surface: fragment
template_variables: [approval_id, operation, stage, detail_sha256]
---

Host Gate replay requires operator repair before provider dispatch.
- approval_id: {{approval_id}}
- operation: {{operation}}
- stage: {{stage}}
- detail_sha256: {{detail_sha256}}
The exact wake remains pending; do not execute or request this effect again.
