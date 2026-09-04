---
description: agent-core tool-loop wording — installed into Agent_core.Tool_guidance_text by the host at prompt-init time; agent_core stays config-free
category: tool
operator_surface: fragment
---
### unknown_tool.not_found (vars: requested)
Tool not found: {{requested}}

### unknown_tool.not_found_no_tools (vars: requested)
Tool not found: {{requested}}. No tools are registered

### unknown_tool.closest_registered (vars: name)
Closest registered name: {{name}}.

### unknown_tool.extra_characters (vars: prefix_quoted)
The name carries extra characters after {{prefix_quoted}}; send the tool name alone and put arguments in the input object.

### unknown_tool.not_bare_with_closest (vars: name)
The name is not a bare identifier (closest registered name: {{name}}); send the registered tool name alone and put arguments in the input object.

### unknown_tool.not_bare
The name is not a bare identifier; send the registered tool name alone and put arguments in the input object.

### handoff.description (vars: name, description)
Hand off to {{name}}: {{description}}

### handoff.prompt_param_description
Instructions for the sub-agent

### agent_tool.prompt_param_description
The prompt to send to the agent
