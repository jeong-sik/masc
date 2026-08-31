---
description: 메타데이터의 현재 Task가 권위 있는 backlog에 없음을 알리는 내부 조각
category: keeper
operator_surface: fragment
template_variables: [task_id]
---

### Current Task
- Keeper metadata references {{task_id}}, but that task is absent from the authoritative backlog. Do not infer or invent task details.
