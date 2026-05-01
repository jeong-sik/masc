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

files_to_remove = [
    "lib/tool_a2a.ml", "lib/tool_schemas_a2a.ml", "lib/a2a_types.mli", "lib/agent_card.ml", "lib/agent_card.mli"
]
for f in files_to_remove:
    if os.path.exists(f): os.remove(f)

process("lib/dune", [
    (r'\s*tool_a2a', ''),
    (r'\s*tool_schemas_a2a', ''),
    (r'\s*a2a_types', ''),
    (r'\s*agent_card', ''),
])

process("lib/config.ml", [
    (r'\s*@ Tool_schemas_a2a\.schemas', ''),
    (r'\s*"masc_collaboration_graph";', ''),
])

process("lib/tools.ml", [
    (r'\s*@ Tool_schemas_a2a\.schemas', ''),
])

process("lib/tool_name.mli", [
    (r'\s*\| A2a_delegate', ''),
])

process("lib/tool_name.ml", [
    (r'\s*\| A2a_delegate', ''),
    (r'\s*\| A2a_delegate -> "masc_a2a_delegate"', ''),
    (r'\s*\| "masc_a2a_delegate" -> Some A2a_delegate', ''),
])

process("lib/tool_dispatch.mli", [
    (r'\s*\| Mod_a2a', ''),
])

process("lib/tool_dispatch.ml", [
    (r'\s*\| Mod_a2a', ''),
    (r'\s*\| A2a_delegate', ''),
])

process("lib/keeper/keeper_tag_dispatch.ml", [
    (r'\s*\| Mod_a2a ->\n\s*Tool_a2a\.dispatch { Tool_a2a\.config; agent_name } ~name ~args', ''),
])

process("lib/keeper/keeper_checkpoint_store.ml", [
    (r' \| A2a _', ''),
    (r' / A2a', ''),
    (r'\s*\| A2a _ ->\n\s*Error "checkpoint io_error: a2a"', ''),
    (r'\s*\| Orchestration _ \| A2a _ \| Internal _ ->', '\n  | Orchestration _ | Internal _ ->'),
])

process("lib/keeper/keeper_agent_error.ml", [
    (r'\s*\| Oas\.Error\.A2a _ -> "a2a"', ''),
    (r'\s*\| Oas\.Error\.A2a _ -> "a2a_error"', ''),
])

process("lib/keeper/keeper_turn_cascade_budget.ml", [
    (r'\s*\| Oas\.Error\.A2a _ -> "a2a"', ''),
])

process("lib/tool_task.ml", [
    (r'\s*\(\* Notify A2A subscribers on successful transition \*\).*?~event_type:A2a_tools\.TaskUpdate\n', ''),
])

process("lib/exec/exec_gate.ml", [
    (r'\s*\("tool/a2a_discovery", internal_observer_overlay\);', ''),
])

process("lib/tool_inline_dispatch_extra.ml", [
    (r'\s*A2a_tools\.notify_event\n\s*~event_type:A2a_tools\.Broadcast', ''),
])

process("lib/dashboard/dashboard_execution_helpers.mli", [
    (r'\s*\[agent_name\] from the A2A heartbeat snapshots\.', ''),
])

process("lib/dashboard/dashboard_execution_helpers.ml", [
    (r'\s*let task_snapshot = A2a_tools\.latest_heartbeat_task agent_name in\n\s*let result_snapshot = A2a_tools\.latest_heartbeat_result agent_name in', ''),
])

process("lib/dashboard/dashboard_mission_assembly.ml", [
    (r'\s*match A2a_tools\.latest_heartbeat_task agent_name,\n\s*A2a_tools\.latest_heartbeat_result agent_name with', ''),
])

process("lib/tool_inline_dispatch_comm.ml", [
    (r'\s*A2a_tools\.notify_event\n\s*~event_type:A2a_tools\.Broadcast', ''),
])

process("lib/operator/operator_control_snapshot.ml", [
    (r'\s*match A2a_tools\.latest_heartbeat_task meta\.agent_name,\n\s*A2a_tools\.latest_heartbeat_result meta\.agent_name with', ''),
])

process("lib/config/env_config_snapshot.ml", [
    (r'\s*entry ~default:"300" "MASC_A2A_DELEGATION_TIMEOUT_SEC"\n\s*"A2A task delegation timeout \(seconds\)";\n\s*"A2A event buffer size per subscription";', ''),
])

print("done")
