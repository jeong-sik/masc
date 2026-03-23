(** Keeper_turn_up_args -- parse and bundle tool arguments for keeper_up.

    Extracts all argument parsing from handle_keeper_up into a single
    record so that create/update branches receive structured data
    instead of 60+ local bindings. *)

open Tool_args
open Keeper_types

type parsed_args = {
  name : string;
  soul_profile_opt : string option;
  compaction_profile_opt : string option;
  goal_opt : string option;
  short_goal_opt : string option;
  mid_goal_opt : string option;
  long_goal_opt : string option;
  models_in : string list;
  allowed_models_in : string list;
  active_model_opt : string option;
  policy_mode_opt : string option;
  policy_voice_enabled_opt : bool option;
  policy_shell_mode_opt : string option;
  allowed_paths_opt : string list option;
  room_scope_opt : string option;
  scope_kind_opt : string option;
  trigger_mode_opt : string option;
  voice_enabled_opt : bool option;
  voice_channel_opt : string option;
  voice_agent_id_opt : string option;
  mention_targets_in : string list;
  presence_keepalive_opt : bool option;
  presence_keepalive_sec_opt : int option;
  proactive_enabled_opt : bool option;
  proactive_idle_sec_opt : int option;
  proactive_cooldown_sec_opt : int option;
  compaction_ratio_gate_opt : float option;
  compaction_message_gate_opt : int option;
  compaction_token_gate_opt : int option;
  continuity_compaction_cooldown_sec_opt : int option;
  auto_handoff_opt : bool option;
  handoff_threshold_opt : float option;
  handoff_cooldown_sec_opt : int option;
  instructions_arg : string option;
  will_opt : string option;
  needs_opt : string option;
  desires_opt : string option;
  profile_defaults : keeper_profile_defaults;
  instructions_opt : string option;
}

let parse (ctx : _ context) (args : Yojson.Safe.t) : (parsed_args, tool_result) result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    Error (false, "invalid keeper name (allowed: [A-Za-z0-9._-])")
  else
    let soul_profile_opt_res = parse_soul_profile_opt args "soul_profile" in
    let compaction_profile_opt_res =
      parse_compaction_profile_opt args "compaction_profile"
    in
    match soul_profile_opt_res, compaction_profile_opt_res with
    | Error e, _ | _, Error e -> Error (false, e)
    | Ok soul_profile_opt, Ok compaction_profile_opt ->
    let goal_opt = get_string_opt args "goal" in
    let short_goal_opt = parse_goal_horizon_opt args "short_goal" in
    let mid_goal_opt = parse_goal_horizon_opt args "mid_goal" in
    let long_goal_opt = parse_goal_horizon_opt args "long_goal" in
    let models_in = get_string_list args "models" in
    let allowed_models_in = get_string_list args "allowed_models" in
    let active_model_opt = get_string_opt args "active_model" in
    let policy_mode_opt = get_string_opt args "policy_mode" in
    let policy_voice_enabled_opt = get_bool_opt args "policy_voice_enabled" in
    let policy_shell_mode_opt = get_string_opt args "policy_shell_mode" in
    let allowed_paths_opt =
      let raw = get_string_list args "allowed_paths" in
      if raw = [] then None else Some raw
    in
    let room_scope_opt = get_string_opt args "room_scope" in
    let scope_kind_opt = get_string_opt args "scope_kind" in
    let trigger_mode_opt = get_string_opt args "trigger_mode" in
    let voice_enabled_opt = get_bool_opt args "voice_enabled" in
    let voice_channel_opt = get_string_opt args "voice_channel" in
    let voice_agent_id_opt = get_string_opt args "voice_agent_id" in
    let mention_targets_in = get_string_list args "mention_targets" in
    let presence_keepalive_opt = get_bool_opt args "presence_keepalive" in
    let presence_keepalive_sec_opt = Safe_ops.json_int_opt "presence_keepalive_sec" args in
    let proactive_enabled_opt = get_bool_opt args "proactive_enabled" in
    let proactive_idle_sec_opt = Safe_ops.json_int_opt "proactive_idle_sec" args in
    let proactive_cooldown_sec_opt = Safe_ops.json_int_opt "proactive_cooldown_sec" args in
    let compaction_ratio_gate_opt = Safe_ops.json_float_opt "compaction_ratio_gate" args in
    let compaction_message_gate_opt = Safe_ops.json_int_opt "compaction_message_gate" args in
    let compaction_token_gate_opt = Safe_ops.json_int_opt "compaction_token_gate" args in
    let continuity_compaction_cooldown_sec_opt =
      Safe_ops.json_int_opt "continuity_compaction_cooldown_sec" args
    in
    let auto_handoff_opt = get_bool_opt args "auto_handoff" in
    let handoff_threshold_opt = Safe_ops.json_float_opt "handoff_threshold" args in
    let handoff_cooldown_sec_opt = Safe_ops.json_int_opt "handoff_cooldown_sec" args in
    let instructions_arg = get_string_opt args "instructions" in
    let profile_defaults = load_keeper_profile_defaults name in
    let soul_path =
      Filename.concat
        (Filename.concat
           (Filename.concat
              (Filename.concat ctx.config.base_path "memory")
              "souls")
           name)
        "SOUL.md"
    in
    let soul_content =
      match Safe_ops.read_file_safe soul_path with Ok c -> c | Error _ -> ""
    in
    let base_instructions_opt =
      match instructions_arg with
      | Some _ -> instructions_arg
      | None -> profile_defaults.instructions
    in
    let instructions_opt =
      if soul_content <> "" then
        let base = Option.value ~default:"" base_instructions_opt in
        Some (base ^ "\n\n[SYSTEM: SOUL INFUSION]\n" ^ soul_content)
      else
        base_instructions_opt
    in
    let will_opt = parse_self_model_opt args "will" in
    let needs_opt = parse_self_model_opt args "needs" in
    let desires_opt = parse_self_model_opt args "desires" in
    Ok {
      name;
      soul_profile_opt;
      compaction_profile_opt;
      goal_opt;
      short_goal_opt;
      mid_goal_opt;
      long_goal_opt;
      models_in;
      allowed_models_in;
      active_model_opt;
      policy_mode_opt;
      policy_voice_enabled_opt;
      policy_shell_mode_opt;
      allowed_paths_opt;
      room_scope_opt;
      scope_kind_opt;
      trigger_mode_opt;
      voice_enabled_opt;
      voice_channel_opt;
      voice_agent_id_opt;
      mention_targets_in;
      presence_keepalive_opt;
      presence_keepalive_sec_opt;
      proactive_enabled_opt;
      proactive_idle_sec_opt;
      proactive_cooldown_sec_opt;
      compaction_ratio_gate_opt;
      compaction_message_gate_opt;
      compaction_token_gate_opt;
      continuity_compaction_cooldown_sec_opt;
      auto_handoff_opt;
      handoff_threshold_opt;
      handoff_cooldown_sec_opt;
      instructions_arg;
      will_opt;
      needs_opt;
      desires_opt;
      profile_defaults;
      instructions_opt;
    }

(** Resolve mention targets with dedup and filtering. *)
let resolve_mention_targets ~mention_targets_in ~fallback_targets ~name =
  let raw =
    if mention_targets_in <> [] then mention_targets_in
    else if fallback_targets <> [] then fallback_targets
    else [ name ]
  in
  raw |> List.filter (fun s -> String.trim s <> "") |> dedupe_keep_order
