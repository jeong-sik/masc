---
description: MCP tool_help 프롬프트 본문 조립 조각 — prompts/get 시점에 렌더되는 그라운디드 설명 요청문
category: mcp
operator_surface: fragment
---
### intro
Explain this MCP tool using only the grounded fields below.
Do not invent extra workflow steps beyond the listed help.

### focus_row (vars: focus)
Focus: {{focus}}

### tool_section (vars: name, short_description, when_to_use)
Tool: {{name}}
Short description: {{short_description}}
When to use: {{when_to_use}}
Key constraints:

### constraint_row (vars: item)
- {{item}}

### details_section (vars: details_markdown)
Details:
{{details_markdown}}

### docs_heading
Docs:

### doc_ref_row (vars: item)
- {{item}}
