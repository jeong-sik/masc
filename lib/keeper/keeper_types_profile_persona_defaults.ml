open Keeper_types_profile_defaults
module Normalizers = Keeper_types_profile_toml_normalizers

type load_error_kind =
  | Persona_read_error
  | Persona_parse_error

type load_error =
  { path : string
  ; kind : load_error_kind
  ; detail : string
  }

let supported_keeper_fields =
  [ "always_allow"
  ; "instructions"
  ; "mention_targets"
  ; "proactive_enabled"
  ; "telemetry_feedback_enabled"
  ; "telemetry_feedback_window_hours"
  ]

let unsupported_keeper_fields = function
  | `Assoc fields ->
      fields
      |> List.filter_map (fun (key, _) ->
        if List.mem key supported_keeper_fields then None else Some key)
      |> List.sort_uniq String.compare
  | _ -> []

let load_from_path ~name path : (keeper_profile_defaults, load_error) result =
  let error kind detail = Error { path; kind; detail } in
  match Safe_ops.read_file_safe path with
  | Error detail -> error Persona_read_error detail
  | Ok content ->
    (match Safe_ops.parse_json_safe ~context:path content with
     | Error detail -> error Persona_parse_error detail
     | Ok (`Assoc _ as json) ->
      if
        Keeper_types_profile_persona.reject_placeholder_persona_profile
          ~label:"load_keeper_profile_defaults" ~path json
      then Ok empty_keeper_profile_defaults
      else (
        let keeper_json =
          match Json_util.assoc_member_opt "keeper" json with
          | Some v -> v
          | None -> `Null
        in
        match keeper_json with
        | `Assoc _ ->
          let unsupported_fields = unsupported_keeper_fields keeper_json in
          if unsupported_fields <> [] then
            error Persona_parse_error
              (Printf.sprintf
                 "unsupported persona keeper fields: %s. Supported fields: %s"
                 (String.concat ", " unsupported_fields)
                 (String.concat ", " supported_keeper_fields))
          else
            Ok
              {
              id = Some (Ids.Keeper_id.generate ~name ~path);
              manifest_path = Some path;
              persona_name = Some name;
              instructions = Safe_ops.json_string_opt "instructions" keeper_json;
              autoboot_enabled = None;
              mention_targets = Safe_ops.json_string_list "mention_targets" keeper_json;
              proactive_enabled = Safe_ops.json_bool_opt "proactive_enabled" keeper_json;
              allowed_paths = None;
              sandbox_profile = None;
              sandbox_image = None;
              network_mode = None;
              multimodal_policy = None;
              active_goal_ids = None;
              max_context_override = None;
              telemetry_feedback_enabled =
                Safe_ops.json_bool_opt "telemetry_feedback_enabled" keeper_json;
              telemetry_feedback_window_hours =
                Safe_ops.json_int_opt "telemetry_feedback_window_hours" keeper_json;
              always_allow = Safe_ops.json_bool_opt "always_allow" keeper_json;
              oas_env = [];
              unknown_toml_keys = [];
              }
        | `Null ->
            Ok { empty_keeper_profile_defaults with manifest_path = Some path }
        | _ ->
            error Persona_parse_error
              "persona profile field [keeper] must be a JSON object")
     | Ok _ ->
       error Persona_parse_error "persona profile root must be a JSON object")

let load_from_dirs ~persona_dirs ~name : (keeper_profile_defaults, load_error) result =
  match
    Keeper_types_profile_persona.persona_profile_path_opt_in_dirs persona_dirs name
  with
  | None -> Ok empty_keeper_profile_defaults
  | Some path -> load_from_path ~name path
