(** Keeper_turn — keeper lifecycle and message-turn handlers. *)

open Tool_args
open Keeper_types
open Keeper_memory
open Keeper_alerting
open Keeper_exec_tools
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
        (match model_specs_of_strings requested_models with
         | Error e -> (false, "❌ " ^ e)
         | Ok specs ->
           (match ensure_api_keys specs with
           | Error e -> (false, "❌ " ^ e)
           | Ok () ->
             let trace_id = generate_trace_id () in
             let primary = match specs with
               | m :: _ -> m
               | [] -> Llm_client.default_local_model_spec ()
             in
             let base_dir = session_base_dir ctx.config in
             mkdir_p base_dir;
             let session = Context_manager.create_session ~session_id:trace_id ~base_dir in
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
             let ctx0 = Context_manager.create ~system_prompt ~max_tokens:primary.max_context in
             (try ignore (save_checkpoint session ctx0 ~generation:0)
              with exn -> log_keeper_exn ~label:"save_checkpoint (init) failed" exn);
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
                autonomy_level =
                  Keeper_contract.autonomy_level_to_storage_string Keeper_autonomy.L1_Reactive;
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
               (true, Yojson.Safe.pretty_to_string json)))
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

let auto_team_session_spawn_profile = "generic_pair_v1"

let write_meta_logged config (meta : keeper_meta) =
  match write_meta config meta with
  | Ok () -> ()
  | Error msg ->
      Printf.eprintf "[keeper] write_meta failed: %s\n%!" msg

let _keeper_team_session_model (meta : keeper_meta) =
  let active_model = String.trim meta.active_model in
  if active_model <> "" && not (String.equal active_model "default") then
    active_model
  else
    match meta.models with
    | model :: _ -> model
    | [] -> "default"

let keeper_team_session_note (meta : keeper_meta) (message : string) =
  Printf.sprintf
    "[keeper auto-team-session]\nkeeper=%s\nrequest=%s\nkeeper_goal=%s\ninstructions=%s"
    meta.name
    (short_preview ~max_len:240 message)
    (short_preview ~max_len:180 meta.goal)
    (short_preview ~max_len:220 meta.instructions)

let planner_spawn_prompt (meta : keeper_meta) (message : string) =
  Printf.sprintf
    "You are planner worker for keeper %s.\n\
     Incoming request:\n%s\n\n\
     Keeper goal:\n%s\n\n\
     Keeper instructions:\n%s\n\n\
     Leave exactly one non-empty planning note via masc_team_session_step that states:\n\
     - intended scope\n\
     - concrete success criteria\n\
     - first work split\n"
    meta.name message meta.goal
    (if String.trim meta.instructions = "" then "(none)" else meta.instructions)

let executor_spawn_prompt (meta : keeper_meta) (message : string) =
  Printf.sprintf
    "You are executor worker for keeper %s.\n\
     Incoming request:\n%s\n\n\
     Keeper goal:\n%s\n\n\
     Keeper instructions:\n%s\n\n\
     Leave exactly one non-empty execution note via masc_team_session_step that states:\n\
     - first concrete action\n\
     - likely files/surfaces/tools to inspect\n\
     - immediate blocker if any\n"
    meta.name message meta.goal
    (if String.trim meta.instructions = "" then "(none)" else meta.instructions)

let auto_team_session_spawn_batch (meta : keeper_meta) (message : string) =
  `List
    [
      `Assoc
        [
          ("spawn_prompt", `String (planner_spawn_prompt meta message));
          ("spawn_role", `String "planner");
          ("worker_class", `String "manager");
          ("worker_size", `String "xlg");
          ("spawn_timeout_seconds", `Int 120);
          ("spawn_selection_note", `String "keeper auto-team-session generic_pair_v1 planner");
        ];
      `Assoc
        [
          ("spawn_prompt", `String (executor_spawn_prompt meta message));
          ("spawn_role", `String "executor");
          ("worker_class", `String "executor");
          ("worker_size", `String "lg");
          ("spawn_timeout_seconds", `Int 120);
          ("spawn_selection_note", `String "keeper auto-team-session generic_pair_v1 executor");
        ];
    ]

let team_session_ctx_of_keeper (ctx : _ context) : _ Tool_team_session.context =
  {
    Tool_team_session.config = ctx.config;
    agent_name = ctx.agent_name;
    sw = ctx.sw;
    clock = ctx.clock;
    proc_mgr = ctx.proc_mgr;
  }

let dispatch_team_session (ctx : _ context) ~name ~args =
  match Tool_team_session.dispatch (team_session_ctx_of_keeper ctx) ~name ~args with
  | Some result -> result
  | None -> (false, Yojson.Safe.to_string (`Assoc [ ("status", `String "error"); ("message", `String "team session dispatch unavailable") ]))

let parse_result_json body =
  try
    let open Yojson.Safe.Util in
    let json = Yojson.Safe.from_string body in
    Ok (json |> member "result")
  with Yojson.Json_error err ->
    Error ("invalid json: " ^ err)

let session_id_of_result_json json =
  try Some Yojson.Safe.Util.(json |> member "session_id" |> to_string)
  with Yojson.Safe.Util.Type_error _ -> None

let _bool_option_to_json = function
  | Some value -> `Bool value
  | None -> `Null

let string_option_to_json = function
  | Some value -> `String value
  | None -> `Null

let running_session_for_keeper config (meta : keeper_meta) =
  match meta.active_team_session_id with
  | None -> (meta, None)
  | Some session_id -> (
      match Team_session_store.load_session config session_id with
      | Some session when session.status = Team_session_types.Running ->
          (meta, Some session)
      | _ ->
          let updated =
            {
              meta with
              active_team_session_id = None;
              updated_at = now_iso ();
            }
          in
          write_meta_logged config updated;
          (updated, None))

let keeper_auto_team_session_response_json
    ~(meta : keeper_meta)
    ~(session : Team_session_types.session)
    ~(created : bool)
    ~(reused : bool)
    ?spawn_error
    () =
  `Assoc
    [
      ( "reply",
        `String
          (Printf.sprintf
             "Team session %s is ready. Use masc_team_session_status or masc_team_session_step."
             session.session_id) );
      ("mode", `String "team_session");
      ("keeper_name", `String meta.name);
      ("session_id", `String session.session_id);
      ("created", `Bool created);
      ("reused", `Bool reused);
      ("session_status", `String (Team_session_types.status_to_string session.status));
      ("spawn_profile", `String auto_team_session_spawn_profile);
      ("spawned_roles", `List [ `String "planner"; `String "executor" ]);
      ("spawn_error", string_option_to_json spawn_error);
      ("active_team_session_id", string_option_to_json meta.active_team_session_id);
      ("last_team_session_started_at", `String meta.last_team_session_started_at);
      ("team_session_start_count_total", `Int meta.team_session_start_count_total);
      ("next_read_tool", `String "masc_team_session_status");
      ("next_write_tool", `String "masc_team_session_step");
    ]

let start_keeper_auto_team_session (ctx : _ context) (meta : keeper_meta)
    (message : string) :
    (keeper_meta * Team_session_types.session * string option, string) result =
  let start_args =
    `Assoc
      [
        ("goal", `String message);
        ("duration_seconds", `Int 3600);
        ("execution_scope", `String "observe_only");
        ("checkpoint_interval_sec", `Int 60);
        ("min_agents", `Int 2);
        ("auto_resume", `Bool true);
        ("report_formats", `List [ `String "markdown"; `String "json" ]);
        ("orchestration_mode", `String "assist");
        ("communication_mode", `String "hybrid");
        ("instruction_profile", `String "strict");
        ("alert_channel", `String "both");
        ("model_cascade", `List (List.map (fun model -> `String model) meta.models));
        ( "agents",
          `List
            (Team_session_types.dedup_strings
               [ ctx.agent_name; meta.agent_name ]
            |> List.map (fun agent -> `String agent)) );
      ]
  in
  let start_ok, start_body =
    dispatch_team_session ctx ~name:"masc_team_session_start" ~args:start_args
  in
  if not start_ok then
    Error ("team session start failed: " ^ start_body)
  else
    match parse_result_json start_body with
    | Error msg -> Error ("team session start parse failed: " ^ msg)
    | Ok start_json -> (
        match session_id_of_result_json start_json with
        | None -> Error "team session start missing session_id"
        | Some session_id -> (
            match Team_session_store.load_session ctx.config session_id with
            | None -> Error ("team session not found after start: " ^ session_id)
            | Some session ->
                let updated_meta =
                  {
                    meta with
                    active_team_session_id = Some session_id;
                    last_team_session_started_at = now_iso ();
                    team_session_start_count_total =
                      meta.team_session_start_count_total + 1;
                    updated_at = now_iso ();
                  }
                in
                write_meta_logged ctx.config updated_meta;
                let note_args =
                  `Assoc
                    [
                      ("session_id", `String session_id);
                      ("turn_kind", `String "note");
                      ("message", `String (keeper_team_session_note updated_meta message));
                    ]
                in
                let note_ok, note_body =
                  dispatch_team_session ctx ~name:"masc_team_session_step"
                    ~args:note_args
                in
                if not note_ok then
                  Error ("team session note failed: " ^ note_body)
                else
                  let spawn_args =
                    `Assoc
                      [
                        ("session_id", `String session_id);
                        ("spawn_batch", auto_team_session_spawn_batch updated_meta message);
                      ]
                  in
                  let spawn_ok, spawn_body =
                    dispatch_team_session ctx ~name:"masc_team_session_step"
                      ~args:spawn_args
                  in
                  let spawn_error =
                    if spawn_ok then None else Some spawn_body
                  in
                  Ok (updated_meta, session, spawn_error)))

