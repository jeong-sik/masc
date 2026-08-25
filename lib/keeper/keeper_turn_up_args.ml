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
  runtime_id_opt : string option;
  allowed_paths_opt : string list option;
  autoboot_enabled_opt : bool option;
  mention_targets_opt : string list option;
  max_context_override_opt : int option;
  max_context_override_present : bool;
  autonomous_wake_prompt_opt : string option;
  autonomous_wake_prompt_present : bool;
  proactive_enabled_opt : bool option;
  sandbox_profile_opt : string option;
  network_mode_opt : string option;
  tool_groups_opt : string list option;
  tool_groups_present : bool;
  native_tool_posture_opt : Runtime_native_tools.posture option;
  native_tool_posture_present : bool;
  instructions_arg : string option;
  profile_defaults : keeper_profile_defaults;
  instructions_opt : string option;
  autonomous_instructions_arg : string option;
  autonomous_instructions_opt : string option;
}

let parse_tools_patch args =
  match Json_util.assoc_member_opt "tools" args with
  | None -> Ok (false, None, false, None)
  | Some (`Assoc fields) ->
      let duplicates =
        fields
        |> List.map fst
        |> List.sort String.compare
        |> List.fold_left
             (fun (previous, duplicates) key ->
                match previous with
                | Some prior when String.equal prior key -> Some key, key :: duplicates
                | _ -> Some key, duplicates)
             (None, [])
        |> snd
        |> List.sort_uniq String.compare
      in
      if duplicates <> []
      then Error ("duplicate tools field(s): " ^ String.concat ", " duplicates)
      else
        let unknown =
          List.filter_map
            (fun (key, _) ->
               if String.equal key "groups" || String.equal key "native"
               then None
               else Some key)
            fields
        in
        if unknown <> []
        then Error ("unsupported tools field(s): " ^ String.concat ", " unknown)
        else
          let groups =
            match List.assoc_opt "groups" fields with
            | None -> Ok (false, None)
            | Some `Null -> Ok (true, None)
            | Some (`List values) ->
              let rec collect acc index = function
                | [] ->
                  let groups = normalize_name_list (List.rev acc) in
                  let unknown =
                    List.filter
                      (fun name -> Option.is_none (Keeper_tool_group.of_string name))
                      groups
                  in
                  if unknown = []
                  then Ok (true, if groups = [] then None else Some groups)
                  else
                    Error
                      ("unknown keeper tool groups: " ^ String.concat ", " unknown)
                | `String value :: rest -> collect (value :: acc) (index + 1) rest
                | bad :: _ ->
                  Error
                    (Printf.sprintf
                       "tools.groups[%d] must be a string (received %s)"
                       index
                       (Json_util.kind_name bad))
              in
              collect [] 0 values
            | Some other ->
              Error
                (Printf.sprintf
                   "tools.groups must be an array of strings or null (received %s)"
                   (Json_util.kind_name other))
          in
          let native =
            match List.assoc_opt "native" fields with
            | None -> Ok (false, None)
            | Some `Null -> Ok (true, None)
            | Some (`String raw) ->
              (match Runtime_native_tools.of_string (String.trim raw) with
               | Some posture -> Ok (true, Some posture)
               | None ->
                 Error
                   (Printf.sprintf
                      "tools.native must be one of %s"
                      (String.concat ", " Runtime_native_tools.valid_posture_strings)))
            | Some other ->
              Error
                (Printf.sprintf
                   "tools.native must be a string or null (received %s)"
                   (Json_util.kind_name other))
          in
          (match groups, native with
           | Ok (tool_groups_present, tool_groups_opt),
             Ok (native_tool_posture_present, native_tool_posture_opt) ->
             Ok
               ( tool_groups_present
               , tool_groups_opt
               , native_tool_posture_present
               , native_tool_posture_opt )
           | Error detail, _ | _, Error detail -> Error detail)
  | Some other ->
    Error
      (Printf.sprintf
         "tools must be an object (received %s)"
         (Json_util.kind_name other))
;;

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
  if v = 0 then Ok None
  else Keeper_config.validate_max_context_override_value v |> Result.map Option.some

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

(* Same shared contract as the fleet env var and the keeper TOML parser
   (Env_config_keeper.KeeperAutonomous.validate_wake_prompt), so no value can
   pass one authoring surface and be rejected by another. Null is the only
   explicit clear: strings have no zero sentinel, and folding "" into a clear
   would make a typo read as "the setting did not take". *)
let parse_autonomous_wake_prompt args =
  match Json_util.assoc_member_opt "autonomous_wake_prompt" args with
  | None -> Ok (false, None)
  | Some `Null -> Ok (true, None)
  | Some (`String raw) ->
      (match Env_config_keeper.KeeperAutonomous.validate_wake_prompt raw with
       | Ok value -> Ok (true, Some value)
       | Error reason ->
           Error (Printf.sprintf "autonomous_wake_prompt: %s" reason))
  | Some other ->
      Error
        (Printf.sprintf
           "autonomous_wake_prompt must be a string or null (received %s)"
           (Json_util.kind_name other))

