---
description: 현재 Task 자체를 읽지 못했음을 알리는 내부 관측 조각
category: keeper
operator_surface: fragment
template_variables: [task_id]
---

### Current Task
- Task {{task_id}} could not be observed because the backlog is unavailable. This does not mean the task is absent; preserve its ownership state.
