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

# Fix dashboard_execution_helpers.ml
process("lib/dashboard/dashboard_execution_helpers.ml", [
    (r'\s*match task_snapshot, result_snapshot with.*?\n\s*\| _ ->\n', '\n'),
])

# Fix dashboard_mission_assembly.ml
process("lib/dashboard/dashboard_mission_assembly.ml", [
    (r'\s*\| Some task, Some result ->.*?\n\s*`Null\n', '\n'),
])

# Fix tool_task.ml syntax error
process("lib/tool_task.ml", [
    (r'\s*\| Error err ->\n\s*Log\.Task\.error "task transition failed: %s" \(Types\.masc_error_to_string err\)\);\n',
     r'\n  | Error err ->\n      Log.Task.error "task transition failed: %s" (Types.masc_error_to_string err);\n'),
    (r'Some \(false, Types\.masc_error_to_string err\)\n', '      Some (false, Types.masc_error_to_string err)\n'),
])

# Fix operator_control_snapshot.ml
process("lib/operator/operator_control_snapshot.ml", [
    (r'\s*\| Some task, Some result ->.*?\n\s*let agent_card = `Null in\n', '\n  let agent_card = `Null in\n'),
])

# Fix mcp_server_eio_execute.ml
process("lib/mcp_server_eio_execute.ml", [
    (r'\s*\| Mod_a2a ->\n', '\n'),
])

# Fix tool_catalog.ml
process("lib/tool_catalog.ml", [
    (r'\s*\( TM\.A2a_delegate\n', '\n'),
])

# Fix test/test_error_logging_coverage.ml
process("test/test_error_logging_coverage.ml", [
    (r'\s*module A2a_tools = Masc_mcp\.A2a_tools\n', '\n'),
    (r'\s*Alcotest\.\(check bool\) "A2a_tools has Log\.error".*?\(has_log_error \(module A2a_tools\)\);\n', '\n'),
])

# Fix test/test_dashboard_mission.ml
process("test/test_dashboard_mission.ml", [
    (r'\s*Lib\.A2a_tools\.emit_heartbeat_task.*?\);\n', '\n'),
    (r'\s*Lib\.A2a_tools\.emit_heartbeat_result.*?\);\n', '\n'),
])

print("done")
