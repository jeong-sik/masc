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

let load_from_path ~name path : (keeper_profile_defaults, load_error) result =
  let error kind detail = Error { path; kind; detail } in
  match Safe_ops.read_file_safe path with
  | Error detail -> error Persona_read_error detail
  | Ok content ->
    (match Safe_ops.parse_json_safe ~context:path content with
     | Error detail -> error Persona_parse_error detail
     | Ok json ->
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
        let removed_fields =
          [ "goal"
          ; "active_goal_ids"
          ; "tool_access"
          ; "tool_denylist"
          ; "shards"
          ; "policy_voice_enabled"
          ]
          |> List.filter (fun key ->
            Option.is_some (Json_util.assoc_member_opt key keeper_json))
        in
        if removed_fields <> [] then
          error Persona_parse_error
            (Printf.sprintf
               "removed persona keeper fields are no longer supported: %s"
               (String.concat ", " removed_fields))
        else (
        (* Persona profiles do not own a
           runtime/model selection. Warn so stale manifests are visible. *)
        (match Safe_ops.json_string_opt "model" keeper_json with
         | Some raw ->
             Log.Keeper.warn
               "persona profile %s has a [model] key (%s); ignored - \
                keeper->runtime assignment lives in runtime.toml \
                [[runtime.assignments]]"
               path raw
         | None -> ());
        match keeper_json with
        | `Assoc _ ->
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
              telemetry_feedback_enabled =
                Safe_ops.json_bool_opt "telemetry_feedback_enabled" keeper_json;
              telemetry_feedback_window_hours =
                Safe_ops.json_int_opt "telemetry_feedback_window_hours" keeper_json;
              always_allow = Safe_ops.json_bool_opt "always_allow" keeper_json;
              oas_env = [];
              unknown_toml_keys = [];
              }
        | _ -> Ok { empty_keeper_profile_defaults with manifest_path = Some path })))

let load_from_dirs ~persona_dirs ~name : (keeper_profile_defaults, load_error) result =
  match
    Keeper_types_profile_persona.persona_profile_path_opt_in_dirs persona_dirs name
  with
  | None -> Ok empty_keeper_profile_defaults
  | Some path -> load_from_path ~name path
