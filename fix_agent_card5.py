import re

with open("test/test_types.ml", "r") as f:
    content = f.read()

content = re.sub(r'\s*Alcotest\.test_case "agent_card_action.*?\n\s*Alcotest\.\(check bool\) "none".*?None\);\n\s*\);\n', '\n', content, flags=re.DOTALL)
content = re.sub(r'\s*Alcotest\.test_case "agent_card_action string conversion" `Quick \(fun \(\) ->.*?None\);\n\s*\);\n', '', content, flags=re.DOTALL)

with open("test/test_types.ml", "w") as f:
    f.write(content)

with open("test/test_tool_agent_coverage.ml", "r") as f:
    content = f.read()

content = re.sub(r'\s*Alcotest\.test_case "get action" `Quick test_agent_card_get;\n\s*Alcotest\.test_case "refresh action" `Quick test_agent_card_refresh;\n', '\n', content)

with open("test/test_tool_agent_coverage.ml", "w") as f:
    f.write(content)

with open("lib/tool_agent.ml", "r") as f:
    content = f.read()

# Remove the bad match arm
content = re.sub(r'\s*\|\s*_\s*->\s*\(false,\s*"unknown tool"\)\n', '\n', content)

with open("lib/tool_agent.ml", "w") as f:
    f.write(content)

with open("lib/server/server_bootstrap_loops.ml", "r") as f:
    content = f.read()

content = re.sub(r'\s*\(\*\s*A2A:\s*remove heartbeat snapshots.*?\s*let active_agents =.*?Agent_registry_eio\.list_active.*?\(\)\)\n\s*in\n', '\n', content, flags=re.DOTALL)

with open("lib/server/server_bootstrap_loops.ml", "w") as f:
    f.write(content)

print("done")