let append_keeper_auto_team_session_note (ctx : _ context) (meta : keeper_meta)
    (session : Team_session_types.session) (message : string) :
    (Team_session_types.session, string) result =
  let note_args =
    `Assoc
      [
        ("session_id", `String session.session_id);
        ("turn_kind", `String "note");
        ("message", `String (keeper_team_session_note meta message));
      ]
  in
  let ok, body =
    dispatch_team_session ctx ~name:"masc_team_session_step" ~args:note_args
  in
  if not ok then
    Error ("team session note failed: " ^ body)
  else
    match Team_session_store.load_session ctx.config session.session_id with
    | Some refreshed -> Ok refreshed
    | None -> Error ("team session disappeared after note: " ^ session.session_id)

let maybe_handle_auto_team_session (ctx : _ context) (meta : keeper_meta)
    (message : string) :
    ((tool_result option * keeper_meta), string) result =
  if not meta.auto_team_session_enabled then
    Ok (None, meta)
  else
    let linked_meta, running_session = running_session_for_keeper ctx.config meta in
    match running_session with
    | Some session -> (
        match append_keeper_auto_team_session_note ctx linked_meta session message with
        | Error err -> Error err
        | Ok session' ->
            let json =
              keeper_auto_team_session_response_json
                ~meta:linked_meta ~session:session' ~created:false ~reused:true ()
            in
            Ok (Some (true, Yojson.Safe.pretty_to_string json), linked_meta))
    | None -> (
        match start_keeper_auto_team_session ctx linked_meta message with
        | Error err -> Error err
        | Ok (updated_meta, session, spawn_error) ->
            let json =
              keeper_auto_team_session_response_json
                ~meta:updated_meta ~session ~created:true ~reused:false
                ?spawn_error ()
            in
            Ok (Some (true, Yojson.Safe.pretty_to_string json), updated_meta))

(* ── Shared types and helpers for handle_keeper_msg decomposition ───── *)

(** Captures all turn-level values needed by the response builder. *)
type turn_env = {
  meta_turn : keeper_meta;
  safe_reply : string;
  final_usage : Llm_client.token_usage;
  final_model_used : string;
  final_latency_ms : int;
  total_cost_usd_turn : float;
  ctx_ratio : float;
  ctx_work : Context_manager.working_context;
  compacted : bool;
  before_compact_tokens : int;
  after_compact_tokens : int;
  compaction_trigger : string option;
  compaction_decision : string;
  work_kind : string;
  tool_call_count : int;
  tools_used : string list;
  effective_skill_route : keeper_skill_route;
  skill_route_resolution : keeper_skill_route_resolution;
  memory_check_json : Yojson.Safe.t;
  auto_rules : keeper_auto_rule_eval;
  drift_applied : bool;
  drift_reason : string option;
  repetition_risk : float;
  goal_alignment : float;
  response_alignment : float;
  memory_notes_added : int;
  memory_note_kinds : string list;
  memory_top_kind : string option;
  memory_compaction : memory_bank_compaction;
  interesting_alert : interesting_alert_result;
}

(** Build the common JSON fields shared between normal-turn and handoff metrics/response. *)
let build_turn_metrics_fields (env : turn_env) : (string * Yojson.Safe.t) list =
  let meta = env.meta_turn in
  [
    ("model_used", `String env.final_model_used);
    ("usage", `Assoc [
      ("input_tokens", `Int env.final_usage.input_tokens);
      ("output_tokens", `Int env.final_usage.output_tokens);
      ("total_tokens", `Int env.final_usage.total_tokens);
    ]);
    ("latency_ms", `Int env.final_latency_ms);
    ("cost_usd", `Float env.total_cost_usd_turn);
    ("context_ratio", `Float env.ctx_ratio);
    ("context_tokens", `Int env.ctx_work.token_count);
    ("context_max", `Int env.ctx_work.max_tokens);
    ("message_count", `Int (List.length env.ctx_work.messages));
    ("compacted", `Bool env.compacted);
    ("compaction_before_tokens", `Int env.before_compact_tokens);
    ("compaction_after_tokens", `Int env.after_compact_tokens);
    ( "compaction_trigger",
      match env.compaction_trigger with
      | Some reason -> `String reason
      | None -> `Null );
    ("compaction_decision", `String env.compaction_decision);
    ("work_kind", `String env.work_kind);
    ("tool_call_count", `Int env.tool_call_count);
    ("tools_used", `List (List.map (fun s -> `String s) env.tools_used));
    ("skill_primary", `String env.effective_skill_route.primary_skill);
    ("skill_secondary",
      `List (List.map (fun s -> `String s) env.effective_skill_route.secondary_skills));
    ("skill_reason", `String env.effective_skill_route.reason);
    ("skill_selection_mode",
      `String env.skill_route_resolution.selection_mode);
    ("skill_provenance",
      `String env.skill_route_resolution.provenance);
    ("memory_check", env.memory_check_json);
    ("auto_rules", keeper_auto_rule_eval_to_json env.auto_rules);
    ("reflection", keeper_reflection_payload_of_auto_rules env.auto_rules);
    ("auto_reflect", `Bool env.auto_rules.reflect);
    ("auto_plan", `Bool env.auto_rules.plan);
    ("auto_compact", `Bool env.auto_rules.compact);
    ("auto_handoff", `Bool env.auto_rules.handoff);
    ("guardrail_stop", `Bool env.auto_rules.guardrail_stop);
    ("guardrail_stop_reason",
      match env.auto_rules.guardrail_reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("repetition_risk", `Float env.repetition_risk);
    ("goal_alignment", `Float env.goal_alignment);
    ("response_alignment", `Float env.response_alignment);
    ("goal_drift", `Float env.auto_rules.goal_drift);
    ("drift", `Assoc [
      ("enabled", `Bool meta.drift_enabled);
      ("applied", `Bool env.drift_applied);
      ("reason",
        match env.drift_reason with
        | Some reason -> `String reason
        | None -> `Null);
      ("min_turn_gap", `Int meta.drift_min_turn_gap);
      ("count_total", `Int meta.drift_count_total);
      ("last_turn", `Int meta.last_drift_turn);
      ("last_reason",
        if String.trim meta.last_drift_reason = ""
        then `Null
        else `String meta.last_drift_reason);
    ]);
    ("memory_notes_added", `Int env.memory_notes_added);
    ("memory_note_kinds",
      `List (List.map (fun s -> `String s) env.memory_note_kinds));
    ("memory_top_kind",
      match env.memory_top_kind with
      | Some kind -> `String kind
      | None -> `Null);
    ("memory_compaction_performed", `Bool env.memory_compaction.performed);
    ("memory_compaction_reason",
      match env.memory_compaction.reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("memory_compaction_target_notes", `Int env.memory_compaction.target_notes);
    ("memory_compaction_before_notes", `Int env.memory_compaction.before_notes);
    ("memory_compaction_after_notes", `Int env.memory_compaction.after_notes);
    ("memory_compaction_dropped_notes", `Int env.memory_compaction.dropped_notes);
    ("memory_compaction_dedup_dropped", `Int env.memory_compaction.dedup_dropped);
    ("memory_compaction_invalid_dropped", `Int env.memory_compaction.invalid_dropped);
  ]

(** Build the metrics JSONL for a normal turn (no handoff). *)
let build_normal_turn_metrics_json ~now_ts (env : turn_env) : Yojson.Safe.t =
  let meta = env.meta_turn in
  `Assoc ([
    ("ts", `String (now_iso ()));
    ("ts_unix", `Float now_ts);
    ("channel", `String "turn");
    ("name", `String meta.name);
    ("agent_name", `String meta.agent_name);
    ("trace_id", `String meta.trace_id);
    ("generation", `Int meta.generation);
  ] @ build_turn_metrics_fields env @ [
    ("interesting_alert_triggered", `Bool env.interesting_alert.triggered);
    ("interesting_alert_score", `Float env.interesting_alert.score);
    ("interesting_alert", interesting_alert_result_to_json env.interesting_alert);
    ("handoff", `Assoc [("performed", `Bool false)]);
  ])

