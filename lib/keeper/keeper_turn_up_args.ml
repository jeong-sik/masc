(** Keeper_turn_up_args -- parse and bundle tool arguments for keeper_up.

    Extracts all argument parsing from handle_keeper_up into a single
    record so that create/update branches receive structured data
    instead of 60+ local bindings. *)

open Tool_args
open Keeper_types

type parsed_args = {
  name : string;
  compaction_profile_opt : string option;
  goal_opt : string option;
  short_goal_opt : string option;
  mid_goal_opt : string option;
  long_goal_opt : string option;
  policy_voice_enabled_opt : bool option;
  allowed_paths_opt : string list option;
  autoboot_enabled_opt : bool option;
  execution_scope_opt : Keeper_execution_scope.t option;
  sandbox_profile_opt : sandbox_profile option;
  network_mode_opt : network_mode option;
  shared_memory_scope_opt : shared_memory_scope option;
  voice_enabled_opt : bool option;
  voice_channel_opt : string option;
  voice_agent_id_opt : string option;
  mention_targets_in : string list;
  max_context_override_opt : int option;
  proactive_enabled_opt : bool option;
  proactive_idle_sec_opt : int option;
  proactive_cooldown_sec_opt : int option;
  compaction_ratio_gate_opt : float option;
  compaction_message_gate_opt : int option;
  compaction_token_gate_opt : int option;
  continuity_compaction_cooldown_sec_opt : int option;
  tool_access_opt : tool_access option;
  tool_preset_opt : tool_preset option;
  tool_also_allow_opt : string list option;
  tool_denylist_opt : string list option;
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

let normalize_tool_name_list names =
  names
  |> List.map String.trim
  |> List.filter (fun name -> name <> "")
  |> dedupe_keep_order

let json_assoc_member_opt key (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let json_non_null_member_present key (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some `Null | None -> false
      | Some _ -> true)
  | _ -> false

let parse_present_tool_name_list_opt args key =
  match json_assoc_member_opt key args with
  | None -> Ok None
  | Some (`List items) ->
      let rec collect acc index = function
        | [] -> Ok (Some (normalize_tool_name_list (List.rev acc)))
        | `String value :: rest -> collect (value :: acc) (index + 1) rest
        | _ :: _ ->
            Error (Printf.sprintf "%s[%d] must be a string" key index)
      in
      collect [] 0 items
  | Some `Null -> Error (Printf.sprintf "%s must not be null" key)
  | Some _ -> Error (Printf.sprintf "%s must be an array of strings" key)

let parse_present_string_list_opt args key =
  match json_assoc_member_opt key args with
  | None -> Ok None
  | Some (`List items) ->
      let rec collect acc index = function
        | [] -> Ok (Some (normalize_name_list (List.rev acc)))
        | `String value :: rest -> collect (value :: acc) (index + 1) rest
        | _ :: _ ->
            Error (Printf.sprintf "%s[%d] must be a string" key index)
      in
      collect [] 0 items
  | Some `Null -> Error (Printf.sprintf "%s must not be null" key)
  | Some _ -> Error (Printf.sprintf "%s must be an array of strings" key)

let parse_enum_string_opt args key of_string ~allowed_values =
  match json_assoc_member_opt key args with
  | None -> Ok None
  | Some (`String raw) -> (
      match of_string raw with
      | Some value -> Ok (Some value)
      | None ->
          Error
            (Printf.sprintf "invalid %s '%s' (allowed: %s)"
               key raw allowed_values))
  | Some `Null -> Error (Printf.sprintf "%s must not be null" key)
  | Some _ -> Error (Printf.sprintf "%s must be a string" key)

let resolve_tool_name_list ~preferred ~fallback =
  first_some preferred fallback
  |> Option.value ~default:[]
  |> normalize_tool_name_list

let reject_legacy_tool_access_kind access_json =
  match json_assoc_member_opt "kind" access_json with
  | Some (`String ("restricted" | "unrestricted")) ->
      Error
        "tool_access.kind must be \"preset\" or \"custom\"; legacy kinds \"restricted\" and \"unrestricted\" are not supported for this endpoint"
  | _ -> Ok ()

let parse_tool_access_input (args : Yojson.Safe.t) :
    (tool_access option * tool_preset option * string list option, string) result =
  let tool_access_present = json_non_null_member_present "tool_access" args in
  let tool_preset_present = json_non_null_member_present "tool_preset" args in
  let tool_also_allow_present = json_non_null_member_present "tool_also_allow" args in
  let tool_custom_allowlist_present = json_non_null_member_present "tool_custom_allowlist" args in
  if tool_access_present
     && (tool_preset_present || tool_also_allow_present || tool_custom_allowlist_present)
  then
    Error
      "tool_access cannot be combined with tool_preset, tool_also_allow, or tool_custom_allowlist"
  else if tool_custom_allowlist_present && (tool_preset_present || tool_also_allow_present) then
    Error
      "tool_custom_allowlist cannot be combined with tool_preset or tool_also_allow"
  else
    let tool_access_opt =
      match json_assoc_member_opt "tool_access" args with
      | Some ((`Assoc _) as access_json) -> (
          match reject_legacy_tool_access_kind access_json with
          | Error msg -> Error msg
          | Ok () -> (
              match tool_access_of_meta_json (`Assoc [ ("tool_access", access_json) ]) with
              | Ok access -> Ok (Some access)
              | Error msg -> Error msg))
      | Some `Null -> Ok None
      | Some _ -> Error "tool_access must be an object"
      | None when json_assoc_member_opt "tool_custom_allowlist" args <> None -> (
          match parse_present_tool_name_list_opt args "tool_custom_allowlist" with
          | Ok (Some names) -> Ok (Some (Custom names))
          | Ok None -> Ok None
          | Error msg -> Error msg)
      | None -> Ok None
    in
    match tool_access_opt with
    | Error msg -> Error msg
    | Ok tool_access_opt ->
        let tool_preset_opt =
          match json_assoc_member_opt "tool_preset" args with
          | None -> Ok None
          | Some (`String raw) -> (
              match tool_preset_of_string raw with
              | Some preset -> Ok (Some preset)
              | None ->
                  Error
                    (Printf.sprintf
                       "invalid tool_preset '%s' (allowed: minimal, social, messaging, coding, research, delivery, full)"
                       raw))
          | Some `Null -> Error "tool_preset must not be null"
          | Some _ -> Error "tool_preset must be a string"
        in
        let tool_also_allow_opt =
          parse_present_tool_name_list_opt args "tool_also_allow"
        in
        (match tool_preset_opt, tool_also_allow_opt with
        | Error msg, _ | _, Error msg -> Error msg
        | Ok tool_preset_opt, Ok tool_also_allow_opt ->
            Ok (tool_access_opt, tool_preset_opt, tool_also_allow_opt))

let parse (ctx : _ context) (args : Yojson.Safe.t) : (parsed_args, tool_result) result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    Error (false, "invalid keeper name (allowed: [A-Za-z0-9._-])")
  else
    match reject_legacy_model_args ~tool_name:"masc_keeper_up" args with
    | Error e -> Error (false, e)
    | Ok () ->
    match reject_removed_keeper_input_keys ~tool_name:"masc_keeper_up" args with
    | Error e -> Error (false, e)
    | Ok () ->
    let compaction_profile_opt_res =
      parse_compaction_profile_opt args "compaction_profile"
    in
    let tool_access_input_res = parse_tool_access_input args in
    let allowed_paths_opt_res = parse_present_string_list_opt args "allowed_paths" in
    let sandbox_profile_opt_res =
      parse_enum_string_opt args "sandbox_profile" sandbox_profile_of_string
        ~allowed_values:(String.concat ", " valid_sandbox_profile_strings)
    in
    let network_mode_opt_res =
      parse_enum_string_opt args "network_mode" network_mode_of_string
        ~allowed_values:"none, inherit"
    in
    let shared_memory_scope_opt_res =
      parse_enum_string_opt args "shared_memory_scope"
        shared_memory_scope_of_string
        ~allowed_values:"disabled, room"
    in
    match
      compaction_profile_opt_res, tool_access_input_res, allowed_paths_opt_res,
      sandbox_profile_opt_res, network_mode_opt_res, shared_memory_scope_opt_res
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
      Ok sandbox_profile_opt,
      Ok network_mode_opt,
      Ok shared_memory_scope_opt ->
    let goal_opt = get_string_opt args "goal" in
    let short_goal_opt = parse_goal_horizon_opt args "short_goal" in
    let mid_goal_opt = parse_goal_horizon_opt args "mid_goal" in
    let long_goal_opt = parse_goal_horizon_opt args "long_goal" in
    let policy_voice_enabled_opt = get_bool_opt args "policy_voice_enabled" in
    let autoboot_enabled_opt = get_bool_opt args "autoboot_enabled" in
    let execution_scope_opt =
      get_string_opt args "execution_scope"
      |> Option.map (fun s ->
        match Keeper_execution_scope.of_string s with
        | Ok v -> v
        | Error (`Unknown_scope raw) ->
          Log.Keeper.warn "keeper_up: unknown execution_scope %S, using default" raw;
          Keeper_execution_scope.default)
    in
    let voice_enabled_opt = get_bool_opt args "voice_enabled" in
    let voice_channel_opt = get_string_opt args "voice_channel" in
    let voice_agent_id_opt = get_string_opt args "voice_agent_id" in
    let mention_targets_in = get_string_list args "mention_targets" in
    let max_context_override_opt =
      let min_keeper_context = Keeper_config.min_keeper_context_tokens in
      match Safe_ops.json_int_opt "max_context_override" args with
      | None -> None
      | Some v when v >= min_keeper_context && v <= 1_000_000 -> Some v
      | Some v when v > 0 && v < min_keeper_context ->
          Log.Misc.warn
            "max_context_override=%d below minimum %d, clamped to %d"
            v min_keeper_context min_keeper_context;
          Some min_keeper_context
      | Some v ->
          Log.Misc.warn "max_context_override=%d out of range (%d..1000000), ignored"
            v min_keeper_context;
          None
    in
    let proactive_enabled_opt = get_bool_opt args "proactive_enabled" in
    let proactive_idle_sec_opt = Safe_ops.json_int_opt "proactive_idle_sec" args in
    let proactive_cooldown_sec_opt = Safe_ops.json_int_opt "proactive_cooldown_sec" args in
    let compaction_ratio_gate_opt = Safe_ops.json_float_opt "compaction_ratio_gate" args in
    let compaction_message_gate_opt = Safe_ops.json_int_opt "compaction_message_gate" args in
    let compaction_token_gate_opt = Safe_ops.json_int_opt "compaction_token_gate" args in
    let continuity_compaction_cooldown_sec_opt =
      Safe_ops.json_int_opt "continuity_compaction_cooldown_sec" args
    in
    let tool_denylist_opt_res = parse_present_tool_name_list_opt args "tool_denylist" in
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
      if not (Fs_compat.file_exists soul_path) then (
        Log.Keeper.info "SOUL.md not found for %s (%s)" name soul_path;
        "")
      else
        match Safe_ops.read_file_safe soul_path with
        | Ok c -> c
        | Error e ->
            Log.Keeper.warn "SOUL.md read failed for %s (%s): %s" name soul_path e;
            ""
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
    match tool_denylist_opt_res with
    | Error msg -> Error (false, msg)
    | Ok tool_denylist_opt ->
    Ok {
      name;
      compaction_profile_opt;
      goal_opt;
      short_goal_opt;
      mid_goal_opt;
      long_goal_opt;
      policy_voice_enabled_opt;
      allowed_paths_opt;
      autoboot_enabled_opt;
      execution_scope_opt;
      sandbox_profile_opt;
      network_mode_opt;
      shared_memory_scope_opt;
      voice_enabled_opt;
      voice_channel_opt;
      voice_agent_id_opt;
      mention_targets_in;
      max_context_override_opt;
      proactive_enabled_opt;
      proactive_idle_sec_opt;
      proactive_cooldown_sec_opt;
      compaction_ratio_gate_opt;
      compaction_message_gate_opt;
      compaction_token_gate_opt;
      continuity_compaction_cooldown_sec_opt;
      tool_access_opt;
      tool_preset_opt;
      tool_also_allow_opt;
      tool_denylist_opt;
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

let resolve_sandbox_profile ~preferred ~fallback =
  first_some preferred fallback
  |> Option.value ~default:default_sandbox_profile

let resolve_network_mode ~sandbox_profile ~preferred ~fallback =
  first_some preferred fallback
  |> Option.value ~default:(default_network_mode_for_profile sandbox_profile)

let resolve_shared_memory_scope ~preferred ~fallback =
  first_some preferred fallback
  |> Option.value ~default:default_shared_memory_scope

let private_workspace_root_rel ~sandbox_profile keeper_name =
  Keeper_sandbox.host_root_rel_of_profile sandbox_profile keeper_name
  |> Keeper_alerting_path.strip_trailing_slashes

let private_workspace_root_abs ~(config : Coord.config) ~sandbox_profile keeper_name =
  Filename.concat
    (Keeper_alerting_path.project_root_of_config config)
    (private_workspace_root_rel ~sandbox_profile keeper_name)
  |> Keeper_alerting_path.normalize_path_for_check
  |> Keeper_alerting_path.strip_trailing_slashes

let sandbox_allowed_path_has_forbidden_segments path =
  let has_glob =
    String.exists (function
      | '*' | '?' | '[' | ']' -> true
      | _ -> false)
      path
  in
  has_glob
  || (path
      |> String.split_on_char '/'
      |> List.exists (function
           | "." | ".." -> true
           | _ -> false))

let sandbox_allowed_path_within_private_root
    ~(config : Coord.config)
    ~keeper_name
    ~sandbox_profile
    path =
  let trimmed = String.trim path in
  if trimmed = "" then false
  else if sandbox_allowed_path_has_forbidden_segments trimmed then
    false
  else
    let private_root =
      private_workspace_root_abs ~config ~sandbox_profile keeper_name
    in
    let candidate =
      (if Filename.is_relative trimmed then
         Filename.concat
           (Keeper_alerting_path.project_root_of_config config)
           trimmed
       else
         trimmed)
      |> Keeper_alerting_path.normalize_path_for_check
      |> Keeper_alerting_path.strip_trailing_slashes
    in
    candidate = private_root
    || String.starts_with ~prefix:(private_root ^ "/") candidate

let validate_sandbox_settings
    ~(config : Coord.config)
    ~keeper_name
    ~sandbox_profile
    ~network_mode
    ~allowed_paths =
  match sandbox_profile with
  | Local -> (
      match network_mode with
      | Network_inherit -> Ok ()
      | Network_none ->
          Error
            "network_mode=none requires sandbox_profile=docker")
  | Docker ->
      let profile_label = sandbox_profile_to_string sandbox_profile in
      if allowed_paths = [ "*" ] then
        Error
          (Printf.sprintf
             "%s rejects allowed_paths=[\"*\"]; keep writes inside the private playground root"
             profile_label)
      else
        let escaping =
          List.filter
            (fun path ->
              not
                (sandbox_allowed_path_within_private_root
                   ~config ~keeper_name ~sandbox_profile path))
            allowed_paths
        in
        match escaping with
        | [] -> Ok ()
        | _ ->
            Error
              (Printf.sprintf
                 "%s allowed_paths must stay under %s (rejected: %s)"
                 profile_label
                 (private_workspace_root_rel ~sandbox_profile keeper_name)
                 (String.concat ", " escaping))
