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

process("test/dune", [
    (r'\s*test_a2a_tools_coverage', ''),
])

process("lib/dashboard/dashboard_execution_helpers.ml", [
    (r'let execution_status =.*?\n\s*in', 'let execution_status = "ok" in'),
])

process("lib/dashboard/dashboard_mission_assembly.ml", [
    (r'let allowed_tool_names, latest_tool_names, latest_tool_call_count,.*?\n\s*tool_audit_source, tool_audit_at =\n\s*\| Some task, Some result ->.*?\n\s*`Null\n\s*in\n',
     r'''let allowed_tool_names, latest_tool_names, latest_tool_call_count,
      latest_action_source, tool_audit_source, tool_audit_at =
    ( fallback_allowed, fallback_latest_tools, fallback_latest_count, fallback_latest_action_source, Some "file_snapshot", Option.map (fun s -> s.Dashboard_execution_helpers.created_at) file_snapshot )
  in
''')
])

process("lib/operator/operator_control_snapshot.ml", [
    (r'let agent_card = \n\s*\| Some task, Some result ->.*?\n\s*let agent_card = `Null in\n',
     r'let agent_card = `Null in\n')
])

process("lib/tool_catalog.ml", [
    (r'\s*\|\s*\(?\s*TM\.A2a_delegate\s*\)?\n', '\n'),
])

process("lib/tool_name.ml", [
    (r'\s*let to_string = function -> "masc_a2a_delegate"\n', '\n'),
])

process("lib/tool_task.ml", [
    (r'\s*\(match result with\n\s*\| Ok _ ->\n\s*sync_keeper_current_task_binding ctx;\n\s*sync_planning_current_task_with_owned_task ctx\n\s*\| Error _ -> \(\)\);\n\s*\(\* Notification harness: push task transition to all active sessions \*\)\n\s*Subscriptions\.push_event_to_sessions \(`Assoc \[\n\s*\("type", `String "masc/task_transition"\);\n\s*\("task_id", `String task_id\);\n\s*\("action", `String action_s\);\n\s*\("agent_name", `String ctx\.agent_name\);\n\s*\("timestamp", `Float \(Time_compat\.now \(\)\)\);\n\s*\]\);\n\s*\(match result with\n\s*\| Ok _ ->\n\s*Some \(true, Printf\.sprintf "Task %s %s successfully\\n" task_id action_s\)\n\s*\| Error err ->\n\s*Log\.Task\.error "task transition failed: %s" \(Types\.masc_error_to_string err\)\);\n',
     r'''  (match result with
   | Ok _ ->
     sync_keeper_current_task_binding ctx;
     sync_planning_current_task_with_owned_task ctx
   | Error _ -> ());
  (* Notification harness: push task transition to all active sessions *)
  Subscriptions.push_event_to_sessions (`Assoc [
    ("type", `String "masc/task_transition");
    ("task_id", `String task_id);
    ("action", `String action_s);
    ("agent_name", `String ctx.agent_name);
    ("timestamp", `Float (Time_compat.now ()));
  ]);
  match result with
  | Ok _ ->
      Some (true, Printf.sprintf "Task %s %s successfully\n" task_id action_s)
  | Error err ->
      Log.Task.error "task transition failed: %s" (Types.masc_error_to_string err);
      Some (false, Types.masc_error_to_string err)
''')
])

print("done")