(** Build the response JSON for a normal turn (no handoff). *)
let build_normal_turn_response_json (env : turn_env) : Yojson.Safe.t =
  let meta = env.meta_turn in
  `Assoc ([
    ("name", `String meta.name);
    ("trace_id", `String meta.trace_id);
    ("generation", `Int meta.generation);
    ("soul_profile", `String meta.soul_profile);
    ("will", if String.trim meta.will = "" then `Null else `String meta.will);
    ("needs", if String.trim meta.needs = "" then `Null else `String meta.needs);
    ("desires", if String.trim meta.desires = "" then `Null else `String meta.desires);
    ("model_used", `String env.final_model_used);
    ("usage", `Assoc [
      ("input_tokens", `Int env.final_usage.input_tokens);
      ("output_tokens", `Int env.final_usage.output_tokens);
      ("total_tokens", `Int env.final_usage.total_tokens);
    ]);
    ("latency_ms", `Int env.final_latency_ms);
    ("cost_usd", `Float env.total_cost_usd_turn);
    ("reply", `String env.safe_reply);
    ("context_ratio", `Float env.ctx_ratio);
    ("compacted", `Bool env.compacted);
    ( "compaction_trigger",
      match env.compaction_trigger with
      | Some reason -> `String reason
      | None -> `Null );
    ("work_kind", `String env.work_kind);
    ("tool_call_count", `Int env.tool_call_count);
    ("tools_used", `List (List.map (fun s -> `String s) env.tools_used));
    ("skill_primary", `String env.effective_skill_route.primary_skill);
    ("skill_secondary",
      `List (List.map (fun s -> `String s) env.effective_skill_route.secondary_skills));
    ("skill_reason", `String env.effective_skill_route.reason);
    ("skill_selection_mode",
      `String env.skill_route_resolution.selection_mode);
    ("skill_provenance",
      `String env.skill_route_resolution.provenance);
    ("memory_check", env.memory_check_json);
    ("auto_rules", keeper_auto_rule_eval_to_json env.auto_rules);
    ("reflection", keeper_reflection_payload_of_auto_rules env.auto_rules);
    ("auto_reflect", `Bool env.auto_rules.reflect);
    ("auto_plan", `Bool env.auto_rules.plan);
    ("auto_compact", `Bool env.auto_rules.compact);
    ("auto_handoff", `Bool env.auto_rules.handoff);
    ("guardrail_stop", `Bool env.auto_rules.guardrail_stop);
    ("guardrail_stop_reason",
      match env.auto_rules.guardrail_reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("repetition_risk", `Float env.repetition_risk);
    ("goal_alignment", `Float env.goal_alignment);
    ("response_alignment", `Float env.response_alignment);
    ("goal_drift", `Float env.auto_rules.goal_drift);
    ("drift", `Assoc [
      ("enabled", `Bool meta.drift_enabled);
      ("applied", `Bool env.drift_applied);
      ("reason",
        match env.drift_reason with
        | Some reason -> `String reason
        | None -> `Null);
      ("min_turn_gap", `Int meta.drift_min_turn_gap);
      ("count_total", `Int meta.drift_count_total);
      ("last_turn", `Int meta.last_drift_turn);
      ("last_reason",
        if String.trim meta.last_drift_reason = ""
        then `Null
        else `String meta.last_drift_reason);
    ]);
    ("memory_notes_added", `Int env.memory_notes_added);
    ("memory_note_kinds",
      `List (List.map (fun s -> `String s) env.memory_note_kinds));
    ("memory_top_kind",
      match env.memory_top_kind with
      | Some kind -> `String kind
      | None -> `Null);
    ("memory_compaction_performed", `Bool env.memory_compaction.performed);
    ("memory_compaction_reason",
      match env.memory_compaction.reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("memory_compaction_target_notes", `Int env.memory_compaction.target_notes);
    ("memory_compaction_before_notes", `Int env.memory_compaction.before_notes);
    ("memory_compaction_after_notes", `Int env.memory_compaction.after_notes);
    ("memory_compaction_dropped_notes", `Int env.memory_compaction.dropped_notes);
    ("memory_compaction_dedup_dropped", `Int env.memory_compaction.dedup_dropped);
    ("memory_compaction_invalid_dropped", `Int env.memory_compaction.invalid_dropped);
    ("interesting_alert", interesting_alert_result_to_json env.interesting_alert);
  ])

(** Build the handoff metrics JSONL entry. *)
let build_handoff_metrics_json ~now_ts ~prev_trace_id ~next_model_id ~new_generation
    (env : turn_env) : Yojson.Safe.t =
  let meta = env.meta_turn in
  `Assoc ([
    ("ts", `String (now_iso ()));
    ("ts_unix", `Float now_ts);
    ("channel", `String "turn");
    ("name", `String meta.name);
    ("agent_name", `String meta.agent_name);
    ("trace_id", `String prev_trace_id);
    ("generation", `Int meta.generation);
  ] @ build_turn_metrics_fields env @ [
    ("interesting_alert_triggered", `Bool env.interesting_alert.triggered);
    ("interesting_alert_score", `Float env.interesting_alert.score);
    ("interesting_alert", interesting_alert_result_to_json env.interesting_alert);
    ("handoff", `Assoc [
      ("performed", `Bool true);
      ("prev_trace_id", `String prev_trace_id);
      ("new_trace_id", `String env.meta_turn.trace_id);
      ("to_model", `String next_model_id);
      ("new_generation", `Int new_generation);
    ]);
  ])

(** Build the handoff response JSON. *)
let build_handoff_response_json ~prev_trace_id ~next_model_id ~new_generation
    (env : turn_env) : Yojson.Safe.t =
  let meta = env.meta_turn in
  `Assoc [
    ("name", `String meta.name);
    ("soul_profile", `String meta.soul_profile);
    ("will", if String.trim meta.will = "" then `Null else `String meta.will);
    ("needs", if String.trim meta.needs = "" then `Null else `String meta.needs);
    ("desires", if String.trim meta.desires = "" then `Null else `String meta.desires);
    ("reply", `String env.safe_reply);
    ("model_used", `String env.final_model_used);
    ("latency_ms", `Int env.final_latency_ms);
    ("cost_usd", `Float env.total_cost_usd_turn);
    ("context_ratio", `Float env.ctx_ratio);
    ("compacted", `Bool env.compacted);
    ( "compaction_trigger",
      match env.compaction_trigger with
      | Some reason -> `String reason
      | None -> `Null );
    ("work_kind", `String env.work_kind);
    ("tool_call_count", `Int env.tool_call_count);
    ("tools_used", `List (List.map (fun s -> `String s) env.tools_used));
    ("skill_primary", `String env.effective_skill_route.primary_skill);
    ("skill_secondary",
      `List (List.map (fun s -> `String s) env.effective_skill_route.secondary_skills));
    ("skill_reason", `String env.effective_skill_route.reason);
    ("skill_selection_mode",
      `String env.skill_route_resolution.selection_mode);
    ("skill_provenance",
      `String env.skill_route_resolution.provenance);
    ("memory_check", env.memory_check_json);
    ("auto_rules", keeper_auto_rule_eval_to_json env.auto_rules);
    ("reflection", keeper_reflection_payload_of_auto_rules env.auto_rules);
    ("auto_reflect", `Bool env.auto_rules.reflect);
    ("auto_plan", `Bool env.auto_rules.plan);
    ("auto_compact", `Bool env.auto_rules.compact);
    ("auto_handoff", `Bool env.auto_rules.handoff);
    ("guardrail_stop", `Bool env.auto_rules.guardrail_stop);
    ("guardrail_stop_reason",
      match env.auto_rules.guardrail_reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("repetition_risk", `Float env.repetition_risk);
    ("goal_alignment", `Float env.goal_alignment);
    ("response_alignment", `Float env.response_alignment);
    ("goal_drift", `Float env.auto_rules.goal_drift);
    ("drift", `Assoc [
      ("enabled", `Bool meta.drift_enabled);
      ("applied", `Bool env.drift_applied);
      ("reason",
        match env.drift_reason with
        | Some reason -> `String reason
        | None -> `Null);
      ("min_turn_gap", `Int meta.drift_min_turn_gap);
      ("count_total", `Int meta.drift_count_total);
      ("last_turn", `Int meta.last_drift_turn);
      ("last_reason",
        if String.trim meta.last_drift_reason = ""
        then `Null
        else `String meta.last_drift_reason);
    ]);
    ("memory_notes_added", `Int env.memory_notes_added);
    ("memory_note_kinds",
      `List (List.map (fun s -> `String s) env.memory_note_kinds));
    ("memory_top_kind",
      match env.memory_top_kind with
      | Some kind -> `String kind
      | None -> `Null);
    ("memory_compaction_performed", `Bool env.memory_compaction.performed);
    ("memory_compaction_reason",
      match env.memory_compaction.reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("memory_compaction_target_notes", `Int env.memory_compaction.target_notes);
    ("memory_compaction_before_notes", `Int env.memory_compaction.before_notes);
    ("memory_compaction_after_notes", `Int env.memory_compaction.after_notes);
    ("memory_compaction_dropped_notes", `Int env.memory_compaction.dropped_notes);
    ("memory_compaction_dedup_dropped", `Int env.memory_compaction.dedup_dropped);
    ("memory_compaction_invalid_dropped", `Int env.memory_compaction.invalid_dropped);
    ("interesting_alert", interesting_alert_result_to_json env.interesting_alert);
    ("handoff", `Assoc [
      ("performed", `Bool true);
      ("prev_trace_id", `String prev_trace_id);
      ("new_trace_id", `String env.meta_turn.trace_id);
      ("to_model", `String next_model_id);
      ("new_generation", `Int new_generation);
    ]);
  ]

