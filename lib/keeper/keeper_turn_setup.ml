(** Keeper_turn_setup -- keeper creation and settings update.

    Extracted from keeper_turn.ml.  Provides [ensure_keeper_exists] and
    [apply_settings_update]. *)

open Tool_args
open Keeper_types
open Keeper_execution

let ensure_keeper_exists
    ~(ctx : _ context)
    ~name
    ~require_existing
    ~(profile_defaults : keeper_profile_defaults)
    ~inline_goal
    ~inline_short_goal
    ~inline_mid_goal
    ~inline_long_goal
    ~inline_instructions
    ~inline_will
    ~inline_needs
    ~inline_desires
    ~inline_soul_profile
    ~inline_models
  : (keeper_meta, string) result =
  match read_meta ctx.config name with
  | Error e -> Error e
  | Ok (Some m) -> Ok m
  | Ok None ->
    if require_existing then
      Error (Printf.sprintf "keeper not found: %s" name)
    else
    let goal =
      match inline_goal with
      | Some goal -> normalize_goal_horizon_text goal
      | None ->
          profile_defaults.goal |> Option.value ~default:""
          |> normalize_goal_horizon_text
    in
    let inline_models =
      if inline_models <> [] then inline_models
      else if profile_defaults.models <> [] then profile_defaults.models
      else profile_defaults.allowed_models
    in
    if goal = "" then Error "keeper not found and goal not provided"
    else if inline_models = [] then Error "keeper not found and models not provided"
    else
    let now_ts = Time_compat.now () in
    let trace_id = generate_trace_id () in
    let soul_profile =
      Option.value
        ~default:(Option.value ~default:default_soul_profile profile_defaults.soul_profile)
        inline_soul_profile
    in
    let will =
      Option.value
        ~default:(Option.value ~default:default_keeper_will profile_defaults.will)
        inline_will
    in
    let needs =
      Option.value
        ~default:(Option.value ~default:default_keeper_needs profile_defaults.needs)
        inline_needs
    in
    let desires =
      Option.value
        ~default:(Option.value ~default:default_keeper_desires profile_defaults.desires)
        inline_desires
    in
    let (env_ratio_gate, env_message_gate, env_token_gate) =
      keeper_compaction_policy_from_env ()
    in
    let continuity_compaction_cooldown_sec =
      keeper_continuity_compaction_cooldown_sec ()
      |> normalize_continuity_compaction_cooldown_sec
    in
    let (short_goal, mid_goal, long_goal) =
      resolve_goal_horizons
        ~goal
        ~short_goal_opt:(first_some inline_short_goal profile_defaults.short_goal)
        ~mid_goal_opt:(first_some inline_mid_goal profile_defaults.mid_goal)
        ~long_goal_opt:(first_some inline_long_goal profile_defaults.long_goal)
    in
    let instructions =
      Option.value ~default:(Option.value ~default:"" profile_defaults.instructions)
        inline_instructions
    in
    let allowed_models =
      resolve_allowed_models
        ~explicit_allowed_models:[]
        ~seed_allowed_models:profile_defaults.allowed_models
        ~models:inline_models
    in
    let active_model =
      profile_defaults.active_model
      |> Option.value
           ~default:
             (match inline_models with
              | model :: _ -> model
              | [] -> "")
    in
    let policy_mode =
      (if default_voice_enabled_for name then None else profile_defaults.policy_mode)
      |> Option.value
           ~default:
             (if default_voice_enabled_for name then "explicit_event_v1"
              else "heuristic")
      |> canonical_policy_mode
    in
    let policy_voice_enabled =
      (if not (default_voice_enabled_for name) then profile_defaults.policy_voice_enabled else None)
      |> Option.value ~default:false
    in
    let policy_shell_mode =
      (if not (default_voice_enabled_for name) then profile_defaults.policy_shell_mode else None)
      |> Option.value ~default:"disabled"
      |> canonical_policy_shell_mode
    in
    let allowed_paths = [] in
    let room_scope =
      profile_defaults.room_scope |> Option.value ~default:"current"
      |> canonical_room_scope
    in
    let scope_kind =
      profile_defaults.scope_kind
      |> Option.value ~default:(if room_scope = "all" then "global" else "local")
      |> canonical_scope_kind
    in
    let trigger_mode =
      profile_defaults.trigger_mode |> Option.value ~default:"legacy"
      |> canonical_trigger_mode
    in
    let mention_targets =
      let raw =
        if profile_defaults.mention_targets <> [] then profile_defaults.mention_targets
        else [ name ]
      in
      raw |> dedupe_keep_order
    in
    let meta = {
      name;
      agent_name = keeper_agent_name name;
      persona_profile_path = Option.value ~default:"" profile_defaults.manifest_path;
      trace_id;
      trace_history = [];
      goal;
      short_goal;
      mid_goal;
      long_goal;
      soul_profile;
      cascade_name = "keeper_unified";
      will;
      needs;
      desires;
      instructions;
      models = inline_models;
      allowed_models;
      active_model;
      policy_mode;
      policy_voice_enabled;
      policy_shell_mode;
      allowed_paths;
      scope_kind;
      room_scope;
      trigger_mode;
      voice_enabled = default_voice_enabled_for name;
      voice_channel = default_voice_channel_for name;
      voice_agent_id = default_voice_agent_id_for name;
      mention_targets;
      joined_room_ids = [];
      last_seen_seq_by_room = [];
      generation = 0;
      presence_keepalive = true;
      presence_keepalive_sec = 30;
      proactive_enabled =
        Option.value
          ~default:
            (if
               trigger_mode
               |> Keeper_contract.trigger_mode_of_string
               |> Keeper_contract.trigger_mode_is_explicit_only
             then false
             else default_proactive_enabled)
          profile_defaults.proactive_enabled;
      proactive_idle_sec = default_proactive_idle_sec;
      proactive_cooldown_sec = default_proactive_cooldown_sec;
      compaction_profile = default_compaction_profile;
      compaction_ratio_gate = env_ratio_gate;
      compaction_message_gate = env_message_gate;
      compaction_token_gate = env_token_gate;
      continuity_compaction_cooldown_sec;
      auto_handoff = true;
      handoff_threshold = 0.85;
      handoff_cooldown_sec = 300;
      last_handoff_ts = 0.0;
      created_at = now_iso ();
      updated_at = now_iso ();
      total_turns = 0;
      total_input_tokens = 0;
      total_output_tokens = 0;
      total_tokens = 0;
      total_cost_usd = 0.0;
      last_turn_ts = 0.0;
      last_model_used = "";
      last_input_tokens = 0;
      last_output_tokens = 0;
      last_total_tokens = 0;
      last_latency_ms = 0;
      compaction_count = 0;
      last_compaction_ts = 0.0;
      last_compaction_before_tokens = 0;
      last_compaction_after_tokens = 0;
      last_compaction_check_ts = now_ts;
      last_compaction_decision = "initialized";
      proactive_count_total = 0;
      last_proactive_ts = 0.0;
      last_proactive_reason = "";
      last_proactive_preview = "";
      last_continuity_update_ts = now_ts;
      continuity_summary = "";
      active_goal_ids = [];
      last_autonomous_action_at = "";
      autonomous_action_count = 0;
      deliberation_count = 0;
      deliberation_cost_total_usd = 0.0;
      last_deliberation_ts = 0.0;
      last_triage_triggers = "";
      active_team_session_id = None;
      last_team_session_started_at = "";
      team_session_start_count_total = 0;
      paused = false;
    } in
    let base_dir = session_base_dir ctx.config in
    mkdir_p base_dir;
    let cascade_models = Oas_model_resolve.models_of_cascade_name meta.cascade_name in
    (match ensure_api_keys_for_labels cascade_models with
     | Error e -> Error e
     | Ok () ->
       let primary_max_context = Oas_model_resolve.resolve_primary_max_context cascade_models in
       let session = Keeper_exec_context.create_session ~session_id:trace_id ~base_dir in
       let persona_extended =
         Keeper_types_profile.load_persona_extended name
         |> Option.value ~default:""
       in
       let system_prompt =
         build_keeper_system_prompt
           ~goal
           ~short_goal
           ~mid_goal
           ~long_goal
           ~soul_profile
           ~will
           ~needs
           ~desires
           ~instructions
           ~persona_extended
           ()
       in
       let ctx0 = Keeper_exec_context.create ~system_prompt ~max_tokens:primary_max_context in
       (try ignore (save_checkpoint session ctx0 ~generation:0)
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn ~label:"save_checkpoint (ensure) failed" exn);
       match write_meta ctx.config meta with
       | Error e -> Error e
       | Ok () -> Ok meta)

