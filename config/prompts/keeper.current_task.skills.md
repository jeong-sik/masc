---
description: Keeper current-task exact Skill references and the tool that serves their bodies
category: keeper
template_variables: [skill_surfaces]
---

- Exact Skill catalog rows selected by this task: {{skill_surfaces}}. An `unavailable` row is not callable and carries the diagnostic. Call an `instruction` row's `tool_name` with its exact `reference`, or a `composition` row's `tool_name`, only when that tool is present in the current attempt's tool schema; a runtime may suppress all tools.
