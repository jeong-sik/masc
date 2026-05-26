include Keeper_types_profile_toml_key_validate

let profile_defaults_of_toml (doc : Keeper_toml_loader.toml_doc)
    : (keeper_profile_defaults, string) result =
  let k key = "keeper." ^ key in
  let str key = Keeper_toml_loader.toml_string_opt doc (k key) in
  let bool_ key = Keeper_toml_loader.toml_bool_opt doc (k key) in
  let int_ key = Keeper_toml_loader.toml_int_opt doc (k key) in
  let strs key = Keeper_toml_loader.toml_string_list doc (k key) in
  let has key = List.mem_assoc (k key) doc in
  let has_raw key = List.mem_assoc key doc in
  let tool_access_key key = k ("tool_access." ^ key) in
  let tool_access_defaults_result =
    let kind_key = tool_access_key "kind" in
    let preset_key = tool_access_key "preset" in
    let also_allow_key = tool_access_key "also_allow" in
    let tools_key = tool_access_key "tools" in
    match Keeper_toml_loader.toml_string_opt doc kind_key with
    | None
      when has_raw preset_key || has_raw also_allow_key || has_raw tools_key ->
        Error
          "keeper.tool_access.kind is required when keeper.tool_access.* keys are present"
    | None -> Ok (None, None, None)
    | Some "preset" -> (
        match Keeper_toml_loader.toml_string_opt doc preset_key with
        | None ->
            Error
              "keeper.tool_access.preset is required when keeper.tool_access.kind = \"preset\""
        | Some raw -> (
            match normalize_tool_preset_raw raw with
            | Some normalized ->
                Ok
                  ( Some normalized,
                    normalize_name_list_opt
                      (Keeper_toml_loader.toml_string_list doc also_allow_key),
                    Some "toml" )
            | None ->
                Error
                  (Printf.sprintf
                     "invalid keeper.tool_access.preset '%s' (allowed: %s)"
                     raw
                     (String.concat ", " valid_tool_preset_raw_strings))))
    | Some "custom" ->
        Error
          "keeper.tool_access.kind=\"custom\" cannot be used in keeper TOML defaults yet; use masc_keeper_up tool_access for runtime custom policies"
    | Some raw ->
        Error
          (Printf.sprintf
             "invalid keeper.tool_access.kind '%s' (allowed: preset)"
             raw)
  in
  let per_provider_timeout_state, per_provider_timeout =
    per_provider_timeout_of_toml
      ~source:"keeper TOML"
      doc
      (k "per_provider_timeout")
  in
  let removed_present =
    ("also_allow" :: removed_keeper_input_key_names)
    |> List.map k
    |> List.filter (fun key -> List.mem_assoc key doc)
  in
  let result =
    match removed_present with
    | [] -> Ok ()
    | fields ->
        Error
          (Printf.sprintf
             "removed keeper TOML keys: %s"
             (String.concat ", " fields))
  in
  let result =
    Result.bind result (fun () ->
        match str "persona_name" with
        | Some raw when not (validate_name raw) ->
            Error (Printf.sprintf "invalid persona_name '%s'" raw)
        | _ -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "github_identity" with
        | Some raw when not (validate_name raw) ->
            Error (Printf.sprintf "invalid github_identity '%s'" raw)
        | _ -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "git_identity_mode" with
        | Some raw -> (
            match normalize_git_identity_mode_opt (Some raw) with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid git_identity_mode '%s' (allowed: keeper_alias, github_identity)"
                     raw))
        | None -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "social_model" with
        | Some raw -> (
            match normalize_social_model_opt (Some raw) with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid social_model '%s' (allowed: %s)"
                     raw
                     (String.concat ", " valid_social_model_strings)))
        | None -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "sandbox_profile" with
        | Some raw -> (
            match sandbox_profile_of_string raw with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid sandbox_profile '%s' (allowed: %s)"
                     raw
                     (String.concat ", " valid_sandbox_profile_strings)))
        | None -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "network_mode" with
        | Some raw -> (
            match network_mode_of_string raw with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid network_mode '%s' (allowed: none, inherit)"
                     raw))
        | None -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "cascade_name" with
        | None -> Ok ()
        | Some raw ->
            let raw_normalized = String.trim raw |> String.lowercase_ascii in
            let normalized =
              Keeper_cascade_profile.normalize_declared_name raw
              |> String.lowercase_ascii
            in
            if List.mem raw_normalized reserved_cascade_names
               || List.mem normalized reserved_cascade_names
            then Ok ()
            else
              match Keeper_cascade_profile.catalog_names_for_validation () with
              | Ok catalog ->
                  let all_valid =
                    List.sort_uniq String.compare
                      (reserved_cascade_names @ catalog)
                  in
                  if not (List.mem normalized all_valid) then
                    Error
                      (Printf.sprintf
                         "invalid cascade_name '%s' (known: %s)"
                         raw
                         (String.concat ", " all_valid))
                  else if Keeper_cascade_profile.is_system_only_cascade normalized
                  then
                    let assignable =
                      Keeper_cascade_profile.keeper_catalog_names ()
                    in
                    let assignable_hint =
                      if assignable = [] then "(none)"
                      else String.concat ", " assignable
                    in
                    Error
                      (Printf.sprintf
                         "cascade_name '%s' is system-only \
                          (keeper_assignable=false); keepers must \
                          reference an assignable cascade. \
                          Assignable: %s"
                         raw assignable_hint)
                  else Ok ()
              | Error fallback_error ->
                  Error
                    (Printf.sprintf
                       "invalid cascade_name '%s' (reserved: %s; %s)"
                       raw
                       (String.concat ", " reserved_cascade_names)
                       fallback_error))
  in
  let result =
    Result.bind result (fun () ->
        let has_proactive_idle = has "proactive_idle_sec" in
        let has_proactive_cooldown = has "proactive_cooldown_sec" in
        match (has_proactive_idle, has_proactive_cooldown) with
        | false, true ->
            Error
              "proactive_cooldown_sec is set but proactive_idle_sec is missing"
        | true, false ->
            Error
              "proactive_idle_sec is set but proactive_cooldown_sec is missing"
        | _ -> Ok ())
  in
  let result =
    Result.bind result (fun () -> tool_access_defaults_result)
  in
  Result.map
    (fun (tool_preset, tool_also_allow, tool_preset_source) ->
      {
        id = None;
        manifest_path = None;
        persona_name = str "persona_name";
        goal = str "goal";
        short_goal =
          str "short_goal"
          |> normalize_goal_horizon_opt;
        mid_goal =
          str "mid_goal"
          |> normalize_goal_horizon_opt;
        long_goal =
          str "long_goal"
          |> normalize_goal_horizon_opt;
        will = str "will";
        needs = str "needs";
        desires = str "desires";
        instructions = str "instructions";
        autoboot_enabled = bool_ "autoboot_enabled";
        mention_targets = strs "mention_targets";
        proactive_enabled = bool_ "proactive_enabled";
        proactive_idle_sec = int_ "proactive_idle_sec";
        proactive_cooldown_sec = int_ "proactive_cooldown_sec";
        room_signal_prompt_enabled = bool_ "room_signal_prompt_enabled";
        shards =
          (match strs "shards" with
           | [] -> None
           | xs -> Some xs);
        allowed_paths =
          if has "allowed_paths" then Some (strs "allowed_paths")
          else None;
        sandbox_profile =
          Option.bind (str "sandbox_profile") sandbox_profile_of_string;
        sandbox_image = str "sandbox_image";
        network_mode =
          Option.bind (str "network_mode") network_mode_of_string;
        github_identity = str "github_identity";
        git_identity_mode =
          normalize_git_identity_mode_opt (str "git_identity_mode");
        tool_preset;
        tool_preset_source;
        tool_also_allow;
        tool_denylist = normalize_name_list_opt (strs "tool_denylist");
        active_goal_ids =
          if has "active_goal_ids" then
            Some (normalize_name_list (strs "active_goal_ids"))
          else None;
        work_discovery_enabled = bool_ "work_discovery_enabled";
        work_discovery_sources =
          (match strs "work_discovery_sources" with
           | [] -> None
           | xs -> Some xs);
        work_discovery_interval_sec = int_ "work_discovery_interval_sec";
        work_discovery_guidance = str "work_discovery_guidance";
        telemetry_feedback_enabled = bool_ "telemetry_feedback_enabled";
        telemetry_feedback_window_hours = int_ "telemetry_feedback_window_hours";
        per_provider_timeout_state;
        per_provider_timeout;
        always_approve = bool_ "always_approve";
        max_turns_per_call = int_ "max_turns_per_call";
        max_turns_per_call_scheduled_autonomous =
          int_ "max_turns_per_call_scheduled_autonomous";
        social_model = normalize_social_model_opt (str "social_model");
        cascade_name = normalize_cascade_name_opt (str "cascade_name");
        models = None;
        oas_env = extract_oas_env_from_doc doc;
        unknown_toml_keys = [];
      })
    result

