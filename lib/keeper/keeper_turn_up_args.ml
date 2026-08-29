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
  autoboot_enabled_opt : bool option;
  mention_targets_opt : string list option;
  max_context_override_opt : int option;
  max_context_override_present : bool;
  autonomous_wake_prompt_opt : string option;
  autonomous_wake_prompt_present : bool;
  proactive_enabled_opt : bool option;
  sandbox_profile_opt : string option;
  remote_endpoint_opt : string option;
  remote_endpoint_present : bool;
  network_mode_opt : string option;
  skill_names_opt : string list option;
  skill_names_present : bool;
  native_tool_posture_opt : Runtime_native_tools.posture option;
  native_tool_posture_present : bool;
  instructions_arg : string option;
  profile_defaults : keeper_profile_defaults;
  declarative_manifest_snapshot : declarative_manifest_snapshot;
  instructions_opt : string option;
  autonomous_instructions_arg : string option;
  autonomous_instructions_opt : string option;
}

let parse_tools_patch args =
  match Json_util.assoc_member_opt "tools" args with
  | None -> Ok (false, None)
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
               if String.equal key "native"
               then None
               else Some key)
            fields
        in
        if unknown <> []
        then Error ("unsupported tools field(s): " ^ String.concat ", " unknown)
        else
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
          (match native with
           | Ok (native_tool_posture_present, native_tool_posture_opt) ->
             Ok (native_tool_posture_present, native_tool_posture_opt)
           | Error detail -> Error detail)
  | Some other ->
    Error
      (Printf.sprintf
         "tools must be an object (received %s)"
         (Json_util.kind_name other))
;;

