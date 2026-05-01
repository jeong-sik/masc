import re

with open("test/test_error_logging_coverage.ml", "r") as f:
    content = f.read()

content = re.sub(r'\s*ignore\s*\(A2a_tools\.submit_heartbeat_result.*?\(\)\);\n', '\n', content, flags=re.DOTALL)

with open("test/test_error_logging_coverage.ml", "w") as f:
    f.write(content)

with open("lib/dashboard/dashboard_mission_assembly.ml", "r") as f:
    content = f.read()

content = re.sub(r'let allowed_tool_names, latest_tool_names, latest_tool_call_count,.*?\n\s*\| Some task, Some result ->\n\s*`Null\n\s*in',
     r'''let allowed_tool_names, latest_tool_names, latest_tool_call_count,
      latest_action_source, tool_audit_source, tool_audit_at =
    ( fallback_allowed, fallback_latest_tools, fallback_latest_count, fallback_latest_action_source, Some "file_snapshot", Option.map (fun (s: Dashboard_execution_helpers.execution_snapshot) -> s.Dashboard_execution_helpers.created_at) file_snapshot )
  in''', content, flags=re.DOTALL)

content = re.sub(r'let allowed_tool_names, latest_tool_names, latest_tool_call_count,.*?\n\s*\| Some task, Some result ->.*?\n\s*`Null\n\s*in',
     r'''let allowed_tool_names, latest_tool_names, latest_tool_call_count,
      latest_action_source, tool_audit_source, tool_audit_at =
    ( fallback_allowed, fallback_latest_tools, fallback_latest_count, fallback_latest_action_source, Some "file_snapshot", Option.map (fun (s: Dashboard_execution_helpers.execution_snapshot) -> s.Dashboard_execution_helpers.created_at) file_snapshot )
  in''', content, flags=re.DOTALL)

with open("lib/dashboard/dashboard_mission_assembly.ml", "w") as f:
    f.write(content)

print("done")
