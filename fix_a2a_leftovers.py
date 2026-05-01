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

# Delete a2a tests
tests_to_delete = [
    "test/test_a2a_tools_coverage.ml",
    "test/test_agent_card_coverage.ml",
]
for t in tests_to_delete:
    if os.path.exists(t): os.remove(t)

# Fix lib/tool_task.ml
process("lib/tool_task.ml", [
    (r'\s*A2a_tools\.notify_event.*?~data:\(`Assoc \[\n.*?\]\)\n', '\n'),
])

# Fix lib/tool_inline_dispatch_comm.ml
process("lib/tool_inline_dispatch_comm.ml", [
    (r'\s*A2a_tools\.notify_event.*?~data:\(`Assoc \[\n.*?\]\)\n', '\n'),
])

# Fix lib/tool_inline_dispatch_extra.ml
process("lib/tool_inline_dispatch_extra.ml", [
    (r'\s*A2a_tools\.notify_event.*?~data:\(`Assoc \[\n.*?\]\)\n', '\n'),
])

# Fix lib/operator/operator_control_snapshot.ml
process("lib/operator/operator_control_snapshot.ml", [
    (r'\s*\| Some task, Some result ->.*?let agent_card =.*?\n', '\n  let agent_card = `Null in\n'),
])

# Fix lib/dashboard/dashboard_mission_assembly.ml
process("lib/dashboard/dashboard_mission_assembly.ml", [
    (r'\s*\| Some task, Some result ->.*?\n\s*\| _ -> `Null\n', '\n    `Null\n'),
])

# Fix lib/dashboard/dashboard_execution_helpers.ml
process("lib/dashboard/dashboard_execution_helpers.ml", [
    (r'match task_snapshot, result_snapshot with.*?\| _ ->\n', ''),
    (r'let execution_status =.*?\n\s*in', 'let execution_status = "ok" in'),
])

# Fix lib/tool_catalog.ml
process("lib/tool_catalog.ml", [
    (r'\s*\| TN\.Masc TM\.A2a_delegate\n', '\n'),
])

# Fix lib/mcp_server_eio_execute.ml
process("lib/mcp_server_eio_execute.ml", [
    (r'\s*\| Mod_a2a ->\n\s*Tool_a2a\.dispatch \{ config; agent_name \} ~name ~args\n', '\n'),
])

# Fix test/test_tool_name.ml
process("test/test_tool_name.ml", [
    (r'A2a_delegate;\s*', ''),
])

# Re-add Oas.Error.A2a pattern matches (since Oas library still has it)
process("lib/keeper/keeper_checkpoint_store.ml", [
    (r'\| Orchestration _ \| Internal _ ->', '| Orchestration _ | Internal _ | A2a _ ->'),
])

process("lib/keeper/keeper_agent_error.ml", [
    (r'\| Oas\.Error\.Internal _ -> "internal"\n', '| Oas.Error.Internal _ -> "internal"\n  | Oas.Error.A2a _ -> "a2a"\n'),
    (r'\| Oas\.Error\.Internal _ -> "internal_error"\n', '| Oas.Error.Internal _ -> "internal_error"\n  | Oas.Error.A2a _ -> "a2a_error"\n'),
])

process("lib/keeper/keeper_turn_cascade_budget.ml", [
    (r'\| Oas\.Error\.Internal _ -> "internal"\n', '| Oas.Error.Internal _ -> "internal"\n  | Oas.Error.A2a _ -> "a2a"\n'),
])

print("done")