let parse_skills_patch args =
  match Json_util.assoc_member_opt "skills" args with
  | None -> Ok (false, None)
  | Some (`Assoc []) -> Ok (true, None)
  | Some (`Assoc [ ("names", `List values) ]) ->
    let rec collect acc index = function
      | [] -> Ok (true, Some (Json_util.dedupe_keep_order (List.rev acc)))
      | `String value :: rest -> collect (value :: acc) (index + 1) rest
      | bad :: _ ->
        Error
          (Printf.sprintf
             "skills.names[%d] must be a string (received %s)"
             index
             (Json_util.kind_name bad))
    in
    collect [] 0 values
  | Some (`Assoc fields) ->
    Error
      ("unsupported skills field(s): "
       ^ String.concat ", " (List.map fst fields))
  | Some other ->
    Error
      (Printf.sprintf
         "skills must be an object (received %s)"
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

let parse_remote_endpoint args =
  match Json_util.assoc_member_opt "remote_endpoint" args with
  | None -> Ok (false, None)
  | Some `Null -> Ok (true, None)
  | Some (`String raw) ->
      let endpoint = String.trim raw in
      if endpoint = ""
      then Error "remote_endpoint must not be blank"
      else Ok (true, Some endpoint)
  | Some other ->
      Error
        (Printf.sprintf
           "remote_endpoint must be a string or null (received %s)"
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
    Error (tool_result_error ~class_:Tool_result.Policy_rejection (invalid_name_error name))
  else
    let mention_targets_opt_res = parse_present_string_list_opt args "mention_targets" in
    let runtime_id_opt_res = parse_runtime_id_opt args in
    let tools_patch_res = parse_tools_patch args in
    let skills_patch_res = parse_skills_patch args in
    match
      mention_targets_opt_res,
      runtime_id_opt_res, tools_patch_res, skills_patch_res
    with
    | Error e, _, _, _
    | _, Error e, _, _
    | _, _, Error e, _
    | _, _, _, Error e -> Error (tool_result_error ~class_:Tool_result.Policy_rejection e)
    | Ok mention_targets_opt,
      Ok runtime_id_opt,
      Ok (native_tool_posture_present, native_tool_posture_opt),
      Ok (skill_names_present, skill_names_opt) ->
    let autoboot_enabled_opt = get_bool_opt args "autoboot_enabled" in
    let max_context_override_res = parse_max_context_override args in
    let autonomous_wake_prompt_res = parse_autonomous_wake_prompt args in
    let proactive_enabled_opt = get_bool_opt args "proactive_enabled" in
    let sandbox_profile_opt = Safe_ops.json_string_opt "sandbox_profile" args in
    let remote_endpoint_res = parse_remote_endpoint args in
    let network_mode_opt = Safe_ops.json_string_opt "network_mode" args in
    let instructions_arg = get_string_opt args "instructions" in
    let autonomous_instructions_arg =
      get_string_opt args "autonomous_instructions"
    in
    match
      load_declarative_materialization_defaults
        ~base_path:ctx.config.base_path
        name
    with
    | Error error ->
      Error (tool_result_error ~class_:Tool_result.Policy_rejection (keeper_toml_load_error_to_string error))
    | Ok { profile_defaults; manifest_snapshot = declarative_manifest_snapshot } ->
    (* An explicit profile must be valid. When neither the call nor keeper TOML states
       one, resolution falls back to [Local] (playground-only writes) — which
       create/update validation rejects unless the MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1
       dev/test hatch is set. Docker remains an explicit opt-in. *)
    let sandbox_profile_error =
      match sandbox_profile_opt, profile_defaults.sandbox_profile,
        profile_defaults.manifest_path
      with
      | Some raw, _, _ when Option.is_none (sandbox_profile_of_string raw) ->
        Some
          (Printf.sprintf
             "invalid sandbox_profile: %S (expected: local, docker, microvm, or remote_ssh)"
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
    let remote_endpoint_error =
      match sandbox_profile_error, remote_endpoint_res with
      | Some _, _ -> None
      | None, Error error -> Some error
      | None, Ok (remote_endpoint_present, remote_endpoint_opt) ->
        let sandbox_profile =
          match Option.bind sandbox_profile_opt sandbox_profile_of_string with
          | Some profile -> profile
          | None ->
            Option.value profile_defaults.sandbox_profile
              ~default:default_sandbox_profile
        in
        let endpoint_name =
          if remote_endpoint_present
          then remote_endpoint_opt
          else profile_defaults.remote_endpoint
        in
        (match sandbox_profile, endpoint_name with
         | Remote_ssh, None ->
           Some
             "remote_ssh_endpoint_missing: sandbox_profile=remote_ssh requires remote_endpoint"
         | Remote_ssh, Some endpoint_name ->
           (match
              Keeper_sandbox_ssh.resolve_endpoint_name
                ~base_path:ctx.config.base_path ~name:endpoint_name
            with
            | Error error -> Some error
            | Ok endpoint ->
              if not (Env_config_sandbox.Preflight.enabled ())
              then None
              else
                (match
                   Keeper_sandbox_ssh.create ~base_path:ctx.config.base_path
                     ~keeper_name:name ~endpoint ()
                 with
                 | Error error -> Some error
                 | Ok ssh ->
                   (match Keeper_sandbox_ssh.check_preflight ~force:true ssh with
                    | Ok () -> None
                    | Error error -> Some error)))
         | (Local | Docker | Micro_vm), Some _ ->
           Some
             "remote_endpoint_requires_remote_ssh: clear remote_endpoint or select sandbox_profile=remote_ssh"
         | (Local | Docker | Micro_vm), None -> None)
    in
    match
      sandbox_profile_error, remote_endpoint_error,
      max_context_override_res, autonomous_wake_prompt_res
    with
    | Some msg, _, _, _
    | None, Some msg, _, _ ->
      Error (tool_result_error ~class_:Tool_result.Policy_rejection msg)
    | None, None, Error msg, _ ->
      Error (tool_result_error ~class_:Tool_result.Policy_rejection msg)
    | None, None, _, Error msg ->
      Error (tool_result_error ~class_:Tool_result.Policy_rejection msg)
    | None, None, Ok (max_context_override_present, max_context_override_opt),
      Ok (autonomous_wake_prompt_present, autonomous_wake_prompt_opt) ->
    let remote_endpoint_present, remote_endpoint_opt =
      match remote_endpoint_res with
      | Ok value -> value
      | Error _ -> false, None
    in
    Ok {
      name;
      runtime_id_opt;
      autoboot_enabled_opt;
      mention_targets_opt;
      max_context_override_opt;
      max_context_override_present;
      autonomous_wake_prompt_opt;
      autonomous_wake_prompt_present;
      proactive_enabled_opt;
      sandbox_profile_opt;
      remote_endpoint_opt;
      remote_endpoint_present;
      network_mode_opt;
      skill_names_opt;
      skill_names_present;
      native_tool_posture_opt;
      native_tool_posture_present;
      instructions_arg;
      profile_defaults;
      declarative_manifest_snapshot;
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

(* An explicit request wins over the TOML default. Without either source, the
   fallback resolves to [Local] — which keeper-up create/update validation
   rejects fail-closed unless the MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1 dev/test
   hatch is set (config-load gating follows in the same plan). *)
let resolve_sandbox_profile ?requested ~fallback () =
  match Option.bind requested sandbox_profile_of_string with
  | Some stated -> stated
  | None ->
    (match fallback with
     | Some stated -> stated
     | None -> default_sandbox_profile)

(* Fail-closed gate: the local playground is off unless the operator sets the
   hatch.  See [Env_config_sandbox.Gate] for the SSOT. *)
let validate_sandbox_profile_allowed ~profile =
  match profile with
  | Local when not (Env_config_sandbox.Gate.allow_local_playground ()) ->
    Error Env_config_sandbox.Gate.disabled_message
  | _ -> Ok ()

let resolve_network_mode ~sandbox_profile ~fallback =
  fallback
  |> Option.value ~default:(default_network_mode_for_profile sandbox_profile)


let validate_sandbox_settings_with_profile ~sandbox_profile =
  validate_sandbox_profile_allowed ~profile:sandbox_profile