let merge_string_list ~base overlay =
  match overlay with [] -> base | xs -> xs

let merge_keeper_profile_defaults
    ~agent_name
    ~(base : keeper_profile_defaults)
    ~(overlay : keeper_profile_defaults) : keeper_profile_defaults =
  ignore agent_name;
  let prefer overlay_value base_value =
    match overlay_value with Some _ -> overlay_value | None -> base_value
  in
  let per_provider_timeout_state, per_provider_timeout =
    match overlay.per_provider_timeout_state with
    | Per_provider_timeout_unset ->
        base.per_provider_timeout_state, base.per_provider_timeout
    | Per_provider_timeout_invalid ->
        Per_provider_timeout_invalid, None
    | Per_provider_timeout_set ->
        Per_provider_timeout_set, overlay.per_provider_timeout
  in
  {
    id = prefer overlay.id base.id;
    manifest_path = prefer overlay.manifest_path base.manifest_path;
    persona_name = prefer overlay.persona_name base.persona_name;
    goal = prefer overlay.goal base.goal;
    short_goal = prefer overlay.short_goal base.short_goal;
    mid_goal = prefer overlay.mid_goal base.mid_goal;
    long_goal = prefer overlay.long_goal base.long_goal;
    will = prefer overlay.will base.will;
    needs = prefer overlay.needs base.needs;
    desires = prefer overlay.desires base.desires;
    instructions = prefer overlay.instructions base.instructions;
    autoboot_enabled = prefer overlay.autoboot_enabled base.autoboot_enabled;
    mention_targets =
      merge_string_list ~base:base.mention_targets overlay.mention_targets;
    proactive_enabled = prefer overlay.proactive_enabled base.proactive_enabled;
    proactive_idle_sec = prefer overlay.proactive_idle_sec base.proactive_idle_sec;
    proactive_cooldown_sec =
      prefer overlay.proactive_cooldown_sec base.proactive_cooldown_sec;
    room_signal_prompt_enabled =
      prefer overlay.room_signal_prompt_enabled base.room_signal_prompt_enabled;
    shards = prefer overlay.shards base.shards;
    allowed_paths = prefer overlay.allowed_paths base.allowed_paths;
    sandbox_profile = prefer overlay.sandbox_profile base.sandbox_profile;
    sandbox_image = prefer overlay.sandbox_image base.sandbox_image;
    network_mode = prefer overlay.network_mode base.network_mode;
    github_identity = prefer overlay.github_identity base.github_identity;
    git_identity_mode =
      prefer overlay.git_identity_mode base.git_identity_mode;
    tool_preset = prefer overlay.tool_preset base.tool_preset;
    tool_preset_source =
      (match overlay.tool_preset_source with
       | Some _ as source -> source
       | None ->
         match overlay.tool_preset with
       | Some _ -> Some "toml"
       | None ->
           match base.tool_preset with
           | Some _ -> Some "persona"
           | None -> None);
    tool_also_allow = prefer overlay.tool_also_allow base.tool_also_allow;
    tool_denylist = prefer overlay.tool_denylist base.tool_denylist;
    active_goal_ids = prefer overlay.active_goal_ids base.active_goal_ids;
    work_discovery_enabled =
      prefer overlay.work_discovery_enabled base.work_discovery_enabled;
    work_discovery_sources =
      prefer overlay.work_discovery_sources base.work_discovery_sources;
    work_discovery_interval_sec =
      prefer overlay.work_discovery_interval_sec base.work_discovery_interval_sec;
    work_discovery_guidance =
      prefer overlay.work_discovery_guidance base.work_discovery_guidance;
    telemetry_feedback_enabled =
      prefer overlay.telemetry_feedback_enabled base.telemetry_feedback_enabled;
    telemetry_feedback_window_hours =
      prefer overlay.telemetry_feedback_window_hours
        base.telemetry_feedback_window_hours;
    per_provider_timeout_state;
    per_provider_timeout;
    always_approve = prefer overlay.always_approve base.always_approve;
    social_model = prefer overlay.social_model base.social_model;
    cascade_name = prefer overlay.cascade_name base.cascade_name;
    models = None;
    max_turns_per_call = prefer overlay.max_turns_per_call base.max_turns_per_call;
    max_turns_per_call_scheduled_autonomous =
      prefer overlay.max_turns_per_call_scheduled_autonomous
        base.max_turns_per_call_scheduled_autonomous;
    oas_env =
      (let overlay_keys = List.map fst overlay.oas_env in
       let surviving_base =
         List.filter (fun (k, _) -> not (List.mem k overlay_keys)) base.oas_env
       in
       surviving_base @ overlay.oas_env);
    unknown_toml_keys =
      merge_string_list ~base:base.unknown_toml_keys overlay.unknown_toml_keys;
  }
