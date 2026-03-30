(** Keeper_turn_up_create -- create a new keeper from parsed arguments.

    Extracted from keeper_turn_up.ml (Ok None branch).
    Handles initial keeper meta construction, checkpoint creation,
    keepalive start, and response JSON generation. *)

open Keeper_types
open Keeper_keepalive
open Keeper_execution
open Keeper_turn_up_args

let create_keeper (ctx : _ context) (p : parsed_args) : tool_result =
  Log.Keeper.info "create_keeper: starting for name=%s" p.name;
  let task_id = Printf.sprintf "keeper_create_%s" p.name in
  let tracker = Progress.start_tracking ~task_id ~total_steps:6 () in
  Progress.Tracker.step tracker ~message:"Resolving keeper configuration" ();
  let now_ts = Time_compat.now () in
  let goal =
    match p.goal_opt with
    | Some goal -> normalize_goal_horizon_text goal
    | None ->
        p.profile_defaults.goal |> Option.value ~default:""
        |> normalize_goal_horizon_text
  in
  let room_scope =
    p.room_scope_opt
    |> first_some p.profile_defaults.room_scope
    |> Option.value ~default:"current"
    |> canonical_room_scope
  in
  let scope_kind =
    p.scope_kind_opt
    |> first_some p.profile_defaults.scope_kind
    |> Option.value ~default:(if room_scope = "all" then "global" else "local")
    |> canonical_scope_kind
  in
  let policy_voice_enabled =
    first_some
      p.policy_voice_enabled_opt
      p.profile_defaults.policy_voice_enabled
    |> Option.value ~default:false
  in
  let allowed_paths =
    match p.allowed_paths_opt with
    | Some paths -> paths
    | None -> Option.value ~default:[] p.profile_defaults.allowed_paths
  in
  let execution_scope =
    p.execution_scope_opt
    |> first_some p.profile_defaults.execution_scope
    |> Option.value ~default:default_execution_scope
  in
  let voice_enabled =
    Option.value ~default:(default_voice_enabled_for p.name) p.voice_enabled_opt
  in
  let voice_channel =
    p.voice_channel_opt
    |> Option.map canonical_voice_channel
    |> Option.value ~default:(default_voice_channel_for p.name)
  in
  let voice_agent_id =
    Option.value ~default:(default_voice_agent_id_for p.name) p.voice_agent_id_opt
  in
  let mention_targets =
    resolve_mention_targets
      ~mention_targets_in:p.mention_targets_in
      ~fallback_targets:p.profile_defaults.mention_targets
      ~name:p.name
  in
  if goal = "" then begin
    Log.Keeper.warn "create_keeper failed: goal is required (name=%s)" p.name;
    (false, "goal is required when creating a keeper")
  end
  else
    let max_active_keepers = Env_config.KeeperBootstrap.max_active_keepers in
    let active_keepers = Keeper_registry.count_running () in
    if max_active_keepers > 0 && active_keepers >= max_active_keepers then begin
      Log.Keeper.warn "create_keeper failed: max active keepers reached (%d/%d) for name=%s"
        active_keepers max_active_keepers p.name;
      (false,
        Printf.sprintf
          "keeper max active reached (%d/%d). Stop/remove a keeper or set MASC_KEEPER_MAX_ACTIVE_KEEPERS."
          active_keepers max_active_keepers)
    end
    else
    let proactive_enabled =
      Option.value
        ~default:
          (Option.value ~default:default_proactive_enabled p.profile_defaults.proactive_enabled)
        p.proactive_enabled_opt
    in
    let proactive_idle_sec =
      Option.value ~default:default_proactive_idle_sec p.proactive_idle_sec_opt
      |> normalize_proactive_idle_sec
    in
    let proactive_cooldown_sec =
      Option.value ~default:default_proactive_cooldown_sec p.proactive_cooldown_sec_opt
      |> normalize_proactive_cooldown_sec
    in
    let auto_handoff = Option.value ~default:true p.auto_handoff_opt in
    let handoff_threshold = Option.value ~default:0.85 p.handoff_threshold_opt in
    let handoff_cooldown_sec = Option.value ~default:300 p.handoff_cooldown_sec_opt in
    let soul_profile =
      Option.value
        ~default:(Option.value ~default:default_soul_profile p.profile_defaults.soul_profile)
        p.soul_profile_opt
    in
    let will =
      Option.value
        ~default:(Option.value ~default:default_keeper_will p.profile_defaults.will)
        p.will_opt
    in
    let needs =
      Option.value
        ~default:(Option.value ~default:default_keeper_needs p.profile_defaults.needs)
        p.needs_opt
    in
    let desires =
      Option.value
        ~default:(Option.value ~default:default_keeper_desires p.profile_defaults.desires)
        p.desires_opt
    in
    let (short_goal, mid_goal, long_goal) =
      resolve_goal_horizons
        ~goal
        ~short_goal_opt:(first_some p.short_goal_opt p.profile_defaults.short_goal)
        ~mid_goal_opt:(first_some p.mid_goal_opt p.profile_defaults.mid_goal)
        ~long_goal_opt:(first_some p.long_goal_opt p.profile_defaults.long_goal)
    in
    let instructions = Option.value ~default:"" p.instructions_opt in
    let (env_ratio_gate, env_message_gate, env_token_gate) =
      keeper_compaction_policy_from_env ()
    in
    let continuity_compaction_cooldown_sec =
      Option.value
        ~default:(keeper_continuity_compaction_cooldown_sec ())
        p.continuity_compaction_cooldown_sec_opt
      |> normalize_continuity_compaction_cooldown_sec
    in
    let (compaction_profile, compaction_ratio_gate, compaction_message_gate, compaction_token_gate) =
      resolve_compaction_policy
        ~profile_opt:p.compaction_profile_opt
        ~ratio_opt:p.compaction_ratio_gate_opt
        ~message_opt:p.compaction_message_gate_opt
        ~token_opt:p.compaction_token_gate_opt
        ~fallback_profile:default_compaction_profile
        ~fallback_ratio:env_ratio_gate
        ~fallback_message:env_message_gate
        ~fallback_token:env_token_gate
    in
    Progress.Tracker.step tracker ~message:"Validating API keys for cascade" ();
    let cascade_models = Oas_model_resolve.models_of_cascade_name "keeper_unified" in
    (match ensure_api_keys_for_labels cascade_models with
     | Error e ->
       Log.Keeper.error "create_keeper failed: API key validation error for name=%s: %s" p.name e;
       Progress.stop_tracking task_id;
       (false, e)
     | Ok () ->
       Log.Keeper.debug "create_keeper: API keys validated for name=%s cascade=%s"
         p.name "keeper_unified";
       Progress.Tracker.step tracker ~message:"Initializing session directory" ();
       let primary_max_context = Oas_model_resolve.resolve_primary_max_context cascade_models in
       let trace_id = generate_trace_id () in
         let base_dir = session_base_dir ctx.config in
         (* Ensure full session dir tree, not just base_dir (issue #3019) *)
         ignore (Keeper_fs.ensure_dir (Filename.concat base_dir trace_id));
         let session = Keeper_exec_context.create_session ~session_id:trace_id ~base_dir in
           let persona_extended =
             Keeper_types_profile.load_persona_extended p.name
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
         let meta = {
           name = p.name;
           agent_name = keeper_agent_name p.name;
           goal;
           short_goal;
           mid_goal;
           long_goal;
           soul_profile;
           social_model = default_social_model;
           cascade_name = "keeper_unified";
           will;
           needs;
           desires;
           instructions;
           policy_voice_enabled;
           execution_scope;
           allowed_paths;
           scope_kind;
           tool_allowlist = Tool_catalog.standard_tools;
           tool_denylist = [];
           room_scope;
           voice_enabled;
           voice_channel;
           voice_agent_id;
           mention_targets;
           joined_room_ids = [];
           last_seen_seq_by_room = [];
           proactive = {
             enabled = proactive_enabled;
             idle_sec = proactive_idle_sec;
             cooldown_sec = proactive_cooldown_sec;
           };
           compaction = {
             profile = compaction_profile;
             ratio_gate = compaction_ratio_gate;
             message_gate = compaction_message_gate;
             token_gate = compaction_token_gate;
             cooldown_sec = continuity_compaction_cooldown_sec;
           };
           auto_handoff;
           handoff_threshold;
           handoff_cooldown_sec;
           created_at = now_iso ();
           updated_at = now_iso ();
           continuity_summary = "";
           active_goal_ids = [];
           active_team_session_id = None;
           last_team_session_started_at = "";
           team_session_start_count_total = 0;
           paused = false;
           current_task_id = None;
           runtime = {
             usage = {
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
             };
             compaction_rt = {
               count = 0;
               last_ts = 0.0;
               last_before_tokens = 0;
               last_after_tokens = 0;
               last_check_ts = now_ts;
               last_decision = "initialized";
             };
             proactive_rt = {
               count_total = 0;
               last_ts = 0.0;
               last_reason = "";
               last_preview = "";
             };
             generation = 0;
             trace_id;
             trace_history = [];
             last_handoff_ts = 0.0;
             last_continuity_update_ts = now_ts;
             last_autonomous_action_at = "";
             autonomous_action_count = 0;
             autonomous_turn_count = 0;
             autonomous_text_turn_count = 0;
             autonomous_tool_turn_count = 0;
             board_reactive_turn_count = 0;
             mention_reactive_turn_count = 0;
             noop_turn_count = 0;
             last_speech_act = "";
             last_blocker = "";
             last_need = "";
           };
         } in
         Progress.Tracker.step tracker ~message:"Saving initial checkpoint" ();
         (try
            ignore
              (Keeper_exec_context.save_oas_checkpoint
                 ~session
                 ~agent_name:meta.agent_name
                 ~model:(Keeper_exec_context.checkpoint_model_of_meta meta)
                 ~ctx:ctx0
                 ~generation:0)
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              log_keeper_exn ~label:"save_oas_checkpoint (init) failed" exn);
         Progress.Tracker.step tracker ~message:"Writing keeper metadata" ();
         match write_meta ctx.config meta with
         | Error e ->
           Log.Keeper.error "create_keeper failed: write_meta error for name=%s: %s" p.name e;
           Progress.stop_tracking task_id;
           (false, e)
         | Ok () ->
           Log.Keeper.debug "create_keeper: metadata written for name=%s trace_id=%s"
             p.name meta.runtime.trace_id;
           Progress.Tracker.step tracker ~message:"Starting keepalive loop" ();
           Log.Keeper.info "create_keeper: starting keepalive for name=%s" p.name;
           start_keepalive ctx meta;
           (* Apply per-persona shard configuration if present *)
           (match p.profile_defaults.shards with
            | Some (_ :: _ as shard_names) ->
                Log.Keeper.debug "create_keeper: applying shard config for name=%s shards=%d"
                  p.name (List.length shard_names);
                Tool_shard.set_agent_shards p.name shard_names
            | Some [] | None -> ());
           Progress.Tracker.complete tracker ~message:"Keeper created" ();
           Log.Keeper.info "create_keeper: completed for name=%s trace_id=%s" p.name meta.runtime.trace_id;
           let json = `Assoc [
             ("name", `String meta.name);
             ("agent_name", `String meta.agent_name);
             ("trace_id", `String meta.runtime.trace_id);
             ("generation", `Int meta.runtime.generation);
             ("goal", `String meta.goal);
             ("short_goal", `String meta.short_goal);
             ("mid_goal", `String meta.mid_goal);
             ("long_goal", `String meta.long_goal);
             ("soul_profile", `String meta.soul_profile);
             ("will", `String meta.will);
             ("needs", `String meta.needs);
             ("desires", `String meta.desires);
             ("instructions", `String meta.instructions);
             ("cascade_name", `String meta.cascade_name);
             ("voice_enabled", `Bool meta.voice_enabled);
             ("voice_channel", `String meta.voice_channel);
             ("voice_agent_id", `String meta.voice_agent_id);
             ("social_model", `String meta.social_model);
             ("proactive_enabled", `Bool meta.proactive.enabled);
             ("proactive_idle_sec", `Int meta.proactive.idle_sec);
             ("proactive_cooldown_sec", `Int meta.proactive.cooldown_sec);
             ("compaction_profile", `String meta.compaction.profile);
             ("compaction_ratio_gate", `Float meta.compaction.ratio_gate);
             ("compaction_message_gate", `Int meta.compaction.message_gate);
             ("compaction_token_gate", `Int meta.compaction.token_gate);
             ("auto_handoff", `Bool meta.auto_handoff);
             ("handoff_threshold", `Float meta.handoff_threshold);
           ] in
           (true, Yojson.Safe.pretty_to_string json))
