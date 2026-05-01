import re
import os

def process(filepath, sub_ops):
    if not os.path.exists(filepath): return
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    for search, repl in sub_ops:
        content = re.sub(search, repl, content, flags=re.MULTILINE | re.DOTALL)
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)

# lib/tool_agent.ml
process("lib/tool_agent.ml", [
    (re.escape('type agent_card_action =') + r'.*?Refresh\n\n', ''),
    (re.escape('let agent_card_action_to_string =') + r'.*?None\n\n', ''),
    (re.escape('let agent_card_action_of_string_opt =') + r'.*?None\n\n', ''),
    (re.escape('let all_agent_card_actions = [ Get; Refresh ]\n\n'), ''),
    (re.escape('let valid_agent_card_action_strings =') + r'.*?all_agent_card_actions\n\n', ''),
    (r'\(\* Issue #8501: Variant SSOT for masc_collaboration_graph.*?valid_collaboration_format_strings =.*?\n\n', ''),
    (r'let handle_collaboration_graph ctx args =.*?\n\n', ''),
    (r'let handle_agent_card ctx args =.*?\n\n', ''),
    (r'\s*\| "masc_agent_card" -> Some \(handle_agent_card ctx args\)', ''),
    (r'\s*\| "masc_collaboration_graph" -> Some \(handle_collaboration_graph ctx args\)', ''),
    (r'\s*"masc_agent_card";', ''),
    (r'\s*"masc_collaboration_graph";', ''),
    (r'w_collaboration = 0.1.*?\n', ''),
    (re.escape('+ (weights.w_collaboration *. collaboration)\n'), ''),
    (r'w_collaboration : float;\n', ''),
    (r'let collaboration =.*?\n\s*in', ''),
    (r'handoff, collaboration\) = score_for', 'handoff) = score_for'),
    (r'\(score, completion, reliability, speed, handoff, collaboration\)', '(score, completion, reliability, speed, handoff)'),
    (re.escape('("collaboration", `Float collaboration);\n'), ''),
    (r'\| "masc_agent_card" \| "masc_collaboration_graph" ', ''),
])

# lib/tool_agent.mli
process("lib/tool_agent.mli", [
    (r'type agent_card_action =.*?\n', ''),
    (r'val agent_card_action_to_string :.*?\n', ''),
    (r'val agent_card_action_of_string_opt :.*?\n', ''),
    (r'val all_agent_card_actions :.*?\n', ''),
    (r'val valid_agent_card_action_strings :.*?\n', ''),
    (r'type collaboration_format =.*?\n', ''),
    (r'val collaboration_format_to_string :.*?\n', ''),
    (r'val collaboration_format_of_string_opt :.*?\n', ''),
    (r'val all_collaboration_formats :.*?\n', ''),
    (r'val valid_collaboration_format_strings :.*?\n', ''),
    (r'val handle_agent_card :.*?\n', ''),
    (r'val handle_collaboration_graph :.*?\n', ''),
])

# test/dune
process("test/dune", [
    (r'\s*test_hebbian_eio', ''),
    (r'\s*test_agent_card_coverage', ''),
    (r'\s*test_a2a_tools_coverage', ''),
])

# lib/tool_catalog.ml
process("lib/tool_catalog.ml", [
    (r'\s*\| TN\.Masc TM\.A2a_delegate\n', '\n'),
    (r'\s*\| TN\.Masc TM\.Collaboration_graph\n', '\n'),
    (r'\s*\| TN\.Masc TM\.Agent_card\n', '\n'),
    (r'\| TM\.A2a_delegate ', ''),
    (r'\| TM\.Collaboration_graph ', ''),
    (r'\| TM\.Agent_card ', ''),
])

# lib/tool_name.ml
process("lib/tool_name.ml", [
    (r'\s*\| A2a_delegate', ''),
    (r'\s*\| Collaboration_graph', ''),
    (r'\s*\| Agent_card', ''),
    (r'\s*\| A2a_delegate -> "masc_a2a_delegate"', ''),
    (r'\s*\| Collaboration_graph -> "masc_collaboration_graph"', ''),
    (r'\s*\| Agent_card -> "masc_agent_card"', ''),
    (r'\s*\| "masc_a2a_delegate" -> Some A2a_delegate', ''),
    (r'\s*\| "masc_collaboration_graph" -> Some Collaboration_graph', ''),
    (r'\s*\| "masc_agent_card" -> Some Agent_card', ''),
])

# lib/tool_name.mli
process("lib/tool_name.mli", [
    (r'\s*\| A2a_delegate', ''),
    (r'\s*\| Collaboration_graph', ''),
    (r'\s*\| Agent_card', ''),
])

# lib/tool_dispatch.ml
process("lib/tool_dispatch.ml", [
    (r'\s*\| Mod_a2a', ''),
    (r'\s*\| A2a_delegate', ''),
    (r'\s*\| Collaboration_graph', ''),
    (r'\s*\| Agent_card', ''),
])

print("done wipe a2a collab final")
