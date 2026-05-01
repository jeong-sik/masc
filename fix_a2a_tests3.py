import re

with open("test/test_dashboard_mission.ml", "r") as f:
    content = f.read()

content = re.sub(r'\s*Lib\.A2a_tools\.emit_heartbeat_task.*?;\n\s*ignore\s*\(Lib\.A2a_tools\.submit_heartbeat_result.*?~decision_confidence:0\.61\n\s*\(\)\);\n', '\n', content, flags=re.DOTALL)
content = re.sub(r'\s*Lib\.A2a_tools\.emit_heartbeat_task.*?\(\);\n', '\n', content, flags=re.DOTALL)
content = re.sub(r'\s*ignore\s*\(Lib\.A2a_tools\.submit_heartbeat_result.*?\(\)\);\n', '\n', content, flags=re.DOTALL)

with open("test/test_dashboard_mission.ml", "w") as f:
    f.write(content)
print("done")
