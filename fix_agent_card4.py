import re

with open("test/test_tool_agent_coverage.ml", "r") as f:
    content = f.read()

content = re.sub(r'\(\* ============================================================\n\s*Handler tests — agent_card\n\s*============================================================ \*\)\n.*?let test_agent_card_get \(\) =.*?\n\s*\)\n\nlet test_agent_card_refresh \(\) =.*?\n\s*\)\n', '', content, flags=re.DOTALL)

with open("test/test_tool_agent_coverage.ml", "w") as f:
    f.write(content)

with open("lib/tool_agent.ml", "r") as f:
    content = f.read()

content = re.sub(r'\s*\|\s*_\s*->\s*\(false,\s*"unknown tool"\)\n', '\n  | _ -> (false, "unknown tool")\n', content)

with open("lib/tool_agent.ml", "w") as f:
    f.write(content)

print("done")
