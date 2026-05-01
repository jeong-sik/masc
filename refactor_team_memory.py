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

# 1. tool_team_memory removal
if os.path.exists("lib/tool_team_memory.ml"): os.remove("lib/tool_team_memory.ml")
if os.path.exists("lib/tool_team_memory.mli"): os.remove("lib/tool_team_memory.mli")
if os.path.exists("test/test_team_memory.ml"): os.remove("test/test_team_memory.ml")

process("lib/dune", [
    (r'\s*tool_team_memory', ''),
])

process("test/dune", [
    (r'\s*test_team_memory', ''),
])

process("lib/tools.ml", [
    (r'\s*@ Tool_team_memory\.schemas', ''),
])

process("lib/tool_catalog_surfaces.ml", [
    (r'^\s*\(\* Shared memory lane.*?\*\)\n', ''),
    (r'^\s*"masc_team_memory_read"; "masc_team_memory_write"; "masc_team_memory_search";\n', ''),
])

process("lib/mcp_server_eio_call_tool.ml", [
    (r'\s*\| "masc_team_memory_read".*?\| "masc_team_memory_search" ->\n\s*Tool_team_memory\.dispatch_exn ctx name args', ''),
])

# 2. shared_memory_scope removal

process("lib/keeper/keeper_types_profile.ml", [
    (r'type shared_memory_scope =.*?\[@@deriving tla\]\n*', ''),
    (r'type shared_memory_scope =.*?\n\n', ''),
    (r'let shared_memory_scope_to_string.*?all_shared_memory_scopes\n\n', ''),
    (r'let default_shared_memory_scope = Shared_memory_disabled\n\n', ''),
    (r'\s*shared_memory_scope\s*:\s*shared_memory_scope\s*option;', ''),
    (r'\s*shared_memory_scope\s*=\s*None;', ''),
    (r'\s*shared_memory_scope\s*=\n\s*Option\.bind \(str "shared_memory_scope"\)\n\s*shared_memory_scope_of_string;', ''),
    (r'\s*;\s*"shared_memory_scope"', ''),
    (r'else if contains "invalid shared_memory_scope".*?\n', ''),
    (r'\s*shared_memory_scope\s*=\s*prefer overlay\.shared_memory_scope base\.shared_memory_scope;', ''),
    (r'match str "shared_memory_scope" with\n\s*\| Some raw -> \(\n\s*match shared_memory_scope_of_string raw with\n\s*\| Some _ -> Ok \(\)\n\s*\| None ->\n\s*Error\n\s*\(Printf\.sprintf\n\s*"invalid shared_memory_scope.*?raw\)\)\n\s*\| None -> Ok \(\)', 'Ok ()'),
])

process("lib/keeper/keeper_types.mli", [
    (r'\s*shared_memory_scope\s*:\s*shared_memory_scope;', ''),
])

process("lib/keeper/keeper_meta_contract.mli", [
    (r'\s*shared_memory_scope\s*:\s*Keeper_types_profile\.shared_memory_scope;', ''),
])

process("lib/keeper/keeper_meta_contract.ml", [
    (r'\s*;\s*shared_memory_scope\s*:\s*shared_memory_scope', ''),
])

process("lib/keeper/keeper_meta_json_parse.mli", [
    (r'\s*;\s*pp_shared_memory_scope\s*:\s*Keeper_types_profile\.shared_memory_scope', ''),
    (r'\s*;\s*pp_shared_memory_scope\s*:\s*shared_memory_scope', ''),
])

process("lib/keeper/keeper_meta_json_parse.ml", [
    (r'\s*;\s*pp_shared_memory_scope\s*:\s*Keeper_types_profile\.shared_memory_scope', ''),
    (r'\s*;\s*pp_shared_memory_scope\s*:\s*shared_memory_scope', ''),
    (r'\s*let pp_shared_memory_scope =.*?\(shared_memory_scope_of_string raw\)\n', ''),
    (r'\s*;\s*pp_shared_memory_scope', ''),
    (r'\s*;\s*shared_memory_scope\s*=\s*policy\.pp_shared_memory_scope', ''),
])

process("lib/keeper/keeper_meta_json.ml", [
    (r'\s*;\s*"shared_memory_scope".*?\n', '\n'),
])

process("lib/keeper/keeper_schema.mli", [
    (r'val shared_memory_scope_enum_strings.*?\*\)\n', ''),
])