(** Apply inline settings update to keeper meta. Extracted from handle_keeper_msg. *)
let apply_settings_update
    ~(args : Yojson.Safe.t)
    ~(meta0 : keeper_meta)
    ~new_short_goal
    ~new_mid_goal
    ~new_long_goal
    ~new_soul_profile
    ~new_will
    ~new_needs
    ~new_desires
    ~(config : Room.config)
  : keeper_meta =
  let new_goal_opt = normalize_goal_horizon_opt (get_string_opt args "new_goal") in
  let goal =
    match new_goal_opt with
    | None -> meta0.goal
    | Some ng -> ng
  in
  let goal_provided = Option.is_some new_goal_opt in
  let short_goal_default = if goal_provided then goal else meta0.short_goal in
  let mid_goal_default = if goal_provided then goal else meta0.mid_goal in
  let long_goal_default = if goal_provided then goal else meta0.long_goal in
  let short_goal =
    Option.value ~default:short_goal_default new_short_goal
    |> normalize_goal_horizon_text
  in
  let mid_goal =
    Option.value ~default:mid_goal_default new_mid_goal
    |> normalize_goal_horizon_text
  in
  let long_goal =
    Option.value ~default:long_goal_default new_long_goal
    |> normalize_goal_horizon_text
  in
  let soul_profile = Option.value ~default:meta0.soul_profile new_soul_profile in
  let instructions =
    Option.value ~default:meta0.instructions (get_string_opt args "new_instructions")
  in
  let will = Option.value ~default:meta0.will new_will in
  let needs = Option.value ~default:meta0.needs new_needs in
  let desires = Option.value ~default:meta0.desires new_desires in
  if goal = meta0.goal
     && short_goal = meta0.short_goal
     && mid_goal = meta0.mid_goal
     && long_goal = meta0.long_goal
     && soul_profile = meta0.soul_profile
     && will = meta0.will
     && needs = meta0.needs
     && desires = meta0.desires
     && instructions = meta0.instructions
  then
    meta0
  else
    let updated = {
      meta0 with
      goal;
      short_goal;
      mid_goal;
      long_goal;
      soul_profile;
      will;
      needs;
      desires;
      instructions;
      updated_at = now_iso ();
    } in
    (try
       (match write_meta config updated with
        | Ok () -> ()
        | Error e -> Log.Keeper.warn "write_meta failed (settings): %s" e)
     with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn ~label:"write_meta (settings) failed" exn);
    updated

