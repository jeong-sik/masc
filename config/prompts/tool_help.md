---
description: MCP tool-help registry — shared fallback prose and the markdown scaffold every help entry renders through
category: tool
operator_surface: fragment
template_variables: []
---
### prompt_hint.tool_help
Use prompt 'tool_help' when the caller needs a guided explanation.

### when_to_use.tool_help
Use when you need canonical guidance for a specific MASC tool.

### when_to_use.generic
Use when you need this tool's canonical action.

### constraint.hidden
Hidden from the default tool list.

### constraint.placeholder
Placeholder implementation; not a truthful default surface.

### constraint.simulation
Simulation-backed implementation.

### constraint.adapter
Compatibility or adapter surface.

### short_description.empty
MASC tool.

### entry.header (vars: name, short_description, visibility, lifecycle)
# {{name}}

{{short_description}}

- visibility: `{{visibility}}`
- lifecycle: `{{lifecycle}}`

### entry.when_to_use (vars: when_to_use)
## When To Use

{{when_to_use}}

### entry.key_constraints (vars: constraints)
## Key Constraints

{{constraints}}

### entry.details (vars: details_markdown)
## Details

{{details_markdown}}

### entry.docs (vars: docs)
## Docs

{{docs}}

### entry.prompt_hints (vars: prompt_hints)
## Prompt Hints

{{prompt_hints}}

### entry.examples (vars: examples)
## Examples

{{examples}}

### entry.alternatives (vars: alternatives)
## Alternatives

{{alternatives}}

### index.header
# Tool Help Index

Canonical help entries for MCP-exposed MASC tools.
