import re
with open("lib/dashboard/dashboard_mission_assembly.ml", "r") as f: content = f.read()
content = re.sub(
  r'let allowed_tool_names.*?tool_audit_at =\n\s*\| Some task, Some result ->.*?\n    `Null\n  in',
  '''let allowed_tool_names, latest_tool_names, latest_tool_call_count,
      latest_action_source, tool_audit_source, tool_audit_at =
    ( fallback_allowed,
      fallback_latest_tools,
      fallback_latest_count,
      fallback_latest_action_source,
      Some "file_snapshot",
      match file_snapshot with | Some s -> Some s.Dashboard_execution_helpers.created_at | None -> None )
  in''',
  content, flags=re.MULTILINE|re.DOTALL
)
with open("lib/dashboard/dashboard_mission_assembly.ml", "w") as f: f.write(content)
print("done")
