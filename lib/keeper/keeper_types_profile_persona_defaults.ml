open Keeper_types_profile_defaults
module Normalizers = Keeper_types_profile_toml_normalizers

let load_from_path ~name path : keeper_profile_defaults =
  match Safe_ops.read_json_file_logged ~label:"load_keeper_profile_defaults" path with
  | None -> empty_keeper_profile_defaults
  | Some json ->
      if
        Keeper_types_profile_persona.reject_placeholder_persona_profile
          ~label:"load_keeper_profile_defaults" ~path json
      then empty_keeper_profile_defaults
      else
        let keeper_json =
          match Json_util.assoc_member_opt "keeper" json with
          | Some v -> v
          | None -> `Null
        in
        let per_provider_timeout_state, per_provider_timeout =
          Normalizers.per_provider_timeout_of_json_field
            ~source:(Printf.sprintf "persona profile %s" path)
            ~field:"per_provider_timeout"
            keeper_json
        in
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
            {
              id = Some (Ids.Keeper_id.generate ~name ~path);
              manifest_path = Some path;
              persona_name = Some name;
              goal = Safe_ops.json_string_opt "goal" keeper_json;
              instructions = Safe_ops.json_string_opt "instructions" keeper_json;
              autoboot_enabled = None;
              mention_targets = Safe_ops.json_string_list "mention_targets" keeper_json;
              proactive_enabled = Safe_ops.json_bool_opt "proactive_enabled" keeper_json;
              proactive_idle_sec = Safe_ops.json_int_opt "proactive_idle_sec" keeper_json;
              proactive_cooldown_sec = Safe_ops.json_int_opt "proactive_cooldown_sec" keeper_json;
              shards =
                (match Safe_ops.json_string_list "shards" keeper_json with
                 | [] -> None
                 | xs -> Some xs);
              allowed_paths = None;
              sandbox_profile = None;
              sandbox_image = None;
              network_mode = None;
              multimodal_policy = None;
              tool_access = None;
              tool_denylist =
                Normalizers.normalize_name_list_opt
                  (Safe_ops.json_string_list "tool_denylist" keeper_json);
              active_goal_ids = None;
              telemetry_feedback_enabled =
                Safe_ops.json_bool_opt "telemetry_feedback_enabled" keeper_json;
              telemetry_feedback_window_hours =
                Safe_ops.json_int_opt "telemetry_feedback_window_hours" keeper_json;
              per_provider_timeout_state;
              per_provider_timeout;
              always_approve = Safe_ops.json_bool_opt "always_approve" keeper_json;
              oas_env = [];
              unknown_toml_keys = [];
            }
        | _ -> { empty_keeper_profile_defaults with manifest_path = Some path }

let load_from_dirs ~persona_dirs ~name : keeper_profile_defaults =
  match
    Keeper_types_profile_persona.persona_profile_path_opt_in_dirs persona_dirs name
  with
  | None -> empty_keeper_profile_defaults
  | Some path -> load_from_path ~name path
