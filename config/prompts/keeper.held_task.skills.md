---
description: 보유 중인 다른 Task별 Skill과 본문 조회 도구를 한 줄로 조립하는 내부 조각
category: keeper
operator_surface: fragment
template_variables: [task_id, skill_surfaces]
---

- {{task_id}} (held by you) names exact Skill catalog rows: {{skill_surfaces}}. An `unavailable` row is not callable and carries the diagnostic. Call an `instruction` row's `tool_name` with its exact `reference`, or a `composition` row's `tool_name`, only when that tool is present in the current attempt's tool schema; a runtime may suppress all tools.
