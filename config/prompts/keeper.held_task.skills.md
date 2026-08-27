---
description: One line per other task the keeper holds that names skills, and the tool that serves their bodies
category: keeper
template_variables: [task_id, skill_surfaces]
---

- {{task_id}} (held by you) names skills: {{skill_surfaces}}. For an `instruction` row, call its `tool_name` with the exact `reference`; for a `composition` row, call its exact `tool_name`; an `unavailable` row is not callable and carries the diagnostic.