process("lib/keeper/keeper_schema.ml", [
    (r'and \[shared_memory_scope\]', ''),
    (r'let shared_memory_scope_enum_strings.*?\n\n', ''),
    (r'\s*\(\"shared_memory_scope\".*?\)\)\);\n', ''),
])

process("lib/keeper/keeper_status_detail.ml", [
    (r'\s*\(\"shared_memory_scope\".*?\);\n', '\n'),
])

process("lib/keeper/keeper_turn_up_args.mli", [
    (r'\s*;\s*shared_memory_scope_opt\s*:\s*Keeper_types_profile\.shared_memory_scope option', ''),
    (r'\s*;\s*shared_memory_scope_opt\s*:\s*shared_memory_scope option', ''),
    (r'val resolve_shared_memory_scope.*?\n\n', ''),
])

process("lib/keeper/keeper_turn_up_args.ml", [
    (r'\s*shared_memory_scope_opt\s*:\s*shared_memory_scope option;', ''),
    (r'\s*shared_memory_scope_opt\s*:\s*Keeper_types_profile\.shared_memory_scope option;', ''),
    (r'\s*let shared_memory_scope_opt_res =.*?shared_memory_scope_of_string\n\s*~allowed_values:"disabled, room"\n\s*in', ''),
    (r'\s*,\s*shared_memory_scope_opt_res', ''),
    (r'\s*\|\s*_, _, _, _, _, _, Error e', ''),
    (r'\s*\|\s*_, Error e, _, _, _, _, _', '| _, Error e, _, _, _, _'),
    (r'\s*\|\s*Error e, _, _, _, _, _, _', '| Error e, _, _, _, _, _'),
    (r'\s*,\s*Ok shared_memory_scope_opt\s*->', ' ->'),
    (r'\s*shared_memory_scope_opt;', ''),
    (r'let resolve_shared_memory_scope.*?\n\n', '\n'),
])

process("lib/keeper/keeper_turn_up_update.ml", [
    (r'\s*let shared_memory_scope =.*?shared_memory_scope_opt\n\s*in', ''),
    (r'\s*shared_memory_scope;', ''),
])

process("lib/keeper/keeper_unified_metrics.ml", [
    (r'\s*,\s*_shared_memory_scope', ''),
    (r'let \(\s*agent_name,\s*lane,\s*thinking_enabled,\s*thinking_budget,\s*prompt_fingerprint,\s*trace_id,\s*session_id,\s*generation,\s*turn,\s*task_id,\s*goal_ids,\s*sandbox_profile,\s*sandbox_root,\s*allowed_paths,\s*network_mode\s*\)\s*=\s*Keeper_tool_call_log\.get_turn_context\s*~keeper_name:meta\.name\s*\(\)',
     r'let ( agent_name, lane, thinking_enabled, thinking_budget, prompt_fingerprint, trace_id, session_id, generation, turn, task_id, goal_ids, sandbox_profile, sandbox_root, allowed_paths, network_mode ) = Keeper_tool_call_log.get_turn_context ~keeper_name:meta.name ()'),
    (r'let \(\s*agent_name,\s*lane,\s*thinking_enabled,\s*thinking_budget,\s*prompt_fingerprint,\s*trace_id,\s*session_id,\s*generation,\s*turn,\s*task_id,\s*goal_ids,\s*sandbox_profile,\s*sandbox_root,\s*allowed_paths,\s*network_mode,\s*_[a-zA-Z0-9_]*\)\s*=\s*Keeper_tool_call_log\.get_turn_context\s*~keeper_name:meta\.name\s*\(\)',
     r'let ( agent_name, lane, thinking_enabled, thinking_budget, prompt_fingerprint, trace_id, session_id, generation, turn, task_id, goal_ids, sandbox_profile, sandbox_root, allowed_paths, network_mode ) = Keeper_tool_call_log.get_turn_context ~keeper_name:meta.name ()'),
])

