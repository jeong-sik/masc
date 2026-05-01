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

process("lib/mcp_server_eio_call_tool.ml", [
    (r'\s*shared_memory_scope\s*=\n\s*Some\n\s*\(Keeper_types_profile\.shared_memory_scope_to_string\n\s*entry\.meta\.shared_memory_scope\);', ''),
    (r'\s*shared_memory_scope = Some \(.*?\);', ''),
])

process("lib/keeper/keeper_turn_up_args.ml", [
    (r'match\n\s*compaction_profile_opt_res, tool_access_input_res, allowed_paths_opt_res,\n\s*active_goal_ids_opt_res, sandbox_profile_opt_res, network_mode_opt_res,\n\s*shared_memory_scope_opt_res\n\s*with\n\s*\| Error e, _, _, _, _, _, _\n\s*\| _, Error e, _, _, _, _, _\n\s*\| _, _, Error e, _, _, _, _\n\s*\| _, _, _, Error e, _, _, _\n\s*\| _, _, _, _, Error e, _, _\n\s*\| _, _, _, _, _, Error e, _\n\s*\| _, _, _, _, _, _, Error e -> Error \(false, e\)\n\s*\| Ok compaction_profile_opt,\n\s*Ok \(tool_access_opt, tool_preset_opt, tool_also_allow_opt\),\n\s*Ok allowed_paths_opt,\n\s*Ok active_goal_ids_opt,\n\s*Ok sandbox_profile_opt,\n\s*Ok network_mode_opt,\n\s*Ok shared_memory_scope_opt ->',
    r'''match
      compaction_profile_opt_res, tool_access_input_res, allowed_paths_opt_res,
      active_goal_ids_opt_res, sandbox_profile_opt_res, network_mode_opt_res
    with
    | Error e, _, _, _, _, _
    | _, Error e, _, _, _, _
    | _, _, Error e, _, _, _
    | _, _, _, Error e, _, _
    | _, _, _, _, Error e, _
    | _, _, _, _, _, Error e -> Error (false, e)
    | Ok compaction_profile_opt,
      Ok (tool_access_opt, tool_preset_opt, tool_also_allow_opt),
      Ok allowed_paths_opt,
      Ok active_goal_ids_opt,
      Ok sandbox_profile_opt,
      Ok network_mode_opt ->''')
])

process("test/test_types.ml", [
    (r'let shared_memory_scope_ssot \(\) =.*?\(\)\n\n', ''),
])

process("test/test_keeper_runtime_config_ssot.ml", [
    (r'\s*check string "shared_memory_scope".*?\n', '\n'),
])

print("done")
