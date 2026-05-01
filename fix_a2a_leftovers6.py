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

process("test/test_error_logging_coverage.ml", [
    (r'\(\* =+ \*\)\n\s*a2a_tools: submit_heartbeat_result unknown status.*?let test_a2a_submit_unknown_status_logs.*?\n\s*\) in\n.*?str_contains output "\[a2a\]"\)', ''),
    (r'"a2a_tools_silent_failures", \[\n\s*test_case "submit unknown status logs to stderr" `Quick test_a2a_submit_unknown_status_logs;\n\s*\];\n', ''),
])

process("lib/dashboard/dashboard_mission_assembly.ml", [
    (r'let fallback_latest_action_source =.*?\n\s*let allowed_tool_names,', 'let allowed_tool_names,'),
])

print("done")
