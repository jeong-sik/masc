(** Keeper_turn_up -- keeper start/reconfigure handler.

    Extracted from keeper_turn.ml.  Handles the "masc_keeper_up" tool
    which creates a new keeper or updates an existing one. *)

open Tool_args
open Keeper_types
open Keeper_keepalive
open Keeper_execution

type tool_result = Keeper_types.tool_result

let handle_keeper_up ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name (allowed: [A-Za-z0-9._-])")
  else
    let soul_profile_opt_res = parse_soul_profile_opt args "soul_profile" in
    let compaction_profile_opt_res =
      parse_compaction_profile_opt args "compaction_profile"
    in
    match soul_profile_opt_res, compaction_profile_opt_res with
    | Error e, _ | _, Error e -> (false, "❌ " ^ e)
    | Ok soul_profile_opt, Ok compaction_profile_opt ->
    let goal_opt = get_string_opt args "goal" in
    let short_goal_opt = parse_goal_horizon_opt args "short_goal" in
    let mid_goal_opt = parse_goal_horizon_opt args "mid_goal" in
    let long_goal_opt = parse_goal_horizon_opt args "long_goal" in
    let models_in = get_string_list args "models" in
    let allowed_models_in = get_string_list args "allowed_models" in
    let active_model_opt = get_string_opt args "active_model" in
    let policy_mode_opt = get_string_opt args "policy_mode" in
    let policy_action_budget_opt = get_string_opt args "policy_action_budget" in
    let policy_reward_model_path_opt = get_string_opt args "policy_reward_model_path" in
    let policy_voice_enabled_opt = get_bool_opt args "policy_voice_enabled" in
    let policy_shell_mode_opt = get_string_opt args "policy_shell_mode" in
    let initiative_enabled_opt = get_bool_opt args "initiative_enabled" in
    let initiative_scope_opt = get_string_opt args "initiative_scope" in
    let initiative_idle_sec_opt = Safe_ops.json_int_opt "initiative_idle_sec" args in
    let initiative_cooldown_sec_opt = Safe_ops.json_int_opt "initiative_cooldown_sec" args in
    let initiative_context_mode_opt = get_string_opt args "initiative_context_mode" in
    let initiative_post_ttl_hours_opt = Safe_ops.json_int_opt "initiative_post_ttl_hours" args in
    let auto_team_session_enabled_opt =
      get_bool_opt args "auto_team_session_enabled"
    in
    let room_scope_opt = get_string_opt args "room_scope" in
    let scope_kind_opt = get_string_opt args "scope_kind" in
    let trigger_mode_opt = get_string_opt args "trigger_mode" in
    let voice_enabled_opt = get_bool_opt args "voice_enabled" in
    let voice_channel_opt = get_string_opt args "voice_channel" in
    let voice_agent_id_opt = get_string_opt args "voice_agent_id" in
    let mention_targets_in = get_string_list args "mention_targets" in
    let verify_opt = get_bool_opt args "verify" in
    let presence_keepalive_opt = get_bool_opt args "presence_keepalive" in
    let presence_keepalive_sec_opt = Safe_ops.json_int_opt "presence_keepalive_sec" args in
    let proactive_enabled_opt = get_bool_opt args "proactive_enabled" in
    let proactive_idle_sec_opt = Safe_ops.json_int_opt "proactive_idle_sec" args in
    let proactive_cooldown_sec_opt = Safe_ops.json_int_opt "proactive_cooldown_sec" args in
    let drift_enabled_opt = get_bool_opt args "drift_enabled" in
    let drift_min_turn_gap_opt = Safe_ops.json_int_opt "drift_min_turn_gap" args in
    let compaction_ratio_gate_opt = Safe_ops.json_float_opt "compaction_ratio_gate" args in
    let compaction_message_gate_opt = Safe_ops.json_int_opt "compaction_message_gate" args in
    let compaction_token_gate_opt = Safe_ops.json_int_opt "compaction_token_gate" args in
    let continuity_compaction_cooldown_sec_opt =
      Safe_ops.json_int_opt "continuity_compaction_cooldown_sec" args
    in
    let auto_handoff_opt = get_bool_opt args "auto_handoff" in
    let handoff_threshold_opt = Safe_ops.json_float_opt "handoff_threshold" args in
    let handoff_cooldown_sec_opt = Safe_ops.json_int_opt "handoff_cooldown_sec" args in
    let context_budget_opt = Safe_ops.json_float_opt "context_budget" args in
    let instructions_arg = get_string_opt args "instructions" in
    let profile_defaults = load_keeper_profile_defaults name in
    let soul_path = Filename.concat (Filename.concat (Filename.concat (Filename.concat ctx.config.base_path "memory") "souls") name) "SOUL.md" in
    let soul_content = match Safe_ops.read_file_safe soul_path with Ok c -> c | Error _ -> "" in
    let base_instructions_opt =
      match instructions_arg with
      | Some _ -> instructions_arg
      | None -> profile_defaults.instructions
    in
    let instructions_opt =
      if soul_content <> "" then
        let base = Option.value ~default:"" base_instructions_opt in
        Some (base ^ "\n\n[SYSTEM: SOUL INFUSION]\n" ^ soul_content)
      else
        base_instructions_opt
    in
    let will_opt = parse_self_model_opt args "will" in
    let needs_opt = parse_self_model_opt args "needs" in
    let desires_opt = parse_self_model_opt args "desires" in
    let resolve_reward_model_path raw_path =
      let trimmed = String.trim raw_path in
      if trimmed = "" then ""
      else if Filename.is_relative trimmed then Filename.concat ctx.config.base_path trimmed
      else trimmed
    in
    match read_meta ctx.config name with
    | Error e -> (false, Printf.sprintf "❌ %s" e)
  | Ok None ->
      (* Create new keeper *)
      let now_ts = Time_compat.now () in
      let goal =
        match goal_opt with
        | Some goal -> normalize_goal_horizon_text goal
        | None ->
            profile_defaults.goal |> Option.value ~default:""
            |> normalize_goal_horizon_text
      in
      let room_scope =
        room_scope_opt
        |> first_some profile_defaults.room_scope
        |> Option.value ~default:"current"
        |> canonical_room_scope
      in
      let scope_kind =
        scope_kind_opt
        |> first_some profile_defaults.scope_kind
        |> Option.value ~default:(if room_scope = "all" then "global" else "local")
        |> canonical_scope_kind
      in
      let trigger_mode =
        trigger_mode_opt
        |> first_some profile_defaults.trigger_mode
        |> Option.value ~default:"legacy"
        |> canonical_trigger_mode
      in
      let requested_models =
        if models_in <> [] then
          models_in
        else if profile_defaults.models <> [] then
          profile_defaults.models
        else
          profile_defaults.allowed_models
      in
      let allowed_models =
        resolve_allowed_models
          ~explicit_allowed_models:allowed_models_in
          ~seed_allowed_models:profile_defaults.allowed_models
          ~models:requested_models
      in
      let active_model =
        active_model_opt
        |> first_some profile_defaults.active_model
        |> Option.value
             ~default:
               (match requested_models with
               | model :: _ -> model
                | [] -> "")
      in
      let policy_mode =
        let default_policy_mode =
          if default_voice_enabled_for name then "explicit_event_v1" else "heuristic"
        in
        policy_mode_opt
        |> first_some
             (if default_voice_enabled_for name then None else profile_defaults.policy_mode)
        |> Option.value
             ~default:default_policy_mode
        |> canonical_policy_mode
      in
      let use_profile_policy_defaults =
        not (default_voice_enabled_for name && Option.is_none policy_mode_opt)
      in
      let policy_action_budget =
        first_some
          policy_action_budget_opt
          (if use_profile_policy_defaults then profile_defaults.policy_action_budget else None)
        |> Option.value ~default:"conversation"
        |> canonical_policy_action_budget
      in
      let policy_reward_model_path =
        first_some
          policy_reward_model_path_opt
          (if use_profile_policy_defaults then profile_defaults.policy_reward_model_path else None)
        |> Option.value ~default:""
        |> resolve_reward_model_path
      in
      let policy_voice_enabled =
        first_some
          policy_voice_enabled_opt
          (if use_profile_policy_defaults then profile_defaults.policy_voice_enabled else None)
        |> Option.value ~default:false
      in
      let policy_shell_mode =
        first_some
          policy_shell_mode_opt
          (if use_profile_policy_defaults then profile_defaults.policy_shell_mode else None)
        |> Option.value ~default:"disabled"
        |> canonical_policy_shell_mode
      in
      let initiative_enabled =
        first_some
          initiative_enabled_opt
          (if use_profile_policy_defaults then profile_defaults.initiative_enabled else None)
        |> Option.value ~default:false
      in
      let initiative_scope =
        first_some
          initiative_scope_opt
          (if use_profile_policy_defaults then profile_defaults.initiative_scope else None)
        |> Option.value ~default:"board_only"
        |> canonical_initiative_scope
      in
      let initiative_idle_sec =
        first_some
          initiative_idle_sec_opt
          (if use_profile_policy_defaults then profile_defaults.initiative_idle_sec else None)
        |> Option.value ~default:3600
        |> normalize_initiative_idle_sec
      in
      let initiative_cooldown_sec =
        first_some
          initiative_cooldown_sec_opt
          (if use_profile_policy_defaults then profile_defaults.initiative_cooldown_sec else None)
        |> Option.value ~default:3600
        |> normalize_initiative_cooldown_sec
      in
      let initiative_context_mode =
        first_some
          initiative_context_mode_opt
          (if use_profile_policy_defaults then profile_defaults.initiative_context_mode else None)
        |> Option.value ~default:"board_snapshot"
        |> canonical_initiative_context_mode
      in
      let initiative_post_ttl_hours =
        first_some
          initiative_post_ttl_hours_opt
          (if use_profile_policy_defaults then profile_defaults.initiative_post_ttl_hours else None)
        |> Option.value ~default:24
        |> normalize_initiative_post_ttl_hours
      in
      let voice_enabled =
        Option.value ~default:(default_voice_enabled_for name) voice_enabled_opt
      in
      let voice_channel =
        voice_channel_opt
        |> Option.map canonical_voice_channel
        |> Option.value ~default:(default_voice_channel_for name)
      in
      let voice_agent_id =
        Option.value ~default:(default_voice_agent_id_for name) voice_agent_id_opt
      in
      let auto_team_session_enabled =
        Option.value ~default:false auto_team_session_enabled_opt
      in
      let mention_targets =
        let raw =
          if mention_targets_in <> [] then mention_targets_in
          else if profile_defaults.mention_targets <> [] then profile_defaults.mention_targets
          else [ name ]
        in
        raw |> List.filter (fun s -> String.trim s <> "") |> dedupe_keep_order
      in
      if goal = "" then
        (false, "❌ goal is required when creating a keeper")
      else if requested_models = [] then
        (false, "❌ models is required when creating a keeper")
      else if policy_mode = "heuristic" && policy_action_budget <> "conversation" then
        (false, "❌ policy_action_budget=board requires policy_mode=learned_offline_v1")
      else if policy_voice_enabled && policy_mode <> "learned_offline_v1" then
        (false, "❌ policy_voice_enabled=true requires policy_mode=learned_offline_v1")
      else if policy_shell_mode = "readonly" && policy_mode <> "learned_offline_v1" then
        (false, "❌ policy_shell_mode=readonly requires policy_mode=learned_offline_v1")
      else if policy_mode = "learned_offline_v1" && policy_action_budget <> "board"
              && initiative_enabled
      then
        (false, "❌ initiative_enabled=true requires policy_action_budget=board in learned_offline_v1")
      else
        let verify = Option.value ~default:false verify_opt in
        let presence_keepalive =
          Option.value
            ~default:(Option.value ~default:true profile_defaults.presence_keepalive)
            presence_keepalive_opt
        in
        let presence_keepalive_sec =
          Option.value
            ~default:(Option.value ~default:30 profile_defaults.presence_keepalive_sec)
            presence_keepalive_sec_opt
        in
        let max_active_keepers = Env_config.KeeperBootstrap.max_active_keepers in
        let active_keepers = running_keepers () in
        if presence_keepalive && max_active_keepers > 0 && active_keepers >= max_active_keepers then
          (false,
            Printf.sprintf
              "❌ keeper keepalive max active reached (%d/%d). Stop/remove a keeper or set MASC_KEEPER_MAX_ACTIVE_KEEPERS."
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
                 profile_defaults.proactive_enabled)
            proactive_enabled_opt
        in
        let proactive_idle_sec =
          Option.value ~default:default_proactive_idle_sec proactive_idle_sec_opt
          |> normalize_proactive_idle_sec
        in
        let proactive_cooldown_sec =
          Option.value ~default:default_proactive_cooldown_sec proactive_cooldown_sec_opt
          |> normalize_proactive_cooldown_sec
        in
        let drift_enabled =
          Option.value ~default:default_drift_enabled drift_enabled_opt
        in
        let drift_min_turn_gap =
          Option.value ~default:default_drift_min_turn_gap drift_min_turn_gap_opt
          |> normalize_drift_min_turn_gap
        in
        let auto_handoff = Option.value ~default:true auto_handoff_opt in
        let handoff_threshold = Option.value ~default:0.85 handoff_threshold_opt in
        let handoff_cooldown_sec = Option.value ~default:300 handoff_cooldown_sec_opt in
        let context_budget = Option.value ~default:0.6 context_budget_opt in
        let soul_profile =
          Option.value
            ~default:(Option.value ~default:default_soul_profile profile_defaults.soul_profile)
            soul_profile_opt
        in
        let will =
          Option.value
            ~default:(Option.value ~default:default_keeper_will profile_defaults.will)
            will_opt
        in
        let needs =
          Option.value
            ~default:(Option.value ~default:default_keeper_needs profile_defaults.needs)
            needs_opt
        in
        let desires =
          Option.value
            ~default:(Option.value ~default:default_keeper_desires profile_defaults.desires)
            desires_opt
        in
        let (short_goal, mid_goal, long_goal) =
          resolve_goal_horizons
            ~goal
            ~short_goal_opt:(first_some short_goal_opt profile_defaults.short_goal)
            ~mid_goal_opt:(first_some mid_goal_opt profile_defaults.mid_goal)
            ~long_goal_opt:(first_some long_goal_opt profile_defaults.long_goal)
        in
        let instructions = Option.value ~default:"" instructions_opt in
        let (env_ratio_gate, env_message_gate, env_token_gate) =
          keeper_compaction_policy_from_env ()
        in
        let continuity_compaction_cooldown_sec =
          Option.value
            ~default:(keeper_continuity_compaction_cooldown_sec ())
            continuity_compaction_cooldown_sec_opt
          |> normalize_continuity_compaction_cooldown_sec
        in
        let (compaction_profile, compaction_ratio_gate, compaction_message_gate, compaction_token_gate) =
          resolve_compaction_policy
            ~profile_opt:compaction_profile_opt
            ~ratio_opt:compaction_ratio_gate_opt
            ~message_opt:compaction_message_gate_opt
            ~token_opt:compaction_token_gate_opt
            ~fallback_profile:default_compaction_profile
            ~fallback_ratio:env_ratio_gate
            ~fallback_message:env_message_gate
            ~fallback_token:env_token_gate
        in
        (match ensure_api_keys_for_labels requested_models with
         | Error e -> (false, "❌ " ^ e)
         | Ok () ->
           let specs = Model_spec.available_model_specs_of_strings requested_models in
           let trace_id = generate_trace_id () in
           let primary = match specs with
             | m :: _ -> m
             | [] -> Model_spec.default_local_model_spec ()
           in
             let base_dir = session_base_dir ctx.config in
             mkdir_p base_dir;
             let session = Keeper_exec_context.create_session ~session_id:trace_id ~base_dir in
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
             in
             let ctx0 = Keeper_exec_context.create ~system_prompt ~max_tokens:primary.max_context in
             (try ignore (save_checkpoint session ctx0 ~generation:0)
              with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log_keeper_exn ~label:"save_checkpoint (init) failed" exn);
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
             } in
             match write_meta ctx.config meta with
             | Error e -> (false, "❌ " ^ e)
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
    | Ok (Some old) ->
      (* Update existing keeper meta (goal/models optional) *)
      let goal_provided = Option.is_some goal_opt in
      let goal =
        match goal_opt with
        | Some g -> normalize_goal_horizon_text g
        | None ->
            if String.trim old.goal <> "" then old.goal
            else profile_defaults.goal |> Option.value ~default:""
      in
      let short_goal_default = if goal_provided then goal else old.short_goal in
      let mid_goal_default = if goal_provided then goal else old.mid_goal in
      let long_goal_default = if goal_provided then goal else old.long_goal in
      let short_goal =
        Option.value ~default:short_goal_default short_goal_opt
        |> normalize_goal_horizon_text
      in
      let mid_goal =
        Option.value ~default:mid_goal_default mid_goal_opt
        |> normalize_goal_horizon_text
      in
      let long_goal =
        Option.value ~default:long_goal_default long_goal_opt
        |> normalize_goal_horizon_text
      in
      let models =
        if models_in <> [] then models_in
        else if old.models <> [] then old.models
        else if profile_defaults.models <> [] then profile_defaults.models
        else profile_defaults.allowed_models
      in
      let allowed_models =
        resolve_allowed_models
          ~explicit_allowed_models:allowed_models_in
          ~seed_allowed_models:
            (if old.allowed_models <> [] then old.allowed_models
             else profile_defaults.allowed_models)
          ~models
      in
      let active_model =
        active_model_opt
        |> first_some
             (if String.trim old.active_model <> "" then Some old.active_model else None)
        |> first_some profile_defaults.active_model
        |> Option.value
             ~default:
               (match models with
                | model :: _ -> model
                | [] -> "")
      in
      let policy_mode =
        first_some
          policy_mode_opt
          (first_some
             (if String.trim old.policy_mode <> "" then Some old.policy_mode else None)
             profile_defaults.policy_mode)
        |> Option.value ~default:"heuristic"
        |> canonical_policy_mode
      in
      let policy_action_budget =
        first_some
          policy_action_budget_opt
          (first_some
             (if String.trim old.policy_action_budget <> "" then Some old.policy_action_budget else None)
             profile_defaults.policy_action_budget)
        |> Option.value ~default:"conversation"
        |> canonical_policy_action_budget
      in
      let policy_reward_model_path =
        first_some
          policy_reward_model_path_opt
          (first_some
             (if String.trim old.policy_reward_model_path <> "" then Some old.policy_reward_model_path else None)
             profile_defaults.policy_reward_model_path)
        |> Option.value ~default:""
        |> resolve_reward_model_path
      in
      let policy_voice_enabled =
        first_some
          policy_voice_enabled_opt
          (first_some (Some old.policy_voice_enabled) profile_defaults.policy_voice_enabled)
        |> Option.value ~default:false
      in
      let policy_shell_mode =
        first_some
          policy_shell_mode_opt
          (first_some (Some old.policy_shell_mode) profile_defaults.policy_shell_mode)
        |> Option.value ~default:"disabled"
        |> canonical_policy_shell_mode
      in
      let initiative_enabled =
        first_some
          initiative_enabled_opt
          (first_some (Some old.initiative_enabled) profile_defaults.initiative_enabled)
        |> Option.value ~default:false
      in
      let initiative_scope =
        first_some
          initiative_scope_opt
          (first_some (Some old.initiative_scope) profile_defaults.initiative_scope)
        |> Option.value ~default:"board_only"
        |> canonical_initiative_scope
      in
      let initiative_idle_sec =
        first_some
          initiative_idle_sec_opt
          (first_some (Some old.initiative_idle_sec) profile_defaults.initiative_idle_sec)
        |> Option.value ~default:3600
        |> normalize_initiative_idle_sec
      in
      let initiative_cooldown_sec =
        first_some
          initiative_cooldown_sec_opt
          (first_some (Some old.initiative_cooldown_sec) profile_defaults.initiative_cooldown_sec)
        |> Option.value ~default:3600
        |> normalize_initiative_cooldown_sec
      in
      let initiative_context_mode =
        first_some
          initiative_context_mode_opt
          (first_some (Some old.initiative_context_mode) profile_defaults.initiative_context_mode)
        |> Option.value ~default:"board_snapshot"
        |> canonical_initiative_context_mode
      in
      let initiative_post_ttl_hours =
        first_some
          initiative_post_ttl_hours_opt
          (first_some (Some old.initiative_post_ttl_hours) profile_defaults.initiative_post_ttl_hours)
        |> Option.value ~default:24
        |> normalize_initiative_post_ttl_hours
      in
      let room_scope =
        room_scope_opt
        |> first_some
             (if String.trim old.room_scope <> "" then Some old.room_scope else None)
        |> first_some profile_defaults.room_scope
        |> Option.value ~default:"current"
        |> canonical_room_scope
      in
      let scope_kind =
        scope_kind_opt
        |> first_some
             (if String.trim old.scope_kind <> "" then Some old.scope_kind else None)
        |> first_some profile_defaults.scope_kind
        |> Option.value ~default:(if room_scope = "all" then "global" else "local")
        |> canonical_scope_kind
      in
      let trigger_mode =
        trigger_mode_opt
        |> first_some
             (if String.trim old.trigger_mode <> "" then Some old.trigger_mode else None)
        |> first_some profile_defaults.trigger_mode
        |> Option.value ~default:"legacy"
        |> canonical_trigger_mode
      in
      let mention_targets =
        let base =
          if mention_targets_in <> [] then mention_targets_in
          else if old.mention_targets <> [] then old.mention_targets
          else if profile_defaults.mention_targets <> [] then profile_defaults.mention_targets
          else [ name ]
        in
        base |> List.filter (fun s -> String.trim s <> "") |> dedupe_keep_order
      in
      let (compaction_profile, compaction_ratio_gate, compaction_message_gate, compaction_token_gate) =
        resolve_compaction_policy
          ~profile_opt:compaction_profile_opt
          ~ratio_opt:compaction_ratio_gate_opt
          ~message_opt:compaction_message_gate_opt
          ~token_opt:compaction_token_gate_opt
          ~fallback_profile:old.compaction_profile
          ~fallback_ratio:old.compaction_ratio_gate
          ~fallback_message:old.compaction_message_gate
          ~fallback_token:old.compaction_token_gate
      in
      if policy_mode = "heuristic" && policy_action_budget <> "conversation" then
        (false, "❌ policy_action_budget=board requires policy_mode=learned_offline_v1")
      else if policy_voice_enabled && policy_mode <> "learned_offline_v1" then
        (false, "❌ policy_voice_enabled=true requires policy_mode=learned_offline_v1")
      else if policy_shell_mode = "readonly" && policy_mode <> "learned_offline_v1" then
        (false, "❌ policy_shell_mode=readonly requires policy_mode=learned_offline_v1")
      else if initiative_enabled && (policy_mode <> "learned_offline_v1" || policy_action_budget <> "board") then
        (false, "❌ initiative_enabled=true requires policy_mode=learned_offline_v1 and policy_action_budget=board")
      else
      let updated = { old with
        goal;
        short_goal;
        mid_goal;
        long_goal;
        soul_profile =
          Option.value
            ~default:
              (if String.trim old.soul_profile <> "" then old.soul_profile
               else Option.value ~default:default_soul_profile profile_defaults.soul_profile)
            soul_profile_opt;
        will =
          Option.value
            ~default:
              (if String.trim old.will <> "" then old.will
               else Option.value ~default:default_keeper_will profile_defaults.will)
            will_opt;
        needs =
          Option.value
            ~default:
              (if String.trim old.needs <> "" then old.needs
               else Option.value ~default:default_keeper_needs profile_defaults.needs)
            needs_opt;
        desires =
          Option.value
            ~default:
              (if String.trim old.desires <> "" then old.desires
               else Option.value ~default:default_keeper_desires profile_defaults.desires)
            desires_opt;
        instructions =
          Option.value
            ~default:
              (if String.trim old.instructions <> "" then old.instructions
               else Option.value ~default:"" profile_defaults.instructions)
            instructions_opt;
        models;
        allowed_models;
        active_model;
        policy_mode;
        policy_action_budget;
        policy_reward_model_path;
        policy_voice_enabled;
        policy_shell_mode;
        initiative_enabled;
        initiative_scope;
        initiative_idle_sec;
        initiative_cooldown_sec;
        initiative_context_mode;
        initiative_post_ttl_hours;
        scope_kind;
        room_scope;
        trigger_mode;
        voice_enabled =
          Option.value ~default:old.voice_enabled voice_enabled_opt;
        voice_channel =
          (voice_channel_opt
          |> Option.map canonical_voice_channel
          |> Option.value ~default:old.voice_channel);
        voice_agent_id =
          Option.value ~default:old.voice_agent_id voice_agent_id_opt;
        mention_targets;
        persona_profile_path =
          if String.trim old.persona_profile_path <> "" then old.persona_profile_path
          else Option.value ~default:"" profile_defaults.manifest_path;
        verify = Option.value ~default:old.verify verify_opt;
        presence_keepalive =
          Option.value
            ~default:
              (Option.value ~default:old.presence_keepalive profile_defaults.presence_keepalive)
            presence_keepalive_opt;
        presence_keepalive_sec =
          Option.value
            ~default:
              (Option.value
                 ~default:old.presence_keepalive_sec
                 profile_defaults.presence_keepalive_sec)
            presence_keepalive_sec_opt;
        proactive_enabled =
          Option.value
            ~default:
              (Option.value
                 ~default:
                   (if
                      trigger_mode
                      |> Keeper_contract.trigger_mode_of_string
                      |> Keeper_contract.trigger_mode_is_explicit_only
                    then false
                    else old.proactive_enabled)
                 profile_defaults.proactive_enabled)
            proactive_enabled_opt;
        proactive_idle_sec =
          Option.value ~default:old.proactive_idle_sec proactive_idle_sec_opt
          |> normalize_proactive_idle_sec;
        proactive_cooldown_sec =
          Option.value ~default:old.proactive_cooldown_sec proactive_cooldown_sec_opt
          |> normalize_proactive_cooldown_sec;
        drift_enabled = Option.value ~default:old.drift_enabled drift_enabled_opt;
        drift_min_turn_gap =
          Option.value ~default:old.drift_min_turn_gap drift_min_turn_gap_opt
          |> normalize_drift_min_turn_gap;
        compaction_profile;
        compaction_ratio_gate;
        compaction_message_gate;
        compaction_token_gate;
        continuity_compaction_cooldown_sec =
          Option.value
            ~default:old.continuity_compaction_cooldown_sec
            continuity_compaction_cooldown_sec_opt
          |> normalize_continuity_compaction_cooldown_sec;
        auto_handoff = Option.value ~default:old.auto_handoff auto_handoff_opt;
        handoff_threshold = Option.value ~default:old.handoff_threshold handoff_threshold_opt;
        handoff_cooldown_sec = Option.value ~default:old.handoff_cooldown_sec handoff_cooldown_sec_opt;
        context_budget = Option.value ~default:old.context_budget context_budget_opt;
        auto_team_session_enabled =
          Option.value
            ~default:old.auto_team_session_enabled
            auto_team_session_enabled_opt;
        updated_at = now_iso ();
      } in
      (match write_meta ctx.config updated with
       | Error e -> (false, "❌ " ^ e)
       | Ok () ->
         stop_keepalive updated.name;
         start_keepalive ctx updated;
         (true, Yojson.Safe.pretty_to_string (meta_to_json updated)))

