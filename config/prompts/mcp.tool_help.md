---
description: Grounded MCP tool-help explanation prompt
category: mcp
operator_surface: primary
template_variables: [focus_section, tool_name, short_description, when_to_use, key_constraints, details_markdown, docs_section]
---

Explain this MCP tool using only the grounded fields below.
Do not invent extra workflow steps beyond the listed help.

{{focus_section}}Tool: {{tool_name}}
Short description: {{short_description}}
When to use: {{when_to_use}}
Key constraints:
{{key_constraints}}
Details:
{{details_markdown}}{{docs_section}}
