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
    (r'\s*match task_snapshot, result_snapshot with\n\s*\| Some task, Some result ->.*?\n\s*\| _ ->\n\s*let execution_status =.*?\n\s*in',
     '\n  let execution_status = "ok" in')
])

process("lib/dashboard/dashboard_mission_assembly.ml", [
    (r'\s*\| Some task, Some result ->.*?\n\s*\| Some task, None ->.*?\n\s*\| None, Some result ->.*?\n\s*\| None, None ->.*?\n\s*`Null\n',
     '\n    `Null\n'),
    (r'let allowed_tool_names, latest_tool_names, latest_tool_call_count,.*?\n\s*tool_audit_source, tool_audit_at =\n\s*`Null\n\s*in',
     r'''let allowed_tool_names, latest_tool_names, latest_tool_call_count,
      latest_action_source, tool_audit_source, tool_audit_at =
    ( fallback_allowed, fallback_latest_tools, fallback_latest_count, fallback_latest_action_source, Some "file_snapshot", Option.map (fun s -> s.Dashboard_execution_helpers.created_at) file_snapshot )
  in''')
])

process("lib/operator/operator_control_snapshot.ml", [
    (r'\s*\| Some task, Some result ->.*?\n\s*\| Some task, None ->.*?\n\s*\| None, Some result ->.*?\n\s*\| None, None ->.*?\n\s*let agent_card = `Null in',
     '\n  let agent_card = `Null in')
])

process("lib/mcp_server_eio_execute.ml", [
    (r'\s*Tool_a2a\.dispatch \{ Tool_a2a\.config; agent_name \} ~name ~args:coerced_args\n', '\n')
])

process("lib/tool_task.ml", [
    (r'match result with\n\s*\| Ok _ ->\n\s*Some \(true, Printf\.sprintf "Task %s %s successfully\\n" task_id action_s\)\n\s*\| Error err ->\n\s*Log\.Task\.error "task transition failed: %s" \(Types\.masc_error_to_string err\);\n\s*Some \(false, Types\.masc_error_to_string err\)',
     r'''(match result with
  | Ok _ ->
      Some (true, Printf.sprintf "Task %s %s successfully\n" task_id action_s)
  | Error err ->
      Log.Task.error "task transition failed: %s" (Types.masc_error_to_string err);
      Some (false, Types.masc_error_to_string err))''')
])

process("test/test_dashboard_mission.ml", [
    (r'\s*ignore \(Lib\.A2a_tools\.submit_heartbeat_result.*?\);\n', '\n')
])

process("test/test_error_logging_coverage.ml", [
    (r'\s*ignore \(A2a_tools\.submit_heartbeat_result.*?\);\n', '\n')
])

process("lib/tool_catalog.ml", [
    (r'\|\s*TM\.A2a_delegate', '')
])

print("done")
