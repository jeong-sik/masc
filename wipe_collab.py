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

# tool_name.ml
process("lib/tool_name.ml", [
    (r'\s*\| Collaboration_graph', ''),
    (r'\s*\| Collaboration_graph -> "masc_collaboration_graph"', ''),
    (r'\s*\| "masc_collaboration_graph" -> Some Collaboration_graph', ''),
])

# tool_name.mli
process("lib/tool_name.mli", [
    (r'\s*\| Collaboration_graph', ''),
])

# tool_agent.ml
process("lib/tool_agent.ml", [
    (r'type collaboration_format =.*?\n\n', ''),
    (r'let collaboration_format_to_string.*?\n\n', ''),
    (r'let collaboration_format_of_string_opt.*?\n\n', ''),
    (r'let all_collaboration_formats =.*?\n', ''),
    (r'let valid_collaboration_format_strings =.*?\n\n', ''),
    (r'let handle_collaboration_graph.*?\n\n', ''),
    (r'\| "masc_collaboration_graph" -> Some \(handle_collaboration_graph ctx args\)\n', ''),
    (r'\| "masc_collaboration_graph" ', ''),
])

# tool_agent.mli
process("lib/tool_agent.mli", [
    (r'type collaboration_format = Text \| Json\n', ''),
    (r'val collaboration_format_to_string : collaboration_format -> string\n', ''),
    (r'val collaboration_format_of_string_opt : string -> collaboration_format option\n', ''),
    (r'val all_collaboration_formats : collaboration_format list\n', ''),
    (r'val valid_collaboration_format_strings : string list\n', ''),
    (r'val handle_collaboration_graph : context -> Yojson\.Safe\.t -> bool \* string\n', ''),
])

# tool_catalog.ml
process("lib/tool_catalog.ml", [
    (r'\| TM\.Collaboration_graph ', ''),
    (r'\s*\| TN\.Masc TM\.Collaboration_graph\n', '\n'),
])

# tool_schemas_agent.ml
process("lib/tool_schemas/tool_schemas_agent.ml", [
    (r'let collaboration_format_enum_strings = \[ "text"; "json" \]\n', ''),
    (r'\s*\{\n\s*name = "masc_collaboration_graph";.*?\n\s*\};\n', '\n'),
])

# tool_schemas_agent.mli
process("lib/tool_schemas/tool_schemas_agent.mli", [
    (r'val collaboration_format_enum_strings : string list\n', ''),
    (r'\[masc_collaboration_graph\], ', ''),
])

# test/test_tool_name.ml
process("test/test_tool_name.ml", [
    (r'Collaboration_graph;\s*', ''),
])

# test/test_tool_agent_coverage.ml
process("test/test_tool_agent_coverage.ml", [
    (r'let test_handle_collaboration_graph_text.*?\(ok, msg\)\);\n', ''),
    (r'let test_handle_collaboration_graph_json.*?\(ok, msg\)\);\n', ''),
    (r'test_case "handle_collaboration_graph text" `Quick test_handle_collaboration_graph_text;\n', ''),
    (r'test_case "handle_collaboration_graph json" `Quick test_handle_collaboration_graph_json;\n', ''),
])

# tool_dispatch.ml
process("lib/tool_dispatch.ml", [
    (r'\s*\| Collaboration_graph', ''),
])

print("done wipe collab")
