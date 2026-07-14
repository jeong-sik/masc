(** Keeper_turn_up_args -- parse and bundle tool arguments for keeper_up.

    Extracts all argument parsing from handle_keeper_up into a single
    record so that create/update branches receive structured data
    instead of 60+ local bindings. *)

open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type parsed_args = {
  name : string;
  compaction_profile_opt : string option;
  runtime_id_opt : string option;
  allowed_paths_opt : string list option;
  autoboot_enabled_opt : bool option;
  mention_targets_opt : string list option;
  active_goal_ids_opt : string list option;
  max_context_override_opt : int option;
  max_context_override_present : bool;
  proactive_enabled_opt : bool option;
  compaction_ratio_gate_opt : float option;
  compaction_message_gate_opt : int option;
  compaction_token_gate_opt : int option;
  compaction_cooldown_sec_opt : int option;
  sandbox_profile_opt : string option;
  network_mode_opt : string option;
  auto_handoff_opt : bool option;
  handoff_threshold_opt : float option;
  handoff_cooldown_sec_opt : int option;
  instructions_arg : string option;
  profile_defaults : keeper_profile_defaults;
  instructions_opt : string option;
}

let json_non_null_member_present key (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some `Null | None -> false
      | Some _ -> true)
  | _ -> false

let parse_present_string_list_opt args key =
  match Json_util.assoc_member_opt key args with
  | None -> Ok None
  | Some (`List items) ->
      let rec collect acc index = function
        | [] -> Ok (Some (normalize_name_list (List.rev acc)))
        | `String value :: rest -> collect (value :: acc) (index + 1) rest
        | bad :: _ ->
            Error
              (Printf.sprintf "%s[%d] must be a string (received %s)" key
                 index (Json_util.kind_name bad))
      in
      collect [] 0 items
  | Some `Null -> Error (Printf.sprintf "%s must not be null" key)
  | Some other ->
      Error
        (Printf.sprintf "%s must be an array of strings (received %s)" key
           (Json_util.kind_name other))

let parse_runtime_id_opt args =
  match Json_util.assoc_member_opt "runtime_id" args with
  | None | Some `Null -> Ok None
  | Some (`String raw) ->
      let runtime_id = String.trim raw in
      if runtime_id = ""
      then Error "runtime_id must not be empty"
      else Ok (Some runtime_id)
  | Some other ->
      Error
        (Printf.sprintf
           "runtime_id must be a string (received %s)"
           (Json_util.kind_name other))

let normalize_max_context_override_value v =
  let min_keeper_context = Keeper_config.min_keeper_context_tokens in
  let max_keeper_context = Keeper_config.max_keeper_context_tokens in
  if v = 0 then Ok None
  else if v >= min_keeper_context && v <= max_keeper_context then Ok (Some v)
  else if v > 0 && v < min_keeper_context then (
    Log.Misc.warn
      "max_context_override=%d below minimum %d, clamped to %d"
      v min_keeper_context min_keeper_context;
    Ok (Some min_keeper_context))
  else
    Error
      (Printf.sprintf "max_context_override=%d out of range (0 or %d..%d)"
         v min_keeper_context max_keeper_context)

