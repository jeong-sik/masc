(** Keeper_turn_up_create -- create a new keeper from parsed arguments.

    Extracted from keeper_turn_up.ml (Ok None branch).
    Handles initial keeper meta construction, checkpoint creation,
    keepalive start, and response JSON generation. *)

open Keeper_types
open Keeper_keepalive
open Keeper_execution
open Keeper_turn_up_args

let create_keeper (ctx : _ context) (p : parsed_args) : tool_result =
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
  let trigger_mode =
    p.trigger_mode_opt
    |> first_some p.profile_defaults.trigger_mode
    |> Option.value ~default:"legacy"
    |> canonical_trigger_mode
  in
  let requested_models =
    if p.models_in <> [] then
      p.models_in
    else if p.profile_defaults.models <> [] then
      p.profile_defaults.models
    else
      p.profile_defaults.allowed_models
  in
  let allowed_models =
    resolve_allowed_models
      ~explicit_allowed_models:p.allowed_models_in
      ~seed_allowed_models:p.profile_defaults.allowed_models
      ~models:requested_models
  in
  let active_model =
    p.active_model_opt
    |> first_some p.profile_defaults.active_model
    |> Option.value
         ~default:
           (match requested_models with
           | model :: _ -> model
            | [] -> "")
  in
  let policy_mode =
    let default_policy_mode =
      if default_voice_enabled_for p.name then "explicit_event_v1" else "heuristic"
    in
    p.policy_mode_opt
    |> first_some
         (if default_voice_enabled_for p.name then None else p.profile_defaults.policy_mode)
    |> Option.value
         ~default:default_policy_mode
    |> canonical_policy_mode
  in
  let use_profile_policy_defaults =
    not (default_voice_enabled_for p.name && Option.is_none p.policy_mode_opt)
  in
  let policy_action_budget =
    first_some
      p.policy_action_budget_opt
      (if use_profile_policy_defaults then p.profile_defaults.policy_action_budget else None)
    |> Option.value ~default:"conversation"
    |> canonical_policy_action_budget
  in
  let policy_reward_model_path =
    first_some
      p.policy_reward_model_path_opt
      (if use_profile_policy_defaults then p.profile_defaults.policy_reward_model_path else None)
    |> Option.value ~default:""
    |> resolve_reward_model_path ~base_path:ctx.config.base_path
  in
  let policy_voice_enabled =
    first_some
      p.policy_voice_enabled_opt
      (if use_profile_policy_defaults then p.profile_defaults.policy_voice_enabled else None)
    |> Option.value ~default:false
  in
  let policy_shell_mode =
    first_some
      p.policy_shell_mode_opt
      (if use_profile_policy_defaults then p.profile_defaults.policy_shell_mode else None)
    |> Option.value ~default:"disabled"
    |> canonical_policy_shell_mode
  in
  let allowed_paths =
    Option.value ~default:[] p.allowed_paths_opt
  in
  let initiative_enabled =
    first_some
      p.initiative_enabled_opt
      (if use_profile_policy_defaults then p.profile_defaults.initiative_enabled else None)
    |> Option.value ~default:false
  in
  let initiative_scope =
    first_some
      p.initiative_scope_opt
      (if use_profile_policy_defaults then p.profile_defaults.initiative_scope else None)
    |> Option.value ~default:"board_only"
    |> canonical_initiative_scope
  in
  let initiative_idle_sec =
    first_some
      p.initiative_idle_sec_opt
      (if use_profile_policy_defaults then p.profile_defaults.initiative_idle_sec else None)
    |> Option.value ~default:3600
    |> normalize_initiative_idle_sec
  in
  let initiative_cooldown_sec =
    first_some
      p.initiative_cooldown_sec_opt
      (if use_profile_policy_defaults then p.profile_defaults.initiative_cooldown_sec else None)
    |> Option.value ~default:3600
    |> normalize_initiative_cooldown_sec
  in
  let initiative_context_mode =
    first_some
      p.initiative_context_mode_opt
      (if use_profile_policy_defaults then p.profile_defaults.initiative_context_mode else None)
    |> Option.value ~default:"board_snapshot"
    |> canonical_initiative_context_mode
  in
  let initiative_post_ttl_hours =
    first_some
      p.initiative_post_ttl_hours_opt
      (if use_profile_policy_defaults then p.profile_defaults.initiative_post_ttl_hours else None)
    |> Option.value ~default:24
    |> normalize_initiative_post_ttl_hours
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
  let auto_team_session_enabled =
    Option.value ~default:false p.auto_team_session_enabled_opt
  in
  let mention_targets =
    resolve_mention_targets
      ~mention_targets_in:p.mention_targets_in
      ~fallback_targets:p.profile_defaults.mention_targets
      ~name:p.name
  in
  if goal = "" then
    (false, "goal is required when creating a keeper")
  else if requested_models = [] then
    (false, "models is required when creating a keeper")
  else
    match validate_policy ~policy_mode ~policy_action_budget
            ~policy_voice_enabled ~policy_shell_mode ~initiative_enabled with
    | Some err -> (false, err)
    | None ->
    let verify = Option.value ~default:false p.verify_opt in
    let presence_keepalive =
      Option.value
        ~default:(Option.value ~default:true p.profile_defaults.presence_keepalive)
        p.presence_keepalive_opt
    in
    let presence_keepalive_sec =
      Option.value
        ~default:(Option.value ~default:30 p.profile_defaults.presence_keepalive_sec)
        p.presence_keepalive_sec_opt
    in
    let max_active_keepers = Env_config.KeeperBootstrap.max_active_keepers in
    let active_keepers = running_keepers () in
    if presence_keepalive && max_active_keepers > 0 && active_keepers >= max_active_keepers then
      (false,
        Printf.sprintf
          "keeper keepalive max active reached (%d/%d). Stop/remove a keeper or set MASC_KEEPER_MAX_ACTIVE_KEEPERS."
          active_keepers max_active_keepers)
    else
    let proactive_enabled =
      Option.value
        ~default:
          (Option.value
             ~default:
               (if
                  trigger_mode
                  |> Keeper_contract.trigger_mode_of_string
                  |> Keeper_contract.trigger_mode_is_explicit_only
                then false
                else default_proactive_enabled)
             p.profile_defaults.proactive_enabled)
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
    let drift_enabled =
      Option.value ~default:default_drift_enabled p.drift_enabled_opt
    in
    let drift_min_turn_gap =
      Option.value ~default:default_drift_min_turn_gap p.drift_min_turn_gap_opt
      |> normalize_drift_min_turn_gap
    in
    let auto_handoff = Option.value ~default:true p.auto_handoff_opt in
    let handoff_threshold = Option.value ~default:0.85 p.handoff_threshold_opt in
    let handoff_cooldown_sec = Option.value ~default:300 p.handoff_cooldown_sec_opt in
    let context_budget = Option.value ~default:0.6 p.context_budget_opt in
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
    (match ensure_api_keys_for_labels requested_models with
     | Error e -> (false, e)
     | Ok () ->
       let primary_max_context = Oas_model_resolve.resolve_primary_max_context requested_models in
       let trace_id = generate_trace_id () in
         let base_dir = session_base_dir ctx.config in
         mkdir_p base_dir;
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
         (try ignore (save_checkpoint session ctx0 ~generation:0)
          with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn ~label:"save_checkpoint (init) failed" exn);
         let meta = {
           name = p.name;
           agent_name = keeper_agent_name p.name;
           persona_profile_path = Option.value ~default:"" p.profile_defaults.manifest_path;
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
           models = requested_models;
           allowed_models;
           active_model;
           policy_mode;
           policy_action_budget;
           policy_reward_model_path;
           policy_voice_enabled;
           policy_shell_mode;
           allowed_paths;
           initiative_enabled;
           initiative_scope;
           initiative_idle_sec;
           initiative_cooldown_sec;
           initiative_context_mode;
           initiative_post_ttl_hours;
           scope_kind;
           room_scope;
           trigger_mode;
           voice_enabled;
           voice_channel;
           voice_agent_id;
           mention_targets;
           joined_room_ids = [];
           last_seen_seq_by_room = [];
           generation = 0;
           verify;
           presence_keepalive;
           presence_keepalive_sec;
           proactive_enabled;
           proactive_idle_sec;
           proactive_cooldown_sec;
           drift_enabled;
           drift_min_turn_gap;
           drift_count_total = 0;
           last_drift_turn = 0;
           last_drift_reason = "";
           compaction_profile;
           compaction_ratio_gate;
           compaction_message_gate;
           compaction_token_gate;
           continuity_compaction_cooldown_sec;
           auto_handoff;
           handoff_threshold;
           handoff_cooldown_sec;
           context_budget;
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
            autonomy_level = "l1_reactive";
            active_goal_ids = [];
            last_autonomous_action_at = "";
            autonomous_action_count = 0;
            deliberation_count = 0;
            deliberation_cost_total_usd = 0.0;
            last_deliberation_ts = 0.0;
            last_triage_triggers = "";
            auto_team_session_enabled;
            active_team_session_id = None;
            last_team_session_started_at = "";
            team_session_start_count_total = 0;
            paused = false;
         } in
         match write_meta ctx.config meta with
         | Error e -> (false, e)
         | Ok () ->
           start_keepalive ctx meta;
           let json = `Assoc [
             ("name", `String meta.name);
             ("agent_name", `String meta.agent_name);
             ("trace_id", `String meta.trace_id);
             ("generation", `Int meta.generation);
             ("goal", `String meta.goal);
             ("short_goal", `String meta.short_goal);
             ("mid_goal", `String meta.mid_goal);
             ("long_goal", `String meta.long_goal);
             ("soul_profile", `String meta.soul_profile);
             ("will", `String meta.will);
             ("needs", `String meta.needs);
             ("desires", `String meta.desires);
             ("instructions", `String meta.instructions);
             ("models", `List (List.map (fun s -> `String s) meta.models));
             ("policy_mode", `String meta.policy_mode);
             ("voice_enabled", `Bool meta.voice_enabled);
             ("voice_channel", `String meta.voice_channel);
             ("voice_agent_id", `String meta.voice_agent_id);
             ("presence_keepalive", `Bool meta.presence_keepalive);
             ("presence_keepalive_sec", `Int meta.presence_keepalive_sec);
             ("proactive_enabled", `Bool meta.proactive_enabled);
             ("proactive_idle_sec", `Int meta.proactive_idle_sec);
             ("proactive_cooldown_sec", `Int meta.proactive_cooldown_sec);
             ("policy_mode", `String meta.policy_mode);
             ("policy_action_budget", `String meta.policy_action_budget);
             ("policy_reward_model_path",
               if String.trim meta.policy_reward_model_path = ""
               then `Null
               else `String meta.policy_reward_model_path);
             ("policy_voice_enabled", `Bool meta.policy_voice_enabled);
             ("policy_shell_mode", `String meta.policy_shell_mode);
             ("initiative_enabled", `Bool meta.initiative_enabled);
             ("initiative_scope", `String meta.initiative_scope);
             ("initiative_idle_sec", `Int meta.initiative_idle_sec);
             ("initiative_cooldown_sec", `Int meta.initiative_cooldown_sec);
             ("initiative_context_mode", `String meta.initiative_context_mode);
             ("initiative_post_ttl_hours", `Int meta.initiative_post_ttl_hours);
             ("auto_team_session_enabled", `Bool meta.auto_team_session_enabled);
             ("drift_enabled", `Bool meta.drift_enabled);
             ("drift_min_turn_gap", `Int meta.drift_min_turn_gap);
             ("compaction_profile", `String meta.compaction_profile);
             ("compaction_ratio_gate", `Float meta.compaction_ratio_gate);
             ("compaction_message_gate", `Int meta.compaction_message_gate);
             ("compaction_token_gate", `Int meta.compaction_token_gate);
             ("auto_handoff", `Bool meta.auto_handoff);
             ("handoff_threshold", `Float meta.handoff_threshold);
           ] in
           (true, Yojson.Safe.pretty_to_string json))
