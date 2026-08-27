---
description: One line per other task the keeper holds that names skills, and the tool that serves their bodies
category: keeper
template_variables: [task_id, skill_surfaces]
---

- {{task_id}} (held by you) names exact Skill catalog rows: {{skill_surfaces}}. An `unavailable` row is not callable and carries the diagnostic. Call an `instruction` row's `tool_name` with its exact `reference`, or a `composition` row's `tool_name`, only when that tool is present in the current attempt's tool schema; a runtime may suppress all tools.
