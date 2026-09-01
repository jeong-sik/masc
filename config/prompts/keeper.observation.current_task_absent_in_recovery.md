---
description: 복구 스냅샷에 현재 Task가 없어 부재를 단정할 수 없음을 알리는 내부 조각
category: keeper
operator_surface: fragment
template_variables: [task_id]
---

### Current Task
- Keeper metadata references {{task_id}}, but it was not found in the recovery snapshot. The primary backlog is unavailable, so absence is not authoritative.