process("lib/keeper/keeper_hooks_oas.ml", [
    (r'\s*,\s*shared_memory_scope', ''),
    (r'\s*\?shared_memory_scope', ''),
    (r'let \(\s*agent_name,\s*lane,\s*thinking_enabled,\s*thinking_budget,\s*prompt_fingerprint,\s*trace_id,\s*session_id,\s*generation,\s*turn,\s*task_id,\s*goal_ids,\s*sandbox_profile,\s*sandbox_root,\s*allowed_paths,\s*network_mode\s*\)\s*=\s*Keeper_tool_call_log\.get_turn_context',
     r'let ( agent_name, lane, thinking_enabled, thinking_budget, prompt_fingerprint, trace_id, session_id, generation, turn, task_id, goal_ids, sandbox_profile, sandbox_root, allowed_paths, network_mode ) = Keeper_tool_call_log.get_turn_context'),
    (r'let \(\s*agent_name,\s*lane,\s*thinking_enabled,\s*thinking_budget,\s*prompt_fingerprint,\s*trace_id,\s*session_id,\s*generation,\s*turn,\s*task_id,\s*goal_ids,\s*sandbox_profile,\s*sandbox_root,\s*network_mode\s*\)\s*=\s*Keeper_tool_call_log\.get_turn_context',
     r'let ( agent_name, lane, thinking_enabled, thinking_budget, prompt_fingerprint, trace_id, session_id, generation, turn, task_id, goal_ids, sandbox_profile, sandbox_root, allowed_paths, network_mode ) = Keeper_tool_call_log.get_turn_context'),
])

process("lib/keeper/keeper_runtime.ml", [
    (r'\s*let target_shared_memory_scope =.*?default_shared_memory_scope in', ''),
    (r'\s*\|\|\s*meta\.shared_memory_scope <> target_shared_memory_scope', ''),
    (r'\s*shared_memory_scope = target_shared_memory_scope;', ''),
    (r'\s*shared_memory_scope\s*=\s*meta\.shared_memory_scope;', ''),
])

process("lib/keeper/keeper_turn_up_create.ml", [
    (r'\s*let shared_memory_scope =.*?resolve_shared_memory_scope.*?fallback:base\.shared_memory_scope\n\s*in', ''),
    (r'\s*~fallback:p\.profile_defaults\.shared_memory_scope', ''),
    (r'\s*shared_memory_scope = shared_memory_scope;', ''),
    (r'\s*resolve_shared_memory_scope.*?\n', '\n'),
])

process("lib/keeper/keeper_exec_persona.ml", [
    (r'\s*append_optional_string_field fields "shared_memory_scope" json', ''),
])

process("lib/keeper/keeper_runtime_contract.mli", [
    (r'\s*\?shared_memory_scope:string ->', ''),
])

process("lib/keeper/keeper_runtime_contract.ml", [
    (r'\s*\?shared_memory_scope', ''),
    (r'\s*\(\"shared_memory_scope\", string_opt_json shared_memory_scope\);', ''),
    (r'\s*\(\s*"shared_memory_scope",\s*string_opt_json shared_memory_scope\s*\);', ''),
    (r'\s*\(\s*"shared_memory_scope",.*?meta\.shared_memory_scope\)\s*\);', ''),
])

process("lib/keeper_tool_call_log.mli", [
    (r'\s*\?shared_memory_scope:string ->', ''),
    (r'\s*shared_memory_scope\s*:\s*string option;', ''),
    (r'\s*string option\s*\*\s*string option\s*\*\s*bool option\s*\*\s*int option\s*\*\s*string option\s*\*\s*string option\s*\*\s*string option\s*\*\s*int option\s*\*\s*int option\s*\*\s*string option\s*\*\s*string list option\s*\*\s*string option\s*\*\s*string option\s*\*\s*string option\s*\*\s*string option',
     r'string option * string option * bool option * int option * string option * string option * string option * int option * int option * string option * string list option * string option * string option * string option'),
])

process("lib/keeper_tool_call_log.ml", [
    (r'\s*shared_memory_scope\s*:\s*string option;', ''),
    (r'\s*shared_memory_scope\s*=\s*None;', ''),
    (r'\s*\?shared_memory_scope:ctx\.shared_memory_scope', ''),
    (r'\s*\?shared_memory_scope', ''),
    (r'\s*shared_memory_scope;', ''),
    (r'\s*,\s*ctx\.shared_memory_scope', ''),
    (r'\s*,\s*ctx_shared_memory_scope', ''),
    (r'\s*let shared_memory_scope =.*?ctx_shared_memory_scope\n\s*in', ''),
    (r'\s*let shared_memory_scope =.*?in', ''),
    (r'\s*let shared_memory_scope_field =.*?\]\n\s*in', ''),
    (r'\s*@\s*shared_memory_scope_field', ''),
])