let parse (ctx : _ context) (args : Yojson.Safe.t) :
    (parsed_args, tool_result) result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    Error (tool_result_error (invalid_name_error name))
  else
    match Keeper_identity.keeper_name_of_agent_alias name with
    (* One parse decides both facts. Asking "is it an alias?" separately forced
       a default keeper name for a case that parse cannot produce, and the
       resulting message named the rejected input as its own replacement. *)
    | Some canonical_name ->
        Error
          (tool_result_error
             (Printf.sprintf
                "invalid keeper name: %S is a runtime agent identity; use the canonical keeper name %S"
                name canonical_name))
    | None ->
    let allowed_paths_opt_res = parse_present_string_list_opt args "allowed_paths" in
    let mention_targets_opt_res = parse_present_string_list_opt args "mention_targets" in
    let runtime_id_opt_res = parse_runtime_id_opt args in
    let tools_patch_res = parse_tools_patch args in
    match
      allowed_paths_opt_res, mention_targets_opt_res,
      runtime_id_opt_res, tools_patch_res
    with
    | Error e, _, _, _
    | _, Error e, _, _
    | _, _, Error e, _
    | _, _, _, Error e -> Error (tool_result_error e)
    | Ok allowed_paths_opt, Ok mention_targets_opt,
      Ok runtime_id_opt,
      Ok
        ( tool_groups_present
        , tool_groups_opt
        , native_tool_posture_present
        , native_tool_posture_opt ) ->
    let autoboot_enabled_opt = get_bool_opt args "autoboot_enabled" in
    let max_context_override_res = parse_max_context_override args in
    let autonomous_wake_prompt_res = parse_autonomous_wake_prompt args in
    let proactive_enabled_opt = get_bool_opt args "proactive_enabled" in
    let sandbox_profile_opt = Safe_ops.json_string_opt "sandbox_profile" args in
    let network_mode_opt = Safe_ops.json_string_opt "network_mode" args in
    let instructions_arg = get_string_opt args "instructions" in
    let autonomous_instructions_arg =
      get_string_opt args "autonomous_instructions"
    in
    match
      load_keeper_profile_defaults_result_for_base_path
        ~base_path:ctx.config.base_path
        name
    with
    | Error error ->
      Error (tool_result_error (keeper_toml_load_error_to_string error))
    | Ok profile_defaults ->
    (* An explicit profile must be valid. When neither the call nor keeper TOML states
       one, creation uses the local sandbox with playground-only writes. This is the
       narrow safe bootstrap: a fresh keeper can start without a hand-authored TOML,
       while docker remains an explicit opt-in. *)
    let sandbox_profile_error =
      match sandbox_profile_opt, profile_defaults.sandbox_profile,
        profile_defaults.manifest_path
      with
      | Some raw, _, _ when Option.is_none (sandbox_profile_of_string raw) ->
        Some
          (Printf.sprintf
             "invalid sandbox_profile: %S (expected: local or docker)"
             raw)
      | Some _, _, _ | None, Some _, _ | None, None, None -> None
      | None, None, Some _ ->
        Some
          (missing_required_sandbox_profile_error
             ~keeper_name:name
             profile_defaults)
    in
    let instructions_opt =
      match instructions_arg with
      | Some _ -> instructions_arg
      | None -> profile_defaults.instructions
    in
    let autonomous_instructions_opt =
      match autonomous_instructions_arg with
      | Some _ -> autonomous_instructions_arg
      | None -> profile_defaults.autonomous_instructions
    in
    match
      sandbox_profile_error, max_context_override_res, autonomous_wake_prompt_res
    with
    | Some msg, _, _ -> Error (tool_result_error msg)
    | None, Error msg, _ -> Error (tool_result_error msg)
    | None, _, Error msg -> Error (tool_result_error msg)
    | None, Ok (max_context_override_present, max_context_override_opt),
      Ok (autonomous_wake_prompt_present, autonomous_wake_prompt_opt) ->
    Ok {
      name;
      runtime_id_opt;
      allowed_paths_opt;
      autoboot_enabled_opt;
      mention_targets_opt;
      max_context_override_opt;
      max_context_override_present;
      autonomous_wake_prompt_opt;
      autonomous_wake_prompt_present;
      proactive_enabled_opt;
      sandbox_profile_opt;
      network_mode_opt;
      tool_groups_opt;
      tool_groups_present;
      native_tool_posture_opt;
      native_tool_posture_present;
      instructions_arg;
      profile_defaults;
      instructions_opt;
      autonomous_instructions_arg;
      autonomous_instructions_opt;
    }

(** Resolve mention targets with dedup and filtering. *)
let resolve_mention_targets ~mention_targets_opt ~fallback_targets ~name =
  let raw =
    match mention_targets_opt with
    | Some targets -> targets
    | None -> if fallback_targets <> [] then fallback_targets else [ name ]
  in
  raw |> List.filter_map String_util.trim_nonempty |> dedupe_keep_order

(* An explicit request wins over the TOML default. Without either source, use the
   canonical local sandbox; creation pairs it with playground-only writes. *)
let resolve_sandbox_profile ?requested ~fallback () =
  match Option.bind requested sandbox_profile_of_string with
  | Some stated -> stated
  | None ->
    (match fallback with
     | Some stated -> stated
     | None -> default_sandbox_profile)

let resolve_network_mode ~sandbox_profile ~fallback =
  fallback
  |> Option.value ~default:(default_network_mode_for_profile sandbox_profile)


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
