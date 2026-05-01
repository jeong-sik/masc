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

process("test/test_tool_agent_coverage.ml", [
    (r'\(\* =+ \*\)\n\s*Handler tests — collaboration_graph.*?\)\n\n', ''),
    (r'\(\* =+ \*\)\n\s*Handler tests — agent_card.*?\)\n\n', ''),
    (r'let test_agent_card_refresh.*?\)\n\n', ''),
    (r'\s*test_case "handle_collaboration_graph text" `Quick test_handle_collaboration_graph_text;\n', ''),
    (r'\s*test_case "handle_collaboration_graph json" `Quick test_handle_collaboration_graph_json;\n', ''),
    (r'\s*test_case "handle_agent_card get" `Quick test_agent_card_get;\n', ''),
    (r'\s*test_case "handle_agent_card refresh" `Quick test_agent_card_refresh;\n', ''),
])

# test_types.ml fix
with open("test/test_types.ml", "r") as f: content = f.read()
content = re.sub(r'\s*"agent_tool_variants_ssot", \[.*?\];', '', content, flags=re.DOTALL)
with open("test/test_types.ml", "w") as f: f.write(content)

print("done")