let parse_max_context_override args =
  match Json_util.assoc_member_opt "max_context_override" args with
  | None -> Ok (false, None)
  | Some `Null -> Ok (true, None)
  | Some (`Int v) ->
      Result.map (fun value -> (true, value))
        (normalize_max_context_override_value v)
  | Some (`Intlit raw) -> (
      match int_of_string_opt raw with
      | Some v ->
          Result.map (fun value -> (true, value))
            (normalize_max_context_override_value v)
      | None ->
          Error
            (Printf.sprintf
               "max_context_override must be an integer or null (received %s)"
               raw))
  | Some other ->
      Error
        (Printf.sprintf
           "max_context_override must be an integer or null (received %s)"
           (Json_util.kind_name other))

let parse ?(allow_sandbox_fields = false) (ctx : _ context) (args : Yojson.Safe.t) :
    (parsed_args, tool_result) result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    Error (tool_result_error (invalid_name_error name))
  else
    match Keeper_meta_contract.reject_removed_model_args ~tool_name:"masc_keeper_up" args with
    | Error e -> Error (tool_result_error e)
    | Ok () ->
    match
      reject_removed_keeper_input_keys ~allow_sandbox_fields
        ~tool_name:"masc_keeper_up" args
    with
    | Error e -> Error (tool_result_error e)
    | Ok () ->
    let compaction_profile_opt_res =
      parse_compaction_profile_opt args "compaction_profile"
    in
    let allowed_paths_opt_res = parse_present_string_list_opt args "allowed_paths" in
    let active_goal_ids_opt_res = parse_present_string_list_opt args "active_goal_ids" in
    let mention_targets_opt_res = parse_present_string_list_opt args "mention_targets" in
    let runtime_id_opt_res = parse_runtime_id_opt args in
    match
      compaction_profile_opt_res, allowed_paths_opt_res,
      active_goal_ids_opt_res, mention_targets_opt_res, runtime_id_opt_res
    with
    | Error e, _, _, _, _
    | _, Error e, _, _, _
    | _, _, Error e, _, _
    | _, _, _, Error e, _
    | _, _, _, _, Error e -> Error (tool_result_error e)
    | Ok compaction_profile_opt,
      Ok allowed_paths_opt,
      Ok active_goal_ids_opt,
      Ok mention_targets_opt,
      Ok runtime_id_opt ->
    let autoboot_enabled_opt = get_bool_opt args "autoboot_enabled" in
    let max_context_override_res = parse_max_context_override args in
    let proactive_enabled_opt = get_bool_opt args "proactive_enabled" in
    let compaction_ratio_gate_opt = Safe_ops.json_float_opt "compaction_ratio_gate" args in
    let compaction_message_gate_opt = Safe_ops.json_int_opt "compaction_message_gate" args in
    let compaction_token_gate_opt = Safe_ops.json_int_opt "compaction_token_gate" args in
    let compaction_cooldown_sec_opt =
      Safe_ops.json_int_opt "compaction_cooldown_sec" args
    in
    let sandbox_profile_opt = Safe_ops.json_string_opt "sandbox_profile" args in
    let network_mode_opt = Safe_ops.json_string_opt "network_mode" args in
    let auto_handoff_opt = get_bool_opt args "auto_handoff" in
    let handoff_threshold_opt = Safe_ops.json_float_opt "handoff_threshold" args in
    let handoff_cooldown_sec_opt = Safe_ops.json_int_opt "handoff_cooldown_sec" args in
    let instructions_arg = get_string_opt args "instructions" in
    match
      load_keeper_profile_defaults_result_for_base_path
        ~base_path:ctx.config.base_path
        name
    with
    | Error error ->
      Error (tool_result_error (keeper_toml_load_error_to_string error))
    | Ok profile_defaults ->
    let sandbox_profile_error =
      match profile_defaults.sandbox_profile with
      | None ->
        Some
          (missing_required_sandbox_profile_error
             ~keeper_name:name
             profile_defaults)
      | Some _ -> None
    in
    (* The previous implementation read [<base>/memory/souls/<name>/SOUL.md]
       on every keeper turn-up and wrapped the resulting (or "not found")
       text into a "[SYSTEM: SOUL INFUSION]" block prepended to the
       keeper's instructions.  No production keeper ships a SOUL.md
       and no spec defines one — the directory does not exist on any
       host — so the path emitted an INFO log every cycle and silently
       polluted every keeper's instructions with a fallback string.
       Removed; instructions now reflect only the operator-supplied
       argument or the keeper profile default. *)
    let instructions_opt =
      match instructions_arg with
      | Some _ -> instructions_arg
      | None -> profile_defaults.instructions
    in
    match sandbox_profile_error, max_context_override_res with
    | Some msg, _ -> Error (tool_result_error msg)
    | None, Error msg -> Error (tool_result_error msg)
    | None, Ok (max_context_override_present, max_context_override_opt) ->
    Ok {
      name;
      compaction_profile_opt;
      runtime_id_opt;
      allowed_paths_opt;
      active_goal_ids_opt;
      autoboot_enabled_opt;
      mention_targets_opt;
      max_context_override_opt;
      max_context_override_present;
      proactive_enabled_opt;
      compaction_ratio_gate_opt;
      compaction_message_gate_opt;
      compaction_token_gate_opt;
      compaction_cooldown_sec_opt;
      sandbox_profile_opt;
      network_mode_opt;
      auto_handoff_opt;
      handoff_threshold_opt;
      handoff_cooldown_sec_opt;
      instructions_arg;
      profile_defaults;
      instructions_opt;
    }

(** Resolve mention targets with dedup and filtering. *)
let resolve_mention_targets ~mention_targets_opt ~fallback_targets ~name =
  let raw =
    match mention_targets_opt with
    | Some targets -> targets
    | None -> if fallback_targets <> [] then fallback_targets else [ name ]
  in
  raw |> List.filter_map String_util.trim_nonempty |> dedupe_keep_order

let resolve_sandbox_profile ~fallback =
  fallback
  |> Option.value ~default:default_sandbox_profile

let resolve_network_mode ~sandbox_profile ~fallback =
  fallback
  |> Option.value ~default:(default_network_mode_for_profile sandbox_profile)


let private_workspace_root_rel ~sandbox_profile keeper_name =
  Keeper_sandbox.host_root_rel_of_profile sandbox_profile keeper_name
  |> Keeper_alerting_path.strip_trailing_slashes

let private_workspace_root_abs ~(config : Workspace.config) ~sandbox_profile keeper_name =
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

let validate_sandbox_settings ~allowed_paths =
  if allowed_paths = [ "*" ] then
    Error "allowed_paths=[\"*\"] is not supported; enumerate explicit paths instead"
  else
    match
      List.filter sandbox_allowed_path_has_forbidden_segments allowed_paths
    with
    | [] -> Ok ()
    | rejected ->
        Error
          (Printf.sprintf
             "allowed_paths entries may not contain globs or traversal segments \
              (rejected: %s)"
             (String.concat ", " rejected))
