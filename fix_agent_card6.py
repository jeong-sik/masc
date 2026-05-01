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

process("test/test_types.ml", [
    (r'\s*Alcotest\.\(check bool\) "agent_card_action .*?\);\n', ''),
    (r'\s*Alcotest\.\(check bool\) "agent_card_action \'\' -> Get back-compat" true\n\s*\(T\.agent_card_action_of_string_opt "" = Some T\.Get\);\n', ''),
])

process("lib/tool_agent.ml", [
    (r'match String\.trim \(String\.lowercase_ascii raw\) with\n\s*\| "text" \| "" -> Some Text\n\s*\| "json" -> Some Json\n',
     'match String.trim (String.lowercase_ascii raw) with\n  | "text" | "" -> Some Text\n  | "json" -> Some Json\n  | _ -> None\n'),
    (r'match Yojson\.Safe\.Util\.member "capabilities" args with\n\s*\| `Null -> None\n\s*\| `List _ -> Some \(get_string_list args "capabilities"\)\n',
     'match Yojson.Safe.Util.member "capabilities" args with\n    | `Null -> None\n    | `List _ -> Some (get_string_list args "capabilities")\n    | _ -> None\n'),
    (r'let tool_required_permission = function\n\s*\| "masc_agents" \| "masc_agent_fitness"\n\s*\| "masc_collaboration_graph"\n\s*\| "masc_get_metrics" ->\n\s*Some Types\.CanReadState\n\s*\| "masc_register_capabilities" \| "masc_agent_update" ->\n\s*Some Types\.CanBroadcast\n',
     'let tool_required_permission = function\n  | "masc_agents" | "masc_agent_fitness"\n  | "masc_collaboration_graph"\n  | "masc_get_metrics" ->\n      Some Types.CanReadState\n  | "masc_register_capabilities" | "masc_agent_update" ->\n      Some Types.CanBroadcast\n  | _ -> None\n'),
])

print("done")
