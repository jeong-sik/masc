import re
import os

with open("lib/tool_agent.ml", "r") as f: content = f.read()

# Remove types and helpers at top
content = re.sub(r'type agent_card_action =.*?let valid_agent_card_action_strings =.*?\n\n', '', content, flags=re.DOTALL)
content = re.sub(r'\(\* Issue #8501: Variant SSOT for masc_collaboration_graph.*?let valid_collaboration_format_strings =.*?\n\n', '', content, flags=re.DOTALL)

# Fix handle_agent_fitness
content = re.sub(r'let max_collabs.*?in\n', '', content)
content = re.sub(r'let \(score, completion, reliability, speed, handoff, collaboration\) = score_for ~min_avg ~max_collabs:max_col metrics in', 
                 'let (score, completion, reliability, speed, handoff) = score_for ~min_avg metrics in', content)
content = re.sub(r'\("collaboration", `Float collaboration\);', '', content)

# Remove handlers
content = re.sub(r'let handle_collaboration_graph ctx args =.*?\)\n\n', '', content, flags=re.DOTALL)
content = re.sub(r'let handle_agent_card _ctx args =.*?\)\n\n', '', content, flags=re.DOTALL)

# Fix dispatch
content = re.sub(r'\| "masc_collaboration_graph" -> Some \(handle_collaboration_graph ctx args\)\n', '', content)
content = re.sub(r'\| "masc_agent_card" -> Some \(handle_agent_card ctx args\)\n', '', content)

# Fix _tool_spec lists
content = re.sub(r'"masc_agent_card";?', '', content)
content = re.sub(r'\| "masc_agent_card" ', '', content)
content = re.sub(r'\| "masc_collaboration_graph" ', '', content)

# Fix score_for function
content = re.sub(r'let collaboration =.*?in\n', '', content, flags=re.DOTALL)
content = re.sub(r'\+\. \(weights.w_collaboration \*\. collaboration\)', '', content)
content = re.sub(r'\(score, completion, reliability, speed, handoff, collaboration\)', '(score, completion, reliability, speed, handoff)', content)

# Fix fitness_weights type if exists
content = re.sub(r'w_collaboration : float;', '', content)
content = re.sub(r'w_collaboration = 0\.1;', '', content)

with open("lib/tool_agent.ml", "w") as f: f.write(content)
print("done")
