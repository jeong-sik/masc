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

process("lib/tool_agent.ml", [
    (r'\|\s*"masc_agents"\s*\|\s*\|\s*"masc_agent_fitness"', '| "masc_agents" | "masc_agent_fitness"'),
])

process("lib/tool_name.ml", [
    (r'\|\s*Add_task -> "masc_add_task"\s*-> "masc_agent_card"', '| Add_task -> "masc_add_task"'),
])

process("lib/tool_catalog.ml", [
    (r'TM\.Agent_card\s*\|\s*', ''),
])

process("lib/tool_dispatch.ml", [
    (r'\s*\|\s*Agent_card\n', '\n'),
])

process("lib/server/server_bootstrap_loops.ml", [
    (r'let hb_reaped = A2a_tools.cleanup_stale_heartbeats.*?let ar_reaped', 'let ar_reaped'),
    (r'if hb_reaped > 0 then.*?\n\s*if ar_reaped', 'if ar_reaped'),
    (r'\s*let buf_reaped =.*?\(\) in', ''),
    (r'\s*let sub_expired =.*?\(\) in', ''),
    (r'if hb_reaped > 0 then\n\s*Log\.Server\.debug "a2a: reaped %d stale heartbeats" hb_reaped;\n', ''),
    (r'if buf_reaped > 0 then\n\s*Log\.Server\.debug "a2a: reaped %d orphan buffers" buf_reaped;\n', ''),
    (r'if sub_expired > 0 then\n\s*Log\.Server\.debug "a2a: reaped %d expired subscriptions" sub_expired;\n', ''),
    (r'\s*if buf_reaped > 0 then.*?\n', '\n'),
    (r'\s*if sub_expired > 0 then.*?\n', '\n'),
])

process("test/test_tool_name.ml", [
    (r'\s*Agent_card;', ''),
])

process("test/test_types.ml", [
    (r'Alcotest\.test_case "agent_card_action witness covers all variants" `Quick \(fun \(\) ->.*?\);\n', ''),
])

process("test/test_tool_agent_coverage.ml", [
    (r'let test_handle_agent_card \(\) =.*?\n\n', ''),
    (r'let test_handle_agent_card_schema_injection \(\) =.*?\n\n', ''),
    (r'\s*test_case "handle_agent_card" `Quick test_handle_agent_card;\n', ''),
    (r'\s*test_case "handle_agent_card schema injection" `Quick test_handle_agent_card_schema_injection;\n', ''),
])

# Remove a2a_tools from tests explicitly if left
process("test/dune", [
    (r'\s*test_agent_card_coverage', ''),
])
if os.path.exists("test/test_agent_card_coverage.ml"):
    os.remove("test/test_agent_card_coverage.ml")

print("done")