(** Emit SSE events + write metrics + finalize trajectory for a normal turn. *)
let finalize_normal_turn ctx ~session ~now_ts ~trajectory_acc ~gate_config (env : turn_env) : tool_result =
  let meta_turn = env.meta_turn in
  (match write_meta ctx.config meta_turn with
   | Ok () -> ()
   | Error e -> Printf.eprintf "[keeper:%s] failed to write meta: %s\n%!" meta_turn.name e);
  let metrics_path = keeper_metrics_path ctx.config meta_turn.name in
  (try
     let metrics_json = build_normal_turn_metrics_json ~now_ts env in
     append_jsonl_line metrics_path metrics_json
   with exn ->
     log_keeper_exn ~label:"turn metrics JSONL write failed" exn);
  (* Harness: finalize trajectory with outcome *)
  (let traj_outcome =
    if trajectory_acc.Trajectory.total_cost >= gate_config.Eval_gate.max_cost_usd then
      Trajectory.CostExceeded
    else
      Trajectory.Completed
  in
  let _traj = Trajectory.finalize trajectory_acc traj_outcome in
  Printf.eprintf "[HARNESS] Trajectory finalized: %s turns=%d calls=%d cost=$%.4f outcome=%s\n%!"
    meta_turn.trace_id
    _traj.Trajectory.total_turns
    _traj.Trajectory.total_tool_calls
    _traj.Trajectory.total_cost_usd
    (Trajectory.outcome_to_string traj_outcome));
  (* SSE: keeper_compaction — emitted only when compaction occurred *)
  (if env.compacted then
    (try Sse.broadcast (`Assoc [
      ("type", `String "keeper_compaction");
      ("name", `String meta_turn.name);
      ("saved_tokens", `Int (env.before_compact_tokens - env.after_compact_tokens));
      ("trigger", match env.compaction_trigger with
        | Some r -> `String r | None -> `Null);
    ]) with exn ->
      log_keeper_exn ~label:"SSE keeper_compaction broadcast failed" exn));
  (* SSE: keeper_turn_complete — emitted on every normal turn finish *)
  (try Sse.broadcast (`Assoc [
    ("type", `String "keeper_turn_complete");
    ("name", `String meta_turn.name);
    ("trace_id", `String meta_turn.trace_id);
    ("generation", `Int meta_turn.generation);
    ("tool_calls", `Int trajectory_acc.Trajectory.total_calls);
    ("compacted", `Bool env.compacted);
    ("context_ratio", `Float env.ctx_ratio);
    ("model_used", `String env.final_model_used);
  ]) with exn ->
    log_keeper_exn ~label:"SSE keeper_turn_complete broadcast failed" exn);
  ignore session;
  let json = build_normal_turn_response_json env in
  (true, Yojson.Safe.pretty_to_string json)

(** Execute handoff: hydrate successor context, rotate trace, emit metrics/SSE. *)
let finalize_handoff_turn ctx ~session ~now_ts ~specs ~primary ~base_dir
    ~trajectory_acc ~gate_config (env : turn_env) : tool_result =
  let meta_turn = env.meta_turn in
  let next_model =
    match specs with
    | _m0 :: m1 :: _ -> m1
    | m0 :: _ -> m0
    | [] -> primary
  in
  let metrics = Succession.{
    total_turns = meta_turn.total_turns;
    total_tokens_used = meta_turn.total_tokens;
    total_cost_usd = meta_turn.total_cost_usd;
    tasks_completed = 0;
    errors_encountered = 0;
    elapsed_seconds = 0.0;
  } in
  let successor_trace = generate_trace_id () in
  let next_generation = meta_turn.generation + 1 in
  let dna = Succession.extract_dna
    ~working_ctx:env.ctx_work
    ~session_ctx:session
    ~goal:meta_turn.goal
    ~generation:next_generation
    ~trace_id:successor_trace
    ~metrics
  in
  let spec = Succession.{
    model = next_model;
    inherit_tools = false;
    context_budget = meta_turn.context_budget;
  } in
  let successor_ctx = Succession.hydrate dna spec in
  let successor_session = Context_manager.create_session
    ~session_id:successor_trace ~base_dir in
  (try ignore (save_checkpoint successor_session successor_ctx ~generation:next_generation)
   with exn -> log_keeper_exn ~label:"save_checkpoint (succession) failed" exn);

  let prev_trace_id = meta_turn.trace_id in
  let trace_history = take 20 (prev_trace_id :: meta_turn.trace_history) in
  let meta' = { meta_turn with
    trace_id = successor_trace;
    trace_history;
    generation = next_generation;
    last_handoff_ts = now_ts;
    updated_at = now_iso ();
  } in
  (try ignore (write_meta ctx.config meta')
   with exn -> log_keeper_exn ~label:"write_meta (succession) failed" exn);

  let metrics_path = keeper_metrics_path ctx.config meta'.name in
  let env_for_handoff = { env with meta_turn = meta' } in
  (try
     let metrics_json = build_handoff_metrics_json
       ~now_ts ~prev_trace_id ~next_model_id:next_model.model_id
       ~new_generation:next_generation env_for_handoff in
     append_jsonl_line metrics_path metrics_json
   with exn ->
     log_keeper_exn ~label:"handoff metrics JSONL write failed" exn);
  (* Harness: finalize trajectory *)
  (let traj_outcome =
    if trajectory_acc.Trajectory.total_cost >= gate_config.Eval_gate.max_cost_usd then
      Trajectory.CostExceeded
    else
      Trajectory.Completed
  in
  ignore (Trajectory.finalize trajectory_acc traj_outcome));
  (* SSE: keeper_handoff — generation succession event *)
  (try Sse.broadcast (`Assoc [
    ("type", `String "keeper_handoff");
    ("name", `String meta_turn.name);
    ("from_generation", `Int meta_turn.generation);
    ("to_generation", `Int next_generation);
    ("to_model", `String next_model.model_id);
  ]) with exn ->
    log_keeper_exn ~label:"SSE keeper_handoff broadcast failed" exn);

  let json = build_handoff_response_json
    ~prev_trace_id ~next_model_id:next_model.model_id
    ~new_generation:next_generation env_for_handoff in
  (true, Yojson.Safe.pretty_to_string json)

(** Build the complete keeper response: emit side-effects + return JSON. *)
let build_keeper_response ctx ~session ~now_ts ~specs ~primary ~base_dir
    ~trajectory_acc ~gate_config ~do_handoff (env : turn_env) : tool_result =
  if not do_handoff then
    finalize_normal_turn ctx ~session ~now_ts ~trajectory_acc ~gate_config env
  else
    finalize_handoff_turn ctx ~session ~now_ts ~specs ~primary ~base_dir
      ~trajectory_acc ~gate_config env

(* ── ensure_keeper_exists: module-level function ────────────────────── *)

(** Create or load a keeper, returning its meta. Extracted from handle_keeper_msg. *)
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
    ~inline_drift_enabled_opt
    ~inline_drift_min_turn_gap_opt
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
    let drift_enabled =
      Option.value ~default:default_drift_enabled inline_drift_enabled_opt
    in
    let drift_min_turn_gap =
      Option.value ~default:default_drift_min_turn_gap inline_drift_min_turn_gap_opt
      |> normalize_drift_min_turn_gap
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
    let use_profile_policy_defaults = not (default_voice_enabled_for name) in
    let policy_action_budget =
      (if use_profile_policy_defaults then profile_defaults.policy_action_budget else None)
      |> Option.value ~default:"conversation"
      |> canonical_policy_action_budget
    in
    let policy_reward_model_path =
      (if use_profile_policy_defaults then profile_defaults.policy_reward_model_path else None)
      |> Option.value ~default:""
    in
    let policy_voice_enabled =
      (if use_profile_policy_defaults then profile_defaults.policy_voice_enabled else None)
      |> Option.value ~default:false
    in
    let policy_shell_mode =
      (if use_profile_policy_defaults then profile_defaults.policy_shell_mode else None)
      |> Option.value ~default:"disabled"
      |> canonical_policy_shell_mode
    in
    let initiative_enabled =
      (if use_profile_policy_defaults then profile_defaults.initiative_enabled else None)
      |> Option.value ~default:false
    in
    let initiative_scope =
      (if use_profile_policy_defaults then profile_defaults.initiative_scope else None)
      |> Option.value ~default:"board_only"
      |> canonical_initiative_scope
    in
    let initiative_idle_sec =
      (if use_profile_policy_defaults then profile_defaults.initiative_idle_sec else None)
      |> Option.value ~default:3600
      |> normalize_initiative_idle_sec
    in
    let initiative_cooldown_sec =
      (if use_profile_policy_defaults then profile_defaults.initiative_cooldown_sec else None)
      |> Option.value ~default:3600
      |> normalize_initiative_cooldown_sec
    in
    let initiative_context_mode =
      (if use_profile_policy_defaults then profile_defaults.initiative_context_mode else None)
      |> Option.value ~default:"board_snapshot"
      |> canonical_initiative_context_mode
    in
    let initiative_post_ttl_hours =
      (if use_profile_policy_defaults then profile_defaults.initiative_post_ttl_hours else None)
      |> Option.value ~default:24
      |> normalize_initiative_post_ttl_hours
    in
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
      will;
      needs;
      desires;
      instructions;
      models = inline_models;
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
      voice_enabled = default_voice_enabled_for name;
      voice_channel = default_voice_channel_for name;
      voice_agent_id = default_voice_agent_id_for name;
      mention_targets;
      joined_room_ids = [];
      last_seen_seq_by_room = [];
      generation = 0;
      verify = false;
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
      drift_enabled;
      drift_min_turn_gap;
      drift_count_total = 0;
      last_drift_turn = 0;
      last_drift_reason = "";
      compaction_profile = default_compaction_profile;
      compaction_ratio_gate = env_ratio_gate;
      compaction_message_gate = env_message_gate;
      compaction_token_gate = env_token_gate;
      continuity_compaction_cooldown_sec;
      auto_handoff = true;
      handoff_threshold = 0.85;
      handoff_cooldown_sec = 300;
      context_budget = 0.6;
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
      autonomy_level =
        Keeper_contract.autonomy_level_to_storage_string Keeper_autonomy.L1_Reactive;
      active_goal_ids = [];
      last_autonomous_action_at = "";
      autonomous_action_count = 0;
      deliberation_count = 0;
      deliberation_cost_total_usd = 0.0;
      last_deliberation_ts = 0.0;
      last_triage_triggers = "";
      auto_team_session_enabled = false;
      active_team_session_id = None;
      last_team_session_started_at = "";
      team_session_start_count_total = 0;
    } in
    let base_dir = session_base_dir ctx.config in
    mkdir_p base_dir;
    (match model_specs_of_strings meta.models with
     | Error e -> Error e
     | Ok specs ->
       (match ensure_api_keys specs with
        | Error e -> Error e
        | Ok () ->
          let primary = match specs with m0 :: _ -> m0 | [] -> Llm_client.default_local_model_spec () in
          let session = Context_manager.create_session ~session_id:trace_id ~base_dir in
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
          let ctx0 = Context_manager.create ~system_prompt ~max_tokens:primary.max_context in
          (try ignore (save_checkpoint session ctx0 ~generation:0)
           with exn -> log_keeper_exn ~label:"save_checkpoint (ensure) failed" exn);
          match write_meta ctx.config meta with
          | Error e -> Error e
          | Ok () -> Ok meta))

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
    ~new_drift_enabled_opt
    ~new_drift_min_turn_gap_opt
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
  let soul_profile =
    match new_soul_profile with
    | None -> meta0.soul_profile
    | Some sp -> sp
  in
  let instructions =
    match get_string_opt args "new_instructions" with
    | None -> meta0.instructions
    | Some ni -> ni
  in
  let will =
    match new_will with
    | None -> meta0.will
    | Some w -> w
  in
  let needs =
    match new_needs with
    | None -> meta0.needs
    | Some n -> n
  in
  let desires =
    match new_desires with
    | None -> meta0.desires
    | Some d -> d
  in
  let drift_enabled =
    match new_drift_enabled_opt with
    | None -> meta0.drift_enabled
    | Some v -> v
  in
  let drift_min_turn_gap =
    match new_drift_min_turn_gap_opt with
    | None -> meta0.drift_min_turn_gap
    | Some v -> normalize_drift_min_turn_gap v
  in
  if goal = meta0.goal
     && short_goal = meta0.short_goal
     && mid_goal = meta0.mid_goal
     && long_goal = meta0.long_goal
     && soul_profile = meta0.soul_profile
     && will = meta0.will
     && needs = meta0.needs
     && desires = meta0.desires
     && instructions = meta0.instructions
     && drift_enabled = meta0.drift_enabled
     && drift_min_turn_gap = meta0.drift_min_turn_gap
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
      drift_enabled;
      drift_min_turn_gap;
      updated_at = now_iso ();
    } in
    (try ignore (write_meta config updated)
     with exn -> log_keeper_exn ~label:"write_meta (settings) failed" exn);
    updated

(* ── handle_keeper_msg: orchestrator ─────────────────────────────────── *)

let handle_keeper_msg ctx args : tool_result =
  let name = get_string args "name" "" in
  let message = get_string args "message" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else if message = "" then
    (false, "❌ message is required")
  else
    let profile_defaults = load_keeper_profile_defaults name in
    let inline_goal = get_string_opt args "goal" in
    let inline_short_goal = parse_goal_horizon_opt args "short_goal" in
    let inline_mid_goal = parse_goal_horizon_opt args "mid_goal" in
    let inline_long_goal = parse_goal_horizon_opt args "long_goal" in
    let inline_instructions = get_string_opt args "instructions" in
    let turn_instructions = get_string_opt args "turn_instructions" in
    let no_skill_route = get_bool args "no_skill_route" false in
    let no_state_block = get_bool args "no_state_block" false in
    let inline_will = parse_self_model_opt args "will" in
    let inline_needs = parse_self_model_opt args "needs" in
    let inline_desires = parse_self_model_opt args "desires" in
    let inline_drift_enabled_opt = get_bool_opt args "drift_enabled" in
    let inline_drift_min_turn_gap_opt = Safe_ops.json_int_opt "drift_min_turn_gap" args in
    let inline_soul_profile_res = parse_soul_profile_opt args "soul_profile" in
    let new_soul_profile_res = parse_soul_profile_opt args "new_soul_profile" in
    let new_short_goal = parse_goal_horizon_opt args "new_short_goal" in
    let new_mid_goal = parse_goal_horizon_opt args "new_mid_goal" in
    let new_long_goal = parse_goal_horizon_opt args "new_long_goal" in
    let new_will = parse_self_model_opt args "new_will" in
    let new_needs = parse_self_model_opt args "new_needs" in
    let new_desires = parse_self_model_opt args "new_desires" in
    let new_drift_enabled_opt = get_bool_opt args "new_drift_enabled" in
    let new_drift_min_turn_gap_opt = Safe_ops.json_int_opt "new_drift_min_turn_gap" args in
    let inline_models = get_string_list args "models" in
    let require_existing = get_bool args "require_existing" false in
    let timeout_sec_opt =
      Safe_ops.json_float_opt "timeout_sec" args
      |> Option.map (fun v ->
             let sec = int_of_float (Float.ceil v) in
             max 5 (min (Keeper_config.keeper_msg_timeout_max_sec ()) sec))
    in
    match inline_soul_profile_res, new_soul_profile_res with
    | Error e, _ | _, Error e -> (false, "❌ " ^ e)
    | Ok inline_soul_profile, Ok new_soul_profile ->
    match ensure_keeper_exists
      ~ctx ~name ~require_existing ~profile_defaults
      ~inline_goal ~inline_short_goal ~inline_mid_goal ~inline_long_goal
      ~inline_instructions ~inline_will ~inline_needs ~inline_desires
      ~inline_drift_enabled_opt ~inline_drift_min_turn_gap_opt
      ~inline_soul_profile ~inline_models
    with
    | Error e -> (false, "❌ " ^ e)
    | Ok meta0 ->
      let meta =
        apply_settings_update
          ~args ~meta0 ~new_short_goal ~new_mid_goal ~new_long_goal
          ~new_soul_profile ~new_will ~new_needs ~new_desires
          ~new_drift_enabled_opt ~new_drift_min_turn_gap_opt
          ~config:ctx.config
      in
      start_keepalive ctx meta;
      match maybe_handle_auto_team_session ctx meta message with
      | Error err -> (false, "❌ " ^ err)
      | Ok (Some result, _) -> result
      | Ok (None, meta) ->
      (* === Harness: trajectory accumulator + eval gate config === *)
      let masc_root = Filename.concat ctx.config.base_path ".masc" in
      let trajectory_acc =
        Trajectory.create_accumulator
          ~masc_root
          ~keeper_name:meta.name
          ~trace_id:meta.trace_id
          ~generation:meta.generation
      in
      let gate_config = Eval_gate.default_config in
      let effective_models =
        effective_model_labels_for_turn meta ~inline_models
      in
      let effective_models =
        if
          (meta.trigger_mode
           |> Keeper_contract.trigger_mode_of_string
           |> Keeper_contract.trigger_mode_is_explicit_only)
          || keeper_policy_mode_is_learned meta
        then
          effective_models
        else maybe_append_keeper_fallback_models effective_models
      in
      (match model_specs_of_strings effective_models with
       | Error e -> (false, "❌ " ^ e)
       | Ok specs ->
         (match ensure_api_keys specs with
          | Error e -> (false, "❌ " ^ e)
          | Ok () ->
            let primary = match specs with m0 :: _ -> m0 | [] -> Llm_client.default_local_model_spec () in
            let base_dir = session_base_dir ctx.config in
            mkdir_p base_dir;
            let (session, ctx_opt) = load_context_from_checkpoint
              ~trace_id:meta.trace_id ~primary_model_max_tokens:primary.max_context ~base_dir in
            let base_ctx =
              match ctx_opt with
              | Some c -> c
              | None ->
                Context_manager.create
                  ~system_prompt:(
                    build_keeper_system_prompt
                      ~goal:meta.goal
                      ~short_goal:meta.short_goal
                      ~mid_goal:meta.mid_goal
                      ~long_goal:meta.long_goal
                      ~soul_profile:meta.soul_profile
                      ~will:meta.will
                      ~needs:meta.needs
                      ~desires:meta.desires
                      ~instructions:meta.instructions)
                  ~max_tokens:primary.max_context
            in
	            let ctx_work =
	              (* Always re-apply the current keeper prompt so goal/instructions updates
	                 actually take effect even when restoring an old checkpoint. *)
	              Context_manager.set_system_prompt base_ctx
                ~system_prompt:(
                  build_keeper_system_prompt
                    ~goal:meta.goal
                    ~short_goal:meta.short_goal
                    ~mid_goal:meta.mid_goal
                    ~long_goal:meta.long_goal
                    ~soul_profile:meta.soul_profile
                    ~will:meta.will
                    ~needs:meta.needs
	                    ~desires:meta.desires
	                    ~instructions:meta.instructions)
            in
            let policy_mode_learned = keeper_policy_mode_is_learned meta in
            let effective_no_skill_route = no_skill_route || policy_mode_learned in
            let fallback_skill_route =
              if policy_mode_learned then
                {
                  primary_skill = "policy";
                  secondary_skills = [];
                  reason = "learned_offline_v1";
                }
              else
                route_keeper_skill ~soul_profile:meta.soul_profile ~message
            in
            let skill_selection_mode =
              if policy_mode_learned then SkillSelectHeuristic
              else keeper_skill_selection_mode ()
            in
            let continuity_snapshot = latest_state_snapshot_from_messages ctx_work.messages in
            let continuity_summary =
              match continuity_snapshot with
              | Some s -> keeper_state_snapshot_to_summary_text s
              | None -> (
                  let trimmed = String.trim meta.continuity_summary in
                  if trimmed = "" then "No continuity snapshot available." else trimmed)
            in
            let base_turn_system_prompt =
              if effective_no_skill_route then
                ctx_work.system_prompt
              else
                match skill_selection_mode with
                | SkillSelectHeuristic ->
                    skill_route_system_prompt_heuristic
                      ~base_system_prompt:ctx_work.system_prompt
                      ~route:fallback_skill_route
                | SkillSelectAgent ->
                    skill_route_system_prompt_agent
                      ~base_system_prompt:ctx_work.system_prompt
                      ~fallback_route:fallback_skill_route
                      ~soul_profile:meta.soul_profile
            in
            let turn_system_prompt =
              append_continuity_context_prompt
                ~base_prompt:base_turn_system_prompt
                continuity_snapshot
                ~continuity_summary
            in
            let turn_system_prompt =
              let policy_guards = [
                (effective_no_skill_route,
                 "Output guard: NEVER output lines starting with SKILL: or SKILL_REASON:.");
                (no_state_block,
                 "Output guard: NEVER output [STATE] or [/STATE] blocks in this turn.");
              ] in
              let policy_lines =
                List.filter_map
                  (fun (active, line) -> if active then Some line else None)
                  policy_guards
              in
              match policy_lines with
              | [] -> turn_system_prompt
              | _ ->
                  Printf.sprintf "%s\n\n%s"
                    turn_system_prompt
                    (String.concat "\n" policy_lines)
            in
            let turn_system_prompt =
              match turn_instructions with
              | None -> turn_system_prompt
              | Some ti ->
                  Printf.sprintf "%s\n\n--- Turn-specific instructions ---\n%s"
                    turn_system_prompt ti
            in
	            let user_msg = Llm_client.user_msg message in
	            let ctx_work = Context_manager.append ctx_work user_msg in
	            Context_manager.persist_message session user_msg;
            let turn_max_tokens = keeper_turn_max_tokens () in
            let followup_max_tokens = keeper_followup_max_tokens turn_max_tokens in
            let correction_max_tokens = keeper_correction_max_tokens turn_max_tokens in
            let postpass_budget_ms = keeper_msg_postpass_budget_ms () in
            let turn_started_ts = Time_compat.now () in
            let postpass_elapsed_ms () =
              int_of_float
                (max 0.0 ((Time_compat.now () -. turn_started_ts) *. 1000.0))
            in
            let postpass_remaining_ms () =
              if postpass_budget_ms <= 0 then max_int
              else max 0 (postpass_budget_ms - postpass_elapsed_ms ())
            in
            let has_postpass_budget () =
              postpass_budget_ms <= 0 || postpass_remaining_ms () > 0
            in

            (* Single-turn LLM call with cascade *)
            let requests =
	              List.map (fun (model : Llm_client.model_spec) ->
	                let msgs =
	                  (Llm_client.system_msg turn_system_prompt) :: ctx_work.messages
	                in
	                ({
                  Llm_client.model;
                  messages = msgs;
                  temperature = 0.7;
                  max_tokens = turn_max_tokens;
                  tools = keeper_allowed_llm_tools meta;
                  response_format = `Text;
                } : Llm_client.completion_request)
              ) specs
            in
            let run_cascade requests =
              match timeout_sec_opt with
              | Some timeout_sec ->
                  Llm_client.cascade ~timeout_sec requests
              | None -> Llm_client.cascade requests
            in
            let recall_candidates = recent_user_messages base_ctx.messages ~max_n:32 in
            match run_cascade requests with
            | Error e ->
              (try ignore (Trajectory.finalize trajectory_acc (Trajectory.Failed e))
               with exn -> log_keeper_exn ~label:"trajectory finalize (error path) failed" exn);
              (false, Printf.sprintf "❌ LLM failed: %s" e)
            | Ok resp0 ->
              let used_model0 =
                model_spec_for_used specs resp0.model_used
                |> Option.value ~default:primary
              in
              let cost0 = cost_usd_of_usage resp0.usage used_model0 in
              (* Multi-round tool calling loop: up to 3 rounds *)
              let max_tool_rounds = 3 in
              let _trunc s n = if String.length s > n then String.sub s 0 n ^ "..." else s in
              let execute_tool_calls tcs =
                List.map (fun (tc : Llm_client.tool_call) ->
                  Printf.eprintf "[TRPG-TRACE] Executing tool: %s args: %s\n%!"
                    tc.call_name (_trunc tc.call_arguments 200);
                  let (decision, result_opt, eval_opt, duration_ms) =
                    Eval_gate.guarded_execute
                      ~config:gate_config
                      ~accumulated_cost:trajectory_acc.Trajectory.total_cost
                      ~trajectory_acc:(Some trajectory_acc)
                      ~tool_name:tc.call_name
                      ~args_json:tc.call_arguments
                      ~execute:(fun () ->
                        execute_keeper_tool_call ~config:ctx.config ~meta ~ctx_work tc)
                  in
                  let output = match decision with
                    | Trajectory.Reject reason ->
                        Printf.eprintf "[HARNESS] Tool %s GATED: %s\n%!" tc.call_name reason;
                        Yojson.Safe.to_string (`Assoc [
                          ("error", `String (Printf.sprintf "gated: %s" reason));
                          ("tool", `String tc.call_name);
                        ])
                    | Trajectory.Pass ->
                        let r = Option.value ~default:"" result_opt in
                        Printf.eprintf "[TRPG-TRACE] Tool %s OK: %s\n%!" tc.call_name (_trunc r 200);
                        (* Log post-eval warnings *)
                        (match eval_opt with
                         | Some eval when eval.Eval_gate.should_warn ->
                             Printf.eprintf "[HARNESS] Warning for %s: %s\n%!" tc.call_name
                               (Option.value ~default:"" eval.Eval_gate.warning)
                         | _ -> ());
                        r
                  in
                  (* Record trajectory entry *)
                  let entry : Trajectory.tool_call_entry = {
                    ts = Time_compat.now ();
                    ts_iso = Types.now_iso ();
                    turn = trajectory_acc.Trajectory.turn;
                    round = 0;  (* updated by tool_loop caller *)
                    tool_name = tc.call_name;
                    args_json = tc.call_arguments;
                    gate_decision = decision;
                    result = (match decision with
                      | Trajectory.Pass -> result_opt
                      | Trajectory.Reject _ -> Some output);
                    duration_ms;
                    error = (match eval_opt with
                      | Some e -> e.Eval_gate.error_message
                      | None -> None);
                    cost_usd = (match eval_opt with
                      | Some e -> e.Eval_gate.cost_usd
                      | None -> 0.0);
                  } in
                  Trajectory.record_entry trajectory_acc entry;
                  (tc, output)
                ) tcs
              in
              let rec tool_loop ~round ~acc_usage ~acc_latency ~acc_cost
                  ~acc_tools_used ~last_resp =
                if last_resp.Llm_client.tool_calls = [] || round > max_tool_rounds then
                  (* Terminal: no more tool calls or hit round limit *)
                  let content =
                    let c = String.trim last_resp.Llm_client.content in
                    if c = "" && acc_tools_used <> [] then
                      Printf.sprintf "(tools executed: %s)"
                        (String.concat ", " acc_tools_used)
                    else last_resp.Llm_client.content
                  in
                  ( content, acc_usage, last_resp.Llm_client.model_used,
                    acc_latency, acc_cost, acc_tools_used )
                else begin
                  Printf.eprintf "[TRPG-TRACE] Tool round %d/%d: %d tool calls\n%!"
                    round max_tool_rounds
                    (List.length last_resp.Llm_client.tool_calls);
                  let round_tools =
                    List.map (fun (tc : Llm_client.tool_call) -> tc.call_name)
                      last_resp.Llm_client.tool_calls
                  in
                  let all_tools_so_far = acc_tools_used @ round_tools in
                  let tool_outputs = execute_tool_calls last_resp.Llm_client.tool_calls in
                  let followup_prompt =
                    keeper_tool_followup_prompt
                      ~user_message:message
                      ~draft_reply:last_resp.Llm_client.content
                      ~tool_outputs
                      ~already_executed:all_tools_so_far
                  in
                  (* Once a write tool has been executed, strip tools from the
                     next request to force the model to produce a text answer. *)
                  let write_done =
                    List.exists
                      (fun n ->
                         List.mem n
                           [
                             "keeper_board_post";
                             "keeper_board_comment";
                             "keeper_fs_edit";
                             "keeper_edit";
                           ])
                      all_tools_so_far
                  in
                  let next_tools =
                    keeper_allowed_llm_tools ~write_done meta
                  in
                  let followup_requests =
                    List.map (fun (model : Llm_client.model_spec) ->
                      ({
                        Llm_client.model;
                        messages = [
                          Llm_client.system_msg (keeper_tool_loop_system_prompt
                            ~character_context:ctx_work.system_prompt);
                          Llm_client.user_msg followup_prompt;
                        ];
                        temperature = 0.3;
                        max_tokens = followup_max_tokens;
                        tools = next_tools;
                        response_format = `Text;
                      } : Llm_client.completion_request)
                    ) specs
                  in
                  match run_cascade followup_requests with
                  | Error _ ->
                    (* Cascade failed — return what we have *)
                    ( last_resp.Llm_client.content, acc_usage,
                      last_resp.Llm_client.model_used, acc_latency,
                      acc_cost, acc_tools_used @ round_tools )
                  | Ok resp_next ->
                    Printf.eprintf "[TRPG-TRACE] Follow-up round %d resp: tool_calls=%d content_len=%d model=%s\n%!"
                      round
                      (List.length resp_next.Llm_client.tool_calls)
                      (String.length resp_next.Llm_client.content)
                      resp_next.Llm_client.model_used;
                    let used_model_next =
                      model_spec_for_used specs resp_next.model_used
                      |> Option.value ~default:primary
                    in
                    let cost_next = cost_usd_of_usage resp_next.usage used_model_next in
                    tool_loop
                      ~round:(round + 1)
                      ~acc_usage:(merge_usage acc_usage resp_next.usage)
                      ~acc_latency:(acc_latency + resp_next.latency_ms)
                      ~acc_cost:(acc_cost +. cost_next)
                      ~acc_tools_used:(acc_tools_used @ round_tools)
                      ~last_resp:resp_next
                end
              in
              (* Harness: increment turn counter before tool execution *)
              Trajectory.increment_turn trajectory_acc;
              let (base_content, base_usage, base_model_used, base_latency_ms,
                   base_cost_usd, tools_used) =
                tool_loop ~round:1 ~acc_usage:resp0.usage
                  ~acc_latency:resp0.latency_ms ~acc_cost:cost0
                  ~acc_tools_used:[] ~last_resp:resp0
              in
              let eval0 =
                evaluate_memory_recall
                  ~user_message:message
                  ~assistant_reply:base_content
                  ~candidates:recall_candidates
              in
              let correction_needed =
                eval0.performed && not eval0.passed && eval0.candidate_count > 0
              in
              let (content_after_correction, usage_after_correction,
                   model_after_correction, latency_after_correction,
                   eval_after_correction, correction_applied_after_correction,
                   correction_success_after_correction,
                   correction_skipped_budget_after_correction,
                   cost_after_correction, tools_used) =
                if not correction_needed then
                  ( base_content, base_usage, base_model_used, base_latency_ms,
                    eval0, false, false, false, base_cost_usd, tools_used )
                else if not (has_postpass_budget ()) then
                  ( base_content, base_usage, base_model_used, base_latency_ms,
                    eval0, false, false, true, base_cost_usd, tools_used )
                else
                  let correction_prompt =
                    memory_correction_prompt
                      ~user_message:message
                      ~first_reply:base_content
                      ~candidate_user_msgs:recall_candidates
                      ~expected_topic:eval0.expected_topic
                  in
                  let correction_requests =
                    List.map (fun (model : Llm_client.model_spec) ->
	                      ({
	                        Llm_client.model;
	                        messages = [
	                          Llm_client.system_msg turn_system_prompt;
	                          Llm_client.user_msg correction_prompt;
	                        ];
                        temperature = 0.2;
                        max_tokens = correction_max_tokens;
                        tools = [];
                        response_format = `Text;
                      } : Llm_client.completion_request)
                    ) specs
                  in
                  match run_cascade correction_requests with
                  | Error _ ->
                    ( base_content, base_usage, base_model_used, base_latency_ms,
                      eval0, true, false, false, base_cost_usd, tools_used )
                  | Ok corr ->
                    let used_model1 =
                      model_spec_for_used specs corr.model_used
                      |> Option.value ~default:primary
                    in
                    let cost1 = cost_usd_of_usage corr.usage used_model1 in
                    let eval1 =
                      evaluate_memory_recall
                        ~user_message:message
                        ~assistant_reply:corr.content
                        ~candidates:recall_candidates
                    in
                    let evalf = { eval1 with initial_score = eval0.final_score } in
                    let merged_usage = merge_usage base_usage corr.usage in
                    ( corr.content, merged_usage, corr.model_used,
                      base_latency_ms + corr.latency_ms,
                      evalf, true, evalf.passed, false, base_cost_usd +. cost1,
                      tools_used )
              in
              let prompt_fallback_needed =
                eval_after_correction.performed
                && not eval_after_correction.passed
                && eval_after_correction.candidate_count > 0
              in
              let (content_after_prompt_fallback, usage_after_prompt_fallback,
                   model_after_prompt_fallback, latency_after_prompt_fallback,
                   eval_after_prompt_fallback, prompt_fallback_applied,
                   prompt_fallback_success, prompt_fallback_skipped_budget,
                   cost_after_prompt_fallback) =
                if not prompt_fallback_needed then
                  ( content_after_correction, usage_after_correction,
                    model_after_correction, latency_after_correction,
                    eval_after_correction, false, false, false, cost_after_correction )
                else if not (has_postpass_budget ()) then
                  ( content_after_correction, usage_after_correction,
                    model_after_correction, latency_after_correction,
                    eval_after_correction, false, false, true, cost_after_correction )
                else
                  let forced_prompt =
                    memory_forced_grounding_prompt
                      ~user_message:message
                      ~first_reply:content_after_correction
                      ~candidate_user_msgs:recall_candidates
                      ~expected_topic:eval_after_correction.expected_topic
                  in
                  let forced_requests =
                    List.map (fun (model : Llm_client.model_spec) ->
	                      ({
	                        Llm_client.model;
	                        messages = [
	                          Llm_client.system_msg turn_system_prompt;
	                          Llm_client.user_msg forced_prompt;
	                        ];
                        temperature = 0.0;
                        max_tokens = correction_max_tokens;
                        tools = [];
                        response_format = `Text;
                      } : Llm_client.completion_request)
                    ) specs
                  in
                  match run_cascade forced_requests with
                  | Error _ ->
                      ( content_after_correction, usage_after_correction,
                        model_after_correction, latency_after_correction,
                        eval_after_correction, true, false, false, cost_after_correction )
                  | Ok forced ->
                      let used_model2 =
                        model_spec_for_used specs forced.model_used
                        |> Option.value ~default:primary
                      in
                      let cost2 = cost_usd_of_usage forced.usage used_model2 in
                      let merged_usage = merge_usage usage_after_correction forced.usage in
                      let merged_latency = latency_after_correction + forced.latency_ms in
                      let grounded_content =
                        let c = String.trim forced.content in
                        if c = "" then content_after_correction else forced.content
                      in
                      let eval2 =
                        evaluate_memory_recall
                          ~user_message:message
                          ~assistant_reply:grounded_content
                          ~candidates:recall_candidates
                      in
                      let eval2 = { eval2 with initial_score = eval_after_correction.final_score } in
                      if eval2.passed then
                        ( grounded_content, merged_usage, forced.model_used,
                          merged_latency, eval2, true, true, false,
                          cost_after_correction +. cost2 )
                      else
                        ( content_after_correction, merged_usage, model_after_correction,
                          merged_latency, eval_after_correction, true, false, false,
                          cost_after_correction +. cost2 )
              in
              let (final_content, final_usage, final_model_used, final_latency_ms,
                   final_eval, correction_applied, correction_success,
                   recall_fallback_applied, total_cost_usd_turn) =
                match
                  deterministic_recall_fallback
                    ~meta
                    ~user_message:message
                    ~eval:eval_after_prompt_fallback
                    ~candidates:recall_candidates
                with
                | None ->
                    ( content_after_prompt_fallback, usage_after_prompt_fallback,
                      model_after_prompt_fallback, latency_after_prompt_fallback,
                      eval_after_prompt_fallback, correction_applied_after_correction,
                      (correction_success_after_correction || prompt_fallback_success), false,
                      cost_after_prompt_fallback )
                | Some (fallback_content, fallback_eval) ->
                    ( fallback_content, usage_after_prompt_fallback,
                      model_after_prompt_fallback, latency_after_prompt_fallback,
                      fallback_eval, true, fallback_eval.passed, true,
                      cost_after_prompt_fallback )
              in
              let postpass_budget_remaining_ms =
                if postpass_budget_ms <= 0 then -1 else postpass_remaining_ms ()
              in
              let memory_check_json =
                memory_eval_to_json final_eval
                  ~correction_applied
                  ~correction_success
                  ~correction_skipped_budget:correction_skipped_budget_after_correction
                  ~prompt_fallback_applied
                  ~prompt_fallback_success
                  ~prompt_fallback_skipped_budget
                  ~postpass_budget_ms
                  ~postpass_budget_remaining_ms
                  ~recall_fallback_applied
              in
	              let work_kind = work_kind_of_eval final_eval in
	              let tool_call_count = List.length tools_used in
	              let safe_reply_raw =
	                let trimmed = String.trim final_content in
	                if trimmed <> "" then final_content
	                else
	                  Printf.sprintf
	                    "Request processed. (generation=%d, trace=%s, model=%s)"
	                    meta.generation meta.trace_id final_model_used
	              in
		              let skill_route_resolution =
                        resolved_keeper_skill_route
                          ~selection_mode:skill_selection_mode
                          ~fallback_route:fallback_skill_route
                          ~reply_raw:safe_reply_raw
		              in
                      let effective_skill_route = skill_route_resolution.route in
			              let safe_reply_with_skill =
			                if effective_no_skill_route then
                            strip_skill_route_lines safe_reply_raw
                          else
			                    ensure_skill_route_header
			                      ~route:effective_skill_route
			                      safe_reply_raw
			              in
                          let raw_reply = safe_reply_with_skill in
                          let safe_reply =
                            let fallback =
                              if no_state_block then Some "State updated." else None
                            in
                            user_visible_reply_text ?fallback raw_reply
                          in
              let repetition_risk =
                repetition_risk_score
                  ~messages:ctx_work.messages
                  ~candidate_reply:(Some safe_reply)
              in
	              let goal_alignment =
	                goal_alignment_score
	                  ~meta
	                  ~user_message:(Some message)
	                  ~assistant_reply:(Some safe_reply)
	              in
              let response_alignment = jaccard_similarity message safe_reply in

		              let assistant_msg = Llm_client.assistant_msg safe_reply in
	              let ctx_work = Context_manager.append ctx_work assistant_msg in
              Context_manager.persist_message session assistant_msg;
              let now_ts = Time_compat.now () in
              let continuity_summary_from_reply =
                match parse_state_snapshot_from_reply raw_reply with
                | None -> meta.continuity_summary
                | Some snapshot -> keeper_state_snapshot_to_summary_text snapshot
              in
              let continuity_summary_from_reply = String.trim continuity_summary_from_reply in
              let last_continuity_update_ts =
                if
                  continuity_summary_from_reply <> ""
                  && String.trim meta.continuity_summary <> continuity_summary_from_reply
                then
                  now_ts
                else
                  meta.last_continuity_update_ts
              in
              let meta_for_compaction =
                {
                  meta with
                  continuity_summary = continuity_summary_from_reply;
                  last_continuity_update_ts;
                }
              in

              (* Compact opportunistically to control growth. *)
              let before_compact_tokens = ctx_work.token_count in
              let (ctx_work, compaction_trigger, compaction_decision) =
                compact_if_needed ~meta:meta_for_compaction ~now_ts ctx_work
              in
              let after_compact_tokens = ctx_work.token_count in
              let compacted = after_compact_tokens < before_compact_tokens in

              let ctx_ratio = Context_manager.context_ratio ctx_work in
              let meta_turn = { meta with
                updated_at = now_iso ();
                total_turns = meta.total_turns + 1;
                total_input_tokens = meta.total_input_tokens + final_usage.input_tokens;
                continuity_summary = continuity_summary_from_reply;
                last_continuity_update_ts;
                total_output_tokens = meta.total_output_tokens + final_usage.output_tokens;
                total_tokens = meta.total_tokens + final_usage.total_tokens;
                total_cost_usd = meta.total_cost_usd +. total_cost_usd_turn;
                last_turn_ts = now_ts;
                last_model_used = final_model_used;
                last_input_tokens = final_usage.input_tokens;
                last_output_tokens = final_usage.output_tokens;
                last_total_tokens = final_usage.total_tokens;
                last_latency_ms = final_latency_ms;
                compaction_count = meta.compaction_count + (if compacted then 1 else 0);
                last_compaction_ts = (if compacted then now_ts else meta.last_compaction_ts);
                last_compaction_before_tokens =
                  (if compacted then before_compact_tokens else meta.last_compaction_before_tokens);
                last_compaction_after_tokens =
                  (if compacted then after_compact_tokens else meta.last_compaction_after_tokens);
                last_compaction_check_ts = now_ts;
                last_compaction_decision = compaction_decision;
              } in
              let (meta_turn, drift_applied, drift_reason) =
                if policy_mode_learned then
                  (meta_turn, false, None)
                else
                  apply_self_model_drift
                    ~meta:meta_turn
                    ~user_message:message
                    ~work_kind
              in

              let (memory_notes_added, memory_note_kinds) =
                append_memory_notes_from_reply
                  ctx.config
                  meta_turn
                  ~turn:meta_turn.total_turns
                  ~reply:raw_reply
              in
              let memory_top_kind =
                match memory_note_kinds with
                | kind :: _ -> Some kind
                | [] -> None
              in
              let memory_compaction =
                compact_memory_bank_if_needed
                  ctx.config
                  meta_turn
              in

              (try ignore (save_checkpoint session ctx_work ~generation:meta_turn.generation)
               with exn -> log_keeper_exn ~label:"save_checkpoint (turn) failed" exn);

		              let handoff_eval =
                let auto_rules =
                  if policy_mode_learned then
                    learned_policy_auto_rules
                      ~meta:meta_turn
                      ~context_ratio:ctx_ratio
                      ~message_count:(List.length ctx_work.messages)
                      ~token_count:ctx_work.token_count
                      ~repetition_risk
                      ~goal_alignment
                      ~response_alignment
                  else
                    evaluate_keeper_auto_rules
                      ~meta:meta_turn
                      ~context_ratio:ctx_ratio
                      ~message_count:(List.length ctx_work.messages)
                      ~token_count:ctx_work.token_count
                      ~repetition_risk
                      ~goal_alignment
                      ~response_alignment
                in
                (if auto_rules.guardrail_stop then
                   (try
                      ignore
                        (Room.broadcast
                           ctx.config
                           ~from_agent:meta_turn.agent_name
                           ~content:
                             (Printf.sprintf
                                "🛑 keeper guardrail_stop: %s"
                                (Option.value
                                   ~default:"policy threshold exceeded"
                                   auto_rules.guardrail_reason)))
                    with exn ->
                      log_keeper_exn ~label:"room broadcast (guardrail_stop) failed" exn);
                   (* SSE: keeper_guardrail — dashboard real-time alert *)
                   (try Sse.broadcast (`Assoc [
                     ("type", `String "keeper_guardrail");
                     ("name", `String meta_turn.name);
                     ("reason", `String (Option.value ~default:"policy threshold exceeded"
                        auto_rules.guardrail_reason));
                   ]) with exn ->
                     log_keeper_exn ~label:"SSE keeper_guardrail broadcast failed" exn));
                let do_handoff =
                  auto_rules.handoff &&
		                (now_ts -. meta_turn.last_handoff_ts >= float_of_int meta_turn.handoff_cooldown_sec)
		              in
                (do_handoff, auto_rules)
	              in
	              let (do_handoff, auto_rules) = handoff_eval in

              let interesting_alert =
                if policy_mode_learned then
                  {
                    empty_interesting_alert_result with
                    enabled = false;
                    threshold = Env_config.KeeperAlert.min_score;
                    reasons = [ "disabled_by_policy_mode" ];
                  }
                else
                  try
                    maybe_emit_interesting_alert
                      ctx
                      ~meta:meta_turn
                      ~message
                      ~reply:safe_reply
                      ~work_kind
                      ~tool_call_count
                      ~context_ratio:ctx_ratio
                      ~goal_alignment
                      ~response_alignment
                      ~auto_rules
                  with exn ->
                    {
                      empty_interesting_alert_result with
                      enabled = Env_config.KeeperAlert.enabled;
                      threshold = Env_config.KeeperAlert.min_score;
                      reasons = [ "fanout_exception" ];
                      keywords = [];
                      channels = [
                        {
                          channel = "fanout";
                          attempted = true;
                          success = false;
                          attempts = 1;
                          detail = Some (short_preview ~max_len:220 (Printexc.to_string exn));
                        };
                      ];
                    }
              in

              let turn_env : turn_env = {
                meta_turn;
                safe_reply;
                final_usage;
                final_model_used;
                final_latency_ms;
                total_cost_usd_turn;
                ctx_ratio;
                ctx_work;
                compacted;
                before_compact_tokens;
                after_compact_tokens;
                compaction_trigger;
                compaction_decision;
                work_kind;
                tool_call_count;
                tools_used;
                effective_skill_route;
                skill_route_resolution;
                memory_check_json;
                auto_rules;
                drift_applied;
                drift_reason;
                repetition_risk;
                goal_alignment;
                response_alignment;
                memory_notes_added;
                memory_note_kinds;
                memory_top_kind;
                memory_compaction;
                interesting_alert;
              } in
              build_keeper_response ctx ~session ~now_ts ~specs ~primary ~base_dir
                ~trajectory_acc ~gate_config ~do_handoff turn_env))