process("lib/mcp_server_eio_call_tool.ml", [
    (r'\s*~shared_memory_scope:\n\s*\(Keeper_types_profile\.shared_memory_scope_to_string\n\s*entry\.meta\.shared_memory_scope\)', ''),
    (r'\s*~shared_memory_scope:\n\s*\(Keeper_types\.shared_memory_scope_to_string\n\s*entry\.meta\.shared_memory_scope\)', ''),
    (r'\s*~shared_memory_scope:.*?\n\s*entry\.meta\.shared_memory_scope\)', ''),
    (r'\s*~shared_memory_scope:.*?\n', '\n'),
    (r'\s*entry\.meta\.shared_memory_scope\);\n', '\n'),
])

process("lib/keeper/keeper_run_tools.ml", [
    (r'\s*~shared_memory_scope:.*?\n\s*meta\.shared_memory_scope\)', ''),
    (r'\s*~shared_memory_scope:.*?\n', '\n'),
])

process("lib/dashboard/dashboard_http_keeper.ml", [
    (r'\s*,\s*"shared_memory_scope", `String \(Keeper_types_profile.shared_memory_scope_to_string meta\.shared_memory_scope\)', ''),
    (r'\s*\("shared_memory_scope",\s*`String \(Keeper_types\.shared_memory_scope_to_string m\.shared_memory_scope\)\);\n', ''),
])

process("test/test_types.ml", [
    (r'\s*test_list_eq "shared_memory_scope_enum_strings".*?Masc_mcp\.Keeper_schema\.shared_memory_scope_enum_strings\);', ''),
])

process("test/test_keeper_runtime_config_ssot.ml", [
    (r'\s*check string "shared_memory_scope".*?updated\.shared_memory_scope\);\n', ''),
])

process("test/test_keeper_tool_call_log.ml", [
    (r'\s*~shared_memory_scope:"team"', ''),
    (r'\s*~shared_memory_scope:"room"', ''),
])

# Dashboard files removal
process("dashboard/src/api/board.ts", [
    (r'\s*shared_memory_scope:\s*asNullableString.*?shared_memory_scope\),', ''),
])

process("dashboard/src/api/dashboard.test.ts", [
    (r'\s*shared_memory_scope:\s*\'room\',', ''),
    (r'\s*expect\(result\.shared_memory_scope\)\.toBe\(\'room\'\)', ''),
])

process("dashboard/src/api/dashboard.ts", [
    (r'\s*shared_memory_scope:\s*asNullableString.*?\'disabled\',', ''),
    (r'\s*shared_memory_scope\?:\s*SharedMemoryScope', ''),
])

process("dashboard/src/types/core.ts", [
    (r'\s*shared_memory_scope\?:\s*\'disabled\'\s*\|\s*\'room\'\s*\|\s*string', ''),
])

process("dashboard/src/components/keeper-config-panel.ts", [
    (r'\s*shared_memory_scope:\s*SharedMemoryScope', ''),
    (r'\s*shared_memory_scope:\s*coerceSharedMemoryScope\(c\.shared_memory_scope\),', ''),
    (r'\s*if \(draft\.shared_memory_scope\s*!==\s*coerceSharedMemoryScope.*?payload\.shared_memory_scope\s*=\s*draft\.shared_memory_scope', ''),
    (r'\s*<ConfigRow\s*label="shared_memory_scope"\s*value=.*?/>', ''),
])

# Let's fix pattern match in keeper_turn_up_args.ml directly to be robust
process("lib/keeper/keeper_turn_up_args.ml", [
    (r'match\n\s*compaction_profile_opt_res, tool_access_input_res, allowed_paths_opt_res,\n\s*active_goal_ids_opt_res, sandbox_profile_opt_res, network_mode_opt_res.*?\n\s*with\n\s*\| Error e, _, _, _, _, _, _\n\s*\| _, Error e, _, _, _, _, _\n\s*\| _, _, Error e, _, _, _, _\n\s*\| _, _, _, Error e, _, _, _\n\s*\| _, _, _, _, Error e, _, _\n\s*\| _, _, _, _, _, Error e, _\n\s*\| _, _, _, _, _, _, Error e -> Error \(false, e\)\n\s*\| Ok compaction_profile_opt,\n\s*Ok \(tool_access_opt, tool_preset_opt, tool_also_allow_opt\),\n\s*Ok allowed_paths_opt,\n\s*Ok active_goal_ids_opt,\n\s*Ok sandbox_profile_opt,\n\s*Ok network_mode_opt,\n\s*Ok shared_memory_scope_opt ->', 
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

print("done")
