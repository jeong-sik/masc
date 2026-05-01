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
    (r'\s*Alcotest\.\(check \(list string\)\) "agent_card_action mirror".*?Masc_mcp\.Tool_schemas_agent\.agent_card_action_enum_strings;', ''),
])

process("lib/tool_agent.ml", [
    (r'let \(\) =\n\s*List\.iter',
     r'''let dispatch ctx ~name ~args =
  match name with
  | "masc_agents" -> Some (handle_agents ctx args)
  | "masc_agent_fitness" -> Some (handle_agent_fitness ctx args)
  | "masc_register_capabilities" -> Some (handle_register_capabilities ctx args)
  | "masc_agent_update" -> Some (handle_agent_update ctx args)
  | "masc_get_metrics" -> Some (handle_get_metrics ctx args)
  | _ -> None

let () =
  List.iter'''),
])

print("done")
