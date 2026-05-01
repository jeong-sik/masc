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
    (r'let test_handle_agent_card.*?\(ok, msg\)\);\n', ''),
])

process("test/test_types.ml", [
    (r'\s*Alcotest\.test_case "agent_card_action witness covers all variants" `Quick \(fun \(\) ->.*?Alcotest\.\(check int\) "count" 2 \(List\.length T\.valid_agent_card_action_strings\)\);', '')
])

process("lib/tool_agent.ml", [
    (r'\|\s*_\s*->\s*None', '| _ -> (false, "unknown tool")')
])

process("lib/server/server_bootstrap_loops.ml", [
    (r'\s*if hb_reaped > 0 then\n\s*Log\.Server\.debug "a2a: reaped %d stale heartbeats" hb_reaped;\n', ''),
    (r'\s*let hb_reaped =.*?\(\) in\n', ''),
])

print("done")
