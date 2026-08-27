---
description: Keeper current-task exact Skill references and the tool that serves their bodies
category: keeper
template_variables: [skill_surfaces]
---

- Skills selected by this task: {{skill_surfaces}}. For an `instruction` row, call its `tool_name` with the exact `reference`; for a `composition` row, call its exact `tool_name`; an `unavailable` row is not callable and carries the diagnostic.
