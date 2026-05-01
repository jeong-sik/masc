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

# lib/coord.ml
process("lib/coord.ml", [
    (r'\(try Hebbian_eio\.strengthen.*?\);', ''),
    (r'\(try Hebbian_eio\.weaken.*?\);', ''),
])

# lib/server/server_bootstrap_loops.ml
process("lib/server/server_bootstrap_loops.ml", [
    (r'Hebbian_eio\.start_consolidation_fiber.*?\n', ''),
])

# lib/server/server_dashboard_http.ml
process("lib/server/server_dashboard_http.ml", [
    (r'let g = Hebbian_eio\.load_graph config in\n\s*Hebbian_eio\.graph_to_json g', '`Null'),
])

# test_tool_agent_coverage.ml
process("test/test_tool_agent_coverage.ml", [
    (r'let test_handle_collaboration_graph_text.*?\(ok, msg\)\);\n\s*\)\n\n', ''),
    (r'let test_handle_collaboration_graph_json.*?\(ok, msg\)\);\n\s*\)\n\n', ''),
    (r'let test_handle_agent_card_get.*?\(ok, msg\)\);\n\s*\)\n\n', ''),
    (r'let test_handle_agent_card_refresh.*?\(ok, msg\)\);\n\s*\)\n\n', ''),
    (r'\("collaboration_graph", \[.*?\]\);', ''),
    (r'\("agent_card", \[.*?\]\);', ''),
])

print("done wipe a2a final")
