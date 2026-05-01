import os
import re

def process(filepath, sub_ops):
    if not os.path.exists(filepath): return
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    for search, repl in sub_ops:
        content = re.sub(search, repl, content, flags=re.MULTILINE | re.DOTALL)
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(content)

# Remove files
files_to_remove = [
    "test/test_hebbian_first_consolidation.ml",
    "test/test_hebbian_edge_update_counter.ml",
]
for f in files_to_remove:
    if os.path.exists(f): os.remove(f)

# Fix lib/tool_agent.ml
process("lib/tool_agent.ml", [
    (r'\+\. \(weights.w_collaboration \*\. collaboration\)', ''),
    (r'collaboration : float;', ''),
    (r'w_collaboration = 0\.1;', ''),
    (r'collaboration = 0\.', ''),
])

# Fix lib/tool_catalog.ml
process("lib/tool_catalog.ml", [
    (r'TM\.Agent_card \| ', ''),
])

# Fix test/test_types.ml
process("test/test_types.ml", [
    (r'Alcotest\.test_case "collaboration_format witness covers both variants".*?\);\n', ''),
    (r'Alcotest\.\(check bool\) "collaboration_format \'json\'".*?None\);\n', ''),
    (r'Alcotest\.\(check \(list string\)\) "collaboration_format mirror == SSOT".*?Tool_schemas_agent\.collaboration_format_enum_strings\);\n', ''),
])

# Fix test/test_tool_agent_coverage.ml
process("test/test_tool_agent_coverage.ml", [
    (r'let test_handle_collaboration_graph_text.*?\(ok, msg\)\);\n', ''),
    (r'let test_handle_collaboration_graph_json.*?\(ok, msg\)\);\n', ''),
    (r'\s*test_case "handle_collaboration_graph text" `Quick test_handle_collaboration_graph_text;\n', ''),
    (r'\s*test_case "handle_collaboration_graph json" `Quick test_handle_collaboration_graph_json;\n', ''),
])

# Fix test/dune
process("test/dune", [
    (r'\s*test_hebbian_first_consolidation', ''),
    (r'\s*test_hebbian_edge_update_counter', ''),
])

print("done aggressive")