let handle_keeper_model_set ctx args : tool_result =
  let name = get_string args "name" "" in
  let model = get_string args "model" "" |> String.trim in
  let allowed_models_arg = get_string_list args "allowed_models" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else if model = "" then
    (false, "❌ model is required")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some meta) -> (
        match Llm_client.model_spec_of_string model with
        | Error e -> (false, "❌ " ^ e)
        | Ok spec ->
            let runtime_ok =
              match spec.provider with
              | Llm_client.Llama -> (
                  match Tool_llama.fetch_models () with
                  | Ok (_, models) -> List.mem spec.model_id models
                  | Error _ -> false)
              | _ -> true
            in
            if spec.provider = Llm_client.Llama && not runtime_ok then
              (false, Printf.sprintf "❌ model not present in llama inventory: %s" spec.model_id)
            else
              let allowed_models =
                dedupe_keep_order
                  (allowed_models_arg @ [ model ] @ meta.allowed_models @ meta.models)
              in
              let updated =
                {
                  meta with
                  active_model = model;
                  allowed_models;
                  models = dedupe_keep_order (model :: meta.models);
                  updated_at = now_iso ();
                }
              in
              match write_meta ctx.config updated with
              | Error e -> (false, "❌ " ^ e)
              | Ok () ->
                  stop_keepalive updated.name;
                  start_keepalive ctx updated;
                  ( true,
                    Yojson.Safe.pretty_to_string
                      (`Assoc
                        [
                          ("name", `String updated.name);
                          ("active_model", `String updated.active_model);
                          ("allowed_models",
                            `List
                              (List.map (fun item -> `String item) updated.allowed_models));
                  ("room_scope", `String updated.room_scope);
                  ("trigger_mode", `String updated.trigger_mode);
                    ]) ))


let handle_keeper_down ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    let remove_meta = get_bool args "remove_meta" false in
    let remove_session = get_bool args "remove_session" false in
    stop_keepalive name;
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (true, Printf.sprintf "keeper already absent: %s" name)
    | Ok (Some m) ->
      let stop_linked_session session_id =
        match
          Team_session_engine_eio.stop_session ~config:ctx.config ~session_id
            ~reason:"keeper_down" ~generate_report:false
        with
        | Ok _ -> ()
        | Error err ->
            Printf.eprintf "[keeper] linked team session stop failed: %s\n%!"
              err
      in
      Option.iter stop_linked_session m.active_team_session_id;
      (if remove_meta then
         Safe_ops.remove_file_logged ~context:"keeper_down"
           (keeper_meta_path ctx.config name)
       else
         let retained =
           {
             m with
             active_team_session_id = None;
             last_team_session_started_at = "";
             updated_at = now_iso ();
           }
         in
         write_meta_logged ctx.config retained);
      if remove_session then (
        let rec rm_rf path =
          if Sys.file_exists path then begin
            if Sys.is_directory path then begin
              Sys.readdir path |> Array.iter (fun entry ->
                rm_rf (Filename.concat path entry)
              );
              Unix.rmdir path
            end else
              Sys.remove path
          end
        in
        if validate_name m.trace_id then (
          let dir = Filename.concat (session_base_dir ctx.config) m.trace_id in
          try rm_rf dir with exn ->
            Printf.eprintf "[keeper] session dir cleanup failed: %s\n%!"
              (Printexc.to_string exn)));
      let json = `Assoc [
        ("name", `String name);
        ("stopped", `Bool true);
        ("remove_meta", `Bool remove_meta);
        ("remove_session", `Bool remove_session);
      ] in
      (true, Yojson.Safe.pretty_to_string json)
