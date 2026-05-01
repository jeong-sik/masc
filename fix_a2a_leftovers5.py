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

process("lib/dashboard/dashboard_execution_helpers.ml", [
    (r'let tool_audit_snapshot agent_name =\n\s*match task_snapshot, result_snapshot with\n.*?\|\s*None,\s*None\s*->\n\s*let file_snapshot = load_execution_snapshot agent_name in\n(.*?)\}\n',
     r'''let tool_audit_snapshot agent_name =
  let file_snapshot = load_execution_snapshot agent_name in
\1}
''')
])

process("test/test_error_logging_coverage.ml", [
    (r'\s*ignore \(A2a_tools\.submit_heartbeat_result.*?\);\n', '\n')
])

process("test/test_dashboard_mission.ml", [
    (r'\s*\(Lib\.A2a_tools\.submit_heartbeat_result.*?\)\n\s*;\n', '\n')
])

process("lib/dashboard/dashboard_mission_assembly.ml", [
    (r'\s*\|\s*Some task,\s*Some result ->.*?\n\s*\|\s*Some task,\s*None\s*->.*?\n\s*\|\s*None,\s*Some result\s*->.*?\n\s*\|\s*None,\s*None\s*->.*?\n\s*`Null\n', '\n    `Null\n')
])

process("lib/tool_catalog.ml", [
    (r'\s*\|\s*TM\.A2a_delegate\n', '\n')
])

process("lib/operator/operator_control_snapshot.ml", [
    (r'\s*\|\s*Some task,\s*Some result ->.*?\n\s*\|\s*Some task,\s*None\s*->.*?\n\s*\|\s*None,\s*Some result\s*->.*?\n\s*\|\s*None,\s*None\s*->.*?\n\s*let agent_card = `Null in\n', '\n  let agent_card = `Null in\n')
])

print("done")
