---
description: 현재 Task의 정확한 Skill 참조와 본문 조회 도구를 조립하는 내부 조각
category: keeper
operator_surface: fragment
template_variables: [skill_surfaces]
---

- Exact Skill catalog rows selected by this task: {{skill_surfaces}}. An `unavailable` row is not callable and carries the diagnostic. Call an `instruction` row's `tool_name` with its exact `reference`, or a `composition` row's `tool_name`, only when that tool is present in the current attempt's tool schema; a runtime may suppress all tools.
