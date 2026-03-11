(** Tool_keeper facade.

    MCP entrypoints stay stable while keeper internals live in dedicated
    keeper modules. Tool_keeper now owns only the public dispatch surface
    and handler composition.
*)

[@@@warning "-32"]

open Tool_args

include Keeper_execution

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
    let room_scope_opt = get_string_opt args "room_scope" in
    let scope_kind_opt = get_string_opt args "scope_kind" in
    let trigger_mode_opt = get_string_opt args "trigger_mode" in
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
        dedupe_keep_order
          (allowed_models_in
           @ profile_defaults.allowed_models
           @ requested_models)
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
                 ~default:(if trigger_mode = "explicit_only" then false else default_proactive_enabled)
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
              with exn -> Printf.eprintf "[keeper] save_checkpoint (init) failed: %s\n%!" (Printexc.to_string exn));
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
               policy_mode = "heuristic";
               policy_action_budget = "conversation";
               policy_reward_model_path = "";
               scope_kind;
               room_scope;
               trigger_mode;
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
                 ("presence_keepalive", `Bool meta.presence_keepalive);
                 ("presence_keepalive_sec", `Int meta.presence_keepalive_sec);
                 ("proactive_enabled", `Bool meta.proactive_enabled);
                 ("proactive_idle_sec", `Int meta.proactive_idle_sec);
                 ("proactive_cooldown_sec", `Int meta.proactive_cooldown_sec);
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
        dedupe_keep_order
          (allowed_models_in
           @ old.allowed_models
           @ profile_defaults.allowed_models
           @ models)
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
        policy_mode = canonical_policy_mode old.policy_mode;
        policy_action_budget = canonical_policy_action_budget old.policy_action_budget;
        policy_reward_model_path = old.policy_reward_model_path;
        scope_kind;
        room_scope;
        trigger_mode;
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
                   (if trigger_mode = "explicit_only" then false else old.proactive_enabled)
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
        updated_at = now_iso ();
      } in
      (match write_meta ctx.config updated with
       | Error e -> (false, "❌ " ^ e)
       | Ok () ->
         stop_keepalive updated.name;
         start_keepalive ctx updated;
         (true, Yojson.Safe.pretty_to_string (meta_to_json updated)))

let handle_keeper_status ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some m) ->
      let tail_turns = max 0 (get_int args "tail_turns" 3) in
      let tail_messages = max 0 (get_int args "tail_messages" 5) in
      let tail_compactions = max 0 (get_int args "tail_compactions" 10) in
      let tail_bytes = max 1_000 (get_int args "tail_bytes" 60_000) in
      let fast = get_bool args "fast" (keeper_status_fast_default ()) in
      let include_context = get_bool args "include_context" (not fast) in
      let include_metrics_overview =
        get_bool args "include_metrics_overview" (not fast)
      in
      let include_memory_bank = get_bool args "include_memory_bank" (not fast) in
      let include_history_tail = get_bool args "include_history_tail" (not fast) in
      let include_compaction_history =
        get_bool args "include_compaction_history" (not fast)
      in
      let models = m.models in
      (match model_specs_of_strings models with
       | Error e -> (false, "❌ " ^ e)
       | Ok specs ->
         let primary = match specs with m0 :: _ -> m0 | [] -> Llm_client.default_local_model_spec () in
         let base_dir = session_base_dir ctx.config in
         let ctx_opt =
           if include_context then
             let (_session, ctx_opt) =
               load_context_from_checkpoint
                 ~trace_id:m.trace_id
                 ~primary_model_max_tokens:primary.max_context
                 ~base_dir
             in
             ctx_opt
           else
             None
         in
         let ctx_stats =
           if not include_context then
             `Assoc [
               ("skipped", `Bool true);
               ("reason", `String "fast_or_disabled");
               ("has_checkpoint", `Null);
             ]
           else
             match ctx_opt with
             | None -> `Assoc [("has_checkpoint", `Bool false)]
             | Some c ->
               `Assoc [
                 ("has_checkpoint", `Bool true);
                 ("context_ratio", `Float (Context_manager.context_ratio c));
                 ("context_tokens", `Int c.token_count);
                 ("context_max", `Int c.max_tokens);
                 ("message_count", `Int (List.length c.messages));
               ]
         in
         let keepalive_running = keeper_keepalive_running m.name in
         let agent_status = parse_agent_status ctx.config ~agent_name:m.agent_name in
         let now_ts = Time_compat.now () in
         let created_ts =
           Resilience.Time.parse_iso8601_opt m.created_at |> Option.value ~default:0.0
         in
         let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
         let last_turn_ago_s = if m.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.last_turn_ts in
         let last_handoff_ago_s = if m.last_handoff_ts <= 0.0 then 0.0 else now_ts -. m.last_handoff_ts in
         let last_compaction_ago_s = if m.last_compaction_ts <= 0.0 then 0.0 else now_ts -. m.last_compaction_ts in
         let last_proactive_ago_s =
           if m.last_proactive_ts <= 0.0 then 0.0 else now_ts -. m.last_proactive_ts
         in
         let trace_history_count = List.length m.trace_history in
         let active_model = active_model_of_meta m in
         let next_model_hint = next_model_hint_of_meta m in
         let last_compaction_saved_tokens =
           max 0 (m.last_compaction_before_tokens - m.last_compaction_after_tokens)
         in
         let (compact_ratio_gate, compact_message_gate, compact_token_gate) =
           compaction_policy_of_keeper m
         in

         let models_resolved = `List (List.map (fun (s : Llm_client.model_spec) ->
           `Assoc [
             ("provider", `String (Llm_client.string_of_provider s.provider));
             ("model_id", `String s.model_id);
             ("max_context", `Int s.max_context);
             ("api_key_env", match s.api_key_env with None -> `Null | Some k -> `String k);
           ]
         ) specs) in

         let metrics_path = keeper_metrics_path ctx.config m.name in
         let memory_bank_path = keeper_memory_bank_path ctx.config m.name in
         let session_dir = keeper_session_dir ctx.config m.trace_id in
         let history_path = keeper_history_path ctx.config m.trace_id in

         let metrics_tail =
           let lines =
             read_file_tail_lines metrics_path
               ~max_bytes:tail_bytes
               ~max_lines:tail_turns
           in
           `List
             (List.filter_map
                (fun line ->
                  try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None)
                lines)
         in
         let metrics_window_lines =
           if include_metrics_overview then
             read_file_tail_lines metrics_path
               ~max_bytes:tail_bytes
               ~max_lines:(max tail_turns 200)
           else
             []
         in
         let metrics_overview =
           if include_metrics_overview then
             summarize_metrics_lines
               metrics_window_lines
               ~default_generation:m.generation
           else
             empty_metrics_summary
         in
         let last_skill_route =
           if not include_metrics_overview then
             None
           else
             let open Yojson.Safe.Util in
             let rec find_latest = function
               | [] -> None
               | line :: tl ->
                 (try
                    let j = Yojson.Safe.from_string line in
                    match Safe_ops.json_string_opt "skill_primary" j with
                    | Some primary when String.trim primary <> "" ->
                      let secondary =
                        match j |> member "skill_secondary" with
                        | `List xs ->
                          xs
                          |> List.filter_map (fun v ->
                               match v with
                               | `String s when String.trim s <> "" -> Some s
                               | _ -> None)
                        | _ -> []
                      in
                      let reason = Safe_ops.json_string_opt "skill_reason" j in
                      Some
                        (`Assoc
                           [
                             ("primary", `String primary);
                             ( "secondary",
                               `List (List.map (fun s -> `String s) secondary) );
                             ( "reason",
                               match reason with
                               | Some s -> `String s
                               | None -> `Null );
                           ])
                    | _ -> find_latest tl
                  with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> find_latest tl)
             in
             find_latest (List.rev metrics_window_lines)
         in
         let memory_bank_summary =
           if include_memory_bank then
             read_keeper_memory_summary
               ctx.config
               ~name:m.name
               ~max_bytes:tail_bytes
               ~max_lines:(max (tail_turns * 10) 400)
               ~recent_limit:8
           else
             {
               total_notes = 0;
               last_ts_unix = 0.0;
               top_kind = None;
               kind_counts = [];
               recent_notes = [];
             }
         in

         let history_filter_fragments =
           bool_default_true_of_env "MASC_KEEPER_HISTORY_FRAGMENT_FILTER"
         in
         let (history_tail, history_raw_count, history_fragment_count, history_fragment_filtered_count) =
           if not include_history_tail then
             (`List [], 0, 0, 0)
           else
             let lines =
               read_file_tail_lines history_path
                 ~max_bytes:tail_bytes
                 ~max_lines:tail_messages
             in
             let open Yojson.Safe.Util in
             let (items_rev, raw_count, fragment_count, filtered_count) =
               List.fold_left
                 (fun (acc, raw_count, fragment_count, filtered_count) line ->
                   try
                     let j = Yojson.Safe.from_string line in
                     let role =
                       j |> member "role" |> to_string_option
                       |> Option.value ~default:"unknown"
                     in
                     let content =
                       j |> member "content" |> to_string_option
                       |> Option.value ~default:""
                     in
                     let ts_unix =
                       let ts0 = Safe_ops.json_float ~default:0.0 "ts_unix" j in
                       if ts0 > 0.0 then ts0
                       else Safe_ops.json_float ~default:0.0 "timestamp" j
                     in
                     let age_s =
                       if ts_unix > 0.0 then Some (max 0.0 (now_ts -. ts_unix))
                       else None
                     in
                     let role_lc = String.lowercase_ascii role in
                     let entry_kind =
                       match role_lc with
                       | "assistant" -> "self_talk"
                       | "user" -> "input"
                       | "tool" -> "tool_result"
                       | "system" -> "system"
                       | _ -> "other"
                     in
                     let is_fragment =
                       role_lc = "assistant"
                       && looks_fragmentary_history_text content
                     in
                     let should_filter = history_filter_fragments && is_fragment in
                     let preview =
                       if String.length content > 200 then
                         utf8_safe_prefix_bytes content ~max_bytes:200 ^ "..."
                       else content
                     in
                     let item =
                       `Assoc [
                         ("role", `String role);
                         ("kind", `String entry_kind);
                         ("is_fragment", `Bool is_fragment);
                         ("ts_unix", `Float ts_unix);
                         ("age_s", match age_s with Some v -> `Float v | None -> `Null);
                         ("content", `String preview);
                       ]
                     in
                     let acc = if should_filter then acc else item :: acc in
                     let filtered_count =
                       filtered_count + if should_filter then 1 else 0
                     in
                     ( acc,
                       raw_count + 1,
                       fragment_count + (if is_fragment then 1 else 0),
                       filtered_count )
                   with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> (acc, raw_count, fragment_count, filtered_count))
                 ([], 0, 0, 0) lines
             in
             (`List (List.rev items_rev), raw_count, fragment_count, filtered_count)
         in
         let history_items =
           match history_tail with
           | `List xs -> xs
           | _ -> []
         in
         let diagnostic =
           keeper_diagnostic_json
             ~meta:m
             ~agent_status
             ~keepalive_running
             ~history_items
             ~now_ts
         in

         let compaction_history_tail =
           if not include_compaction_history then
             (`List [], 0)
           else
             let lines =
               read_file_tail_lines metrics_path
                 ~max_bytes:tail_bytes
                 ~max_lines:(max 200 (tail_compactions * 20))
             in
             let events_rev =
               List.fold_left
                 (fun acc line ->
                   try
                     let j = Yojson.Safe.from_string line in
                     let compacted = Safe_ops.json_bool ~default:false "compacted" j in
                     let memory_compaction_performed =
                       Safe_ops.json_bool ~default:false "memory_compaction_performed" j
                     in
                     if (not compacted) && (not memory_compaction_performed) then acc
                     else
                       let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
                       let age_s =
                         if ts_unix > 0.0 then Some (max 0.0 (now_ts -. ts_unix)) else None
                       in
                       let before_tokens = Safe_ops.json_int ~default:0 "compaction_before_tokens" j in
                       let after_tokens = Safe_ops.json_int ~default:0 "compaction_after_tokens" j in
                       let saved_tokens = max 0 (before_tokens - after_tokens) in
                       let memory_before_notes =
                         Safe_ops.json_int ~default:0 "memory_compaction_before_notes" j
                       in
                       let memory_after_notes =
                         Safe_ops.json_int ~default:0 "memory_compaction_after_notes" j
                       in
                       let memory_dropped_notes =
                         Safe_ops.json_int ~default:0 "memory_compaction_dropped_notes" j
                       in
                       let memory_invalid_dropped =
                         Safe_ops.json_int ~default:0 "memory_compaction_invalid_dropped" j
                       in
                       let event_kind =
                         if compacted && memory_compaction_performed then "context+memory"
                         else if compacted then "context"
                         else "memory"
                       in
                       let item =
                         `Assoc [
                           ("kind", `String event_kind);
                           ("channel", `String (Safe_ops.json_string ~default:"turn" "channel" j));
                           ("ts_unix", `Float ts_unix);
                           ("age_s", match age_s with Some v -> `Float v | None -> `Null);
                           ("trace_id", `String (Safe_ops.json_string ~default:"" "trace_id" j));
                           ("generation", `Int (Safe_ops.json_int ~default:m.generation "generation" j));
                           ("context_ratio", `Float (Safe_ops.json_float ~default:0.0 "context_ratio" j));
                           ("context_before_tokens", `Int before_tokens);
                           ("context_after_tokens", `Int after_tokens);
                           ("context_saved_tokens", `Int saved_tokens);
                           ( "context_trigger",
                             match Safe_ops.json_string_opt "compaction_trigger" j with
                             | Some reason when String.trim reason <> "" -> `String reason
                             | _ -> `Null );
                           ("memory_compaction_performed", `Bool memory_compaction_performed);
                           ("memory_before_notes", `Int memory_before_notes);
                           ("memory_after_notes", `Int memory_after_notes);
                           ("memory_dropped_notes", `Int memory_dropped_notes);
                           ("memory_invalid_dropped", `Int memory_invalid_dropped);
                           ( "memory_reason",
                             match Safe_ops.json_string_opt "memory_compaction_reason" j with
                             | Some reason when String.trim reason <> "" -> `String reason
                             | _ -> `Null );
                         ]
                       in
                       item :: acc
                   with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> acc)
                 [] lines
             in
             let events = List.rev events_rev in
             let total = List.length events in
             let start = max 0 (total - tail_compactions) in
             let tail = List.filteri (fun i _ -> i >= start) events in
             (`List tail, total)
         in

         let json = `Assoc [
           ("meta", meta_to_json m);
           ("goal", `String m.goal);
           ("short_goal", `String m.short_goal);
           ("mid_goal", `String m.mid_goal);
           ("long_goal", `String m.long_goal);
           ("goal_horizons", `Assoc [
             ("short", `String m.short_goal);
             ("mid", `String m.mid_goal);
             ("long", `String m.long_goal);
           ]);
           ("soul_profile", `String m.soul_profile);
           ("will", if String.trim m.will = "" then `Null else `String m.will);
           ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
           ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
           ("self_model", `Assoc [
             ("will", if String.trim m.will = "" then `Null else `String m.will);
             ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
             ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
           ]);
           ("keepalive_running", `Bool keepalive_running);
           ("agent", agent_status);
           ("diagnostic", diagnostic);
           ("keeper_age_s", `Float keeper_age_s);
           ("last_turn_ago_s", `Float last_turn_ago_s);
           ("last_handoff_ago_s", `Float last_handoff_ago_s);
           ("last_compaction_ago_s", `Float last_compaction_ago_s);
           ("last_proactive_ago_s", `Float last_proactive_ago_s);
           ("active_model", `String active_model);
           ("next_model_hint", match next_model_hint with Some s -> `String s | None -> `Null);
           ("trace_history_count", `Int trace_history_count);
           ("handoff_count_total", `Int trace_history_count);
           ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
           ("lifecycle", `Assoc [
             ("created_at", `String m.created_at);
             ("updated_at", `String m.updated_at);
             ("uptime_hours", `Float (keeper_age_s /. 3600.0));
           ]);
           ("proactive", `Assoc [
             ("enabled", `Bool m.proactive_enabled);
             ("idle_sec", `Int m.proactive_idle_sec);
             ("cooldown_sec", `Int m.proactive_cooldown_sec);
             ("count_total", `Int m.proactive_count_total);
             ("last_ts", `Float m.last_proactive_ts);
             ("last_ago_s", `Float last_proactive_ago_s);
             ("last_reason",
               if String.trim m.last_proactive_reason = ""
               then `Null
               else `String m.last_proactive_reason);
             ("last_preview",
               if String.trim m.last_proactive_preview = ""
               then `Null
               else `String m.last_proactive_preview);
           ]);
           ("drift", `Assoc [
             ("enabled", `Bool m.drift_enabled);
             ("min_turn_gap", `Int m.drift_min_turn_gap);
             ("count_total", `Int m.drift_count_total);
             ("last_turn", `Int m.last_drift_turn);
             ("last_reason",
               if String.trim m.last_drift_reason = ""
               then `Null
               else `String m.last_drift_reason);
           ]);
           ("policy", `Assoc [
             ("mode", `String m.policy_mode);
             ("action_budget", `String m.policy_action_budget);
             ("reward_model_path",
               if String.trim m.policy_reward_model_path = ""
               then `Null
               else `String m.policy_reward_model_path);
           ]);
           ("compaction_policy", `Assoc [
             ("profile", `String m.compaction_profile);
             ("ratio_gate", `Float compact_ratio_gate);
             ("message_gate", `Int compact_message_gate);
             ("token_gate", `Int compact_token_gate);
             ("token_gate_enabled", `Bool (compact_token_gate > 0));
           ]);
           ("status_options", `Assoc [
             ("fast", `Bool fast);
             ("include_context", `Bool include_context);
             ("include_metrics_overview", `Bool include_metrics_overview);
             ("include_memory_bank", `Bool include_memory_bank);
             ("include_history_tail", `Bool include_history_tail);
             ("include_compaction_history", `Bool include_compaction_history);
           ]);
	           ("models_resolved", models_resolved);
	           ("context", ctx_stats);
	           ("skill_route", match last_skill_route with Some v -> v | None -> `Null);
	           ("metrics_overview", metrics_summary_to_json metrics_overview);
	           ("memory_bank", memory_summary_to_json memory_bank_summary);
           ("metrics_tail", metrics_tail);
           ("history_tail", history_tail);
           ("history_tail_count",
             match history_tail with
             | `List xs -> `Int (List.length xs)
             | _ -> `Int 0);
           ("history_raw_count", `Int history_raw_count);
           ("history_fragment_count", `Int history_fragment_count);
           ("history_fragment_filtered_count", `Int history_fragment_filtered_count);
           ("history_fragment_filter_enabled", `Bool history_filter_fragments);
           ("compaction_history_tail", fst compaction_history_tail);
           ("compaction_history_count", `Int (snd compaction_history_tail));
           ("storage_paths", `Assoc [
             ("meta", `String (keeper_meta_path ctx.config m.name));
             ("metrics", `String metrics_path);
             ("memory_bank", `String memory_bank_path);
             ("policy", `String (keeper_policy_log_path ctx.config m.name));
             ("feedback", `String (keeper_feedback_log_path ctx.config m.name));
             ("dataset_export", `String (keeper_dataset_export_path ctx.config m.name));
             ("session_dir", `String session_dir);
             ("history", `String history_path);
           ]);
         ] in
         (true, Yojson.Safe.pretty_to_string json))

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
             max 5 (min 300 sec))
    in
    match inline_soul_profile_res, new_soul_profile_res with
    | Error e, _ | _, Error e -> (false, "❌ " ^ e)
    | Ok inline_soul_profile, Ok new_soul_profile ->
    (* Ensure keeper exists (create inline if missing) *)
    let ensure_keeper () : (keeper_meta, string) result =
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
            dedupe_keep_order (profile_defaults.allowed_models @ inline_models)
          in
          let active_model =
            profile_defaults.active_model
            |> Option.value
                 ~default:
                   (match inline_models with
                    | model :: _ -> model
                    | [] -> "")
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
            policy_mode = "heuristic";
            policy_action_budget = "conversation";
            policy_reward_model_path = "";
            scope_kind;
            room_scope;
            trigger_mode;
            mention_targets;
            joined_room_ids = [];
            last_seen_seq_by_room = [];
            generation = 0;
            verify = false;
            presence_keepalive = true;
            presence_keepalive_sec = 30;
            proactive_enabled =
              Option.value
                ~default:(if trigger_mode = "explicit_only" then false else default_proactive_enabled)
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
            autonomy_level = "l1_reactive";
            active_goal_ids = [];
            last_autonomous_action_at = "";
            autonomous_action_count = 0;
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
                 with exn -> Printf.eprintf "[keeper] save_checkpoint (ensure) failed: %s\n%!" (Printexc.to_string exn));
                match write_meta ctx.config meta with
                | Error e -> Error e
                | Ok () -> Ok meta))
    in
    match ensure_keeper () with
    | Error e -> (false, "❌ " ^ e)
    | Ok meta0 ->
      (* Update keeper settings inline if requested. *)
      let meta =
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
          (try ignore (write_meta ctx.config updated)
           with exn -> Printf.eprintf "[keeper] write_meta (settings) failed: %s\n%!" (Printexc.to_string exn));
          updated
      in
      start_keepalive ctx meta;
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
        if meta.trigger_mode = "explicit_only" || keeper_policy_mode_is_learned meta then effective_models
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
                  tools = keeper_llm_tools;
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
               with exn -> Printf.eprintf "[keeper] trajectory finalize (error path) failed: %s\n%!" (Printexc.to_string exn));
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
                    if write_done then [] else keeper_llm_tools
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
                          let safe_reply =
                            if no_state_block then
                              let stripped =
                                strip_state_blocks_text safe_reply_with_skill
                                |> String.trim
                              in
                              if stripped = "" then safe_reply_with_skill else stripped
                            else
                              safe_reply_with_skill
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
                match parse_state_snapshot_from_reply safe_reply with
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
                  ~reply:safe_reply
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
               with exn -> Printf.eprintf "[keeper] save_checkpoint (turn) failed: %s\n%!" (Printexc.to_string exn));

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
                      Printf.eprintf "[keeper] room broadcast (guardrail_stop) failed: %s\n%!" (Printexc.to_string exn));
                   (* SSE: keeper_guardrail — dashboard real-time alert *)
                   (try Sse.broadcast (`Assoc [
                     ("type", `String "keeper_guardrail");
                     ("name", `String meta_turn.name);
                     ("reason", `String (Option.value ~default:"policy threshold exceeded"
                        auto_rules.guardrail_reason));
                   ]) with exn ->
                     Printf.eprintf "[keeper] SSE keeper_guardrail broadcast failed: %s\n%!" (Printexc.to_string exn)));
                let do_handoff =
                  auto_rules.handoff &&
		                (now_ts -. meta_turn.last_handoff_ts >= float_of_int meta_turn.handoff_cooldown_sec)
		              in
                (do_handoff, auto_rules)
	              in
	              let (do_handoff, auto_rules) = handoff_eval in

	              let metrics_path = keeper_metrics_path ctx.config meta_turn.name in
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

              if not do_handoff then begin
                (match write_meta ctx.config meta_turn with
                 | Ok () -> ()
                 | Error e -> Printf.eprintf "[keeper:%s] failed to write meta: %s\n%!" meta_turn.name e);

                (try
                   let metrics_json = `Assoc [
                     ("ts", `String (now_iso ()));
                     ("ts_unix", `Float now_ts);
                     ("channel", `String "turn");
                     ("name", `String meta_turn.name);
                     ("agent_name", `String meta_turn.agent_name);
                     ("trace_id", `String meta_turn.trace_id);
                     ("generation", `Int meta_turn.generation);
                     ("model_used", `String final_model_used);
                     ("usage", `Assoc [
                       ("input_tokens", `Int final_usage.input_tokens);
                       ("output_tokens", `Int final_usage.output_tokens);
                       ("total_tokens", `Int final_usage.total_tokens);
                     ]);
                     ("latency_ms", `Int final_latency_ms);
                     ("cost_usd", `Float total_cost_usd_turn);
                     ("context_ratio", `Float ctx_ratio);
                     ("context_tokens", `Int ctx_work.token_count);
                     ("context_max", `Int ctx_work.max_tokens);
                     ("message_count", `Int (List.length ctx_work.messages));
                     ("compacted", `Bool compacted);
                     ("compaction_before_tokens", `Int before_compact_tokens);
                     ("compaction_after_tokens", `Int after_compact_tokens);
                     ( "compaction_trigger",
                       match compaction_trigger with
                       | Some reason -> `String reason
                       | None -> `Null );
                     ("compaction_decision", `String compaction_decision);
	                     ("work_kind", `String work_kind);
	                     ("tool_call_count", `Int tool_call_count);
	                     ("tools_used", `List (List.map (fun s -> `String s) tools_used));
		                     ("skill_primary", `String effective_skill_route.primary_skill);
		                     ("skill_secondary",
		                       `List (List.map (fun s -> `String s) effective_skill_route.secondary_skills));
			                     ("skill_reason", `String effective_skill_route.reason);
                             ("skill_selection_mode",
                               `String skill_route_resolution.selection_mode);
                             ("skill_provenance",
                               `String skill_route_resolution.provenance);
		                     ("memory_check", memory_check_json);
                     ("auto_rules", keeper_auto_rule_eval_to_json auto_rules);
                     ("reflection", keeper_reflection_payload_of_auto_rules auto_rules);
                     ("auto_reflect", `Bool auto_rules.reflect);
                     ("auto_plan", `Bool auto_rules.plan);
                     ("auto_compact", `Bool auto_rules.compact);
                     ("auto_handoff", `Bool auto_rules.handoff);
                     ("guardrail_stop", `Bool auto_rules.guardrail_stop);
                     ("guardrail_stop_reason",
                       match auto_rules.guardrail_reason with
                       | Some reason -> `String reason
                       | None -> `Null);
	                     ("repetition_risk", `Float repetition_risk);
	                     ("goal_alignment", `Float goal_alignment);
                     ("response_alignment", `Float response_alignment);
                     ("goal_drift", `Float auto_rules.goal_drift);
		                     ("drift", `Assoc [
	                       ("enabled", `Bool meta_turn.drift_enabled);
                       ("applied", `Bool drift_applied);
                       ("reason",
                         match drift_reason with
                         | Some reason -> `String reason
                         | None -> `Null);
                       ("min_turn_gap", `Int meta_turn.drift_min_turn_gap);
                       ("count_total", `Int meta_turn.drift_count_total);
                       ("last_turn", `Int meta_turn.last_drift_turn);
                       ("last_reason",
                         if String.trim meta_turn.last_drift_reason = ""
                         then `Null
                         else `String meta_turn.last_drift_reason);
                     ]);
                     ("memory_notes_added", `Int memory_notes_added);
                     ("memory_note_kinds",
                       `List (List.map (fun s -> `String s) memory_note_kinds));
                     ("memory_top_kind",
                       match memory_top_kind with
                       | Some kind -> `String kind
                       | None -> `Null);
                     ("memory_compaction_performed", `Bool memory_compaction.performed);
                     ("memory_compaction_reason",
                       match memory_compaction.reason with
                       | Some reason -> `String reason
                       | None -> `Null);
                     ("memory_compaction_target_notes", `Int memory_compaction.target_notes);
                     ("memory_compaction_before_notes", `Int memory_compaction.before_notes);
                     ("memory_compaction_after_notes", `Int memory_compaction.after_notes);
                     ("memory_compaction_dropped_notes", `Int memory_compaction.dropped_notes);
                     ("memory_compaction_dedup_dropped", `Int memory_compaction.dedup_dropped);
                     ("memory_compaction_invalid_dropped", `Int memory_compaction.invalid_dropped);
                     ("interesting_alert_triggered", `Bool interesting_alert.triggered);
                     ("interesting_alert_score", `Float interesting_alert.score);
                     ("interesting_alert", interesting_alert_result_to_json interesting_alert);
                     ("handoff", `Assoc [("performed", `Bool false)]);
                   ] in
                   append_jsonl_line metrics_path metrics_json
                 with exn ->
                   Printf.eprintf "[keeper] turn metrics JSONL write failed: %s\n%!" (Printexc.to_string exn));
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
                (if compacted then
                  (try Sse.broadcast (`Assoc [
                    ("type", `String "keeper_compaction");
                    ("name", `String meta_turn.name);
                    ("saved_tokens", `Int (before_compact_tokens - after_compact_tokens));
                    ("trigger", match compaction_trigger with
                      | Some r -> `String r | None -> `Null);
                  ]) with exn ->
                    Printf.eprintf "[keeper] SSE keeper_compaction broadcast failed: %s\n%!" (Printexc.to_string exn)));

                let json = `Assoc [
                  ("name", `String meta_turn.name);
                  ("trace_id", `String meta_turn.trace_id);
                  ("generation", `Int meta_turn.generation);
                  ("soul_profile", `String meta_turn.soul_profile);
                  ("will", if String.trim meta_turn.will = "" then `Null else `String meta_turn.will);
                  ("needs", if String.trim meta_turn.needs = "" then `Null else `String meta_turn.needs);
                  ("desires", if String.trim meta_turn.desires = "" then `Null else `String meta_turn.desires);
                  ("model_used", `String final_model_used);
                  ("usage", `Assoc [
                    ("input_tokens", `Int final_usage.input_tokens);
                    ("output_tokens", `Int final_usage.output_tokens);
                    ("total_tokens", `Int final_usage.total_tokens);
                  ]);
                  ("latency_ms", `Int final_latency_ms);
                  ("cost_usd", `Float total_cost_usd_turn);
                  ("reply", `String safe_reply);
                  ("context_ratio", `Float ctx_ratio);
                  ("compacted", `Bool compacted);
                  ( "compaction_trigger",
                    match compaction_trigger with
                    | Some reason -> `String reason
                    | None -> `Null );
	                  ("work_kind", `String work_kind);
	                  ("tool_call_count", `Int tool_call_count);
	                  ("tools_used", `List (List.map (fun s -> `String s) tools_used));
		                  ("skill_primary", `String effective_skill_route.primary_skill);
		                  ("skill_secondary",
		                    `List (List.map (fun s -> `String s) effective_skill_route.secondary_skills));
			                  ("skill_reason", `String effective_skill_route.reason);
                          ("skill_selection_mode",
                            `String skill_route_resolution.selection_mode);
                          ("skill_provenance",
                            `String skill_route_resolution.provenance);
			                  ("memory_check", memory_check_json);
                  ("auto_rules", keeper_auto_rule_eval_to_json auto_rules);
                  ("reflection", keeper_reflection_payload_of_auto_rules auto_rules);
                  ("auto_reflect", `Bool auto_rules.reflect);
                  ("auto_plan", `Bool auto_rules.plan);
                  ("auto_compact", `Bool auto_rules.compact);
                  ("auto_handoff", `Bool auto_rules.handoff);
                  ("guardrail_stop", `Bool auto_rules.guardrail_stop);
                  ("guardrail_stop_reason",
                    match auto_rules.guardrail_reason with
                    | Some reason -> `String reason
                    | None -> `Null);
	                  ("repetition_risk", `Float repetition_risk);
	                  ("goal_alignment", `Float goal_alignment);
                  ("response_alignment", `Float response_alignment);
                  ("goal_drift", `Float auto_rules.goal_drift);
		                  ("drift", `Assoc [
	                    ("enabled", `Bool meta_turn.drift_enabled);
                    ("applied", `Bool drift_applied);
                    ("reason",
                      match drift_reason with
                      | Some reason -> `String reason
                      | None -> `Null);
                    ("min_turn_gap", `Int meta_turn.drift_min_turn_gap);
                    ("count_total", `Int meta_turn.drift_count_total);
                    ("last_turn", `Int meta_turn.last_drift_turn);
                    ("last_reason",
                      if String.trim meta_turn.last_drift_reason = ""
                      then `Null
                      else `String meta_turn.last_drift_reason);
                  ]);
                  ("memory_notes_added", `Int memory_notes_added);
                  ("memory_note_kinds",
                    `List (List.map (fun s -> `String s) memory_note_kinds));
                  ("memory_top_kind",
                    match memory_top_kind with
                    | Some kind -> `String kind
                    | None -> `Null);
                  ("memory_compaction_performed", `Bool memory_compaction.performed);
                  ("memory_compaction_reason",
                    match memory_compaction.reason with
                    | Some reason -> `String reason
                    | None -> `Null);
                  ("memory_compaction_target_notes", `Int memory_compaction.target_notes);
                  ("memory_compaction_before_notes", `Int memory_compaction.before_notes);
                  ("memory_compaction_after_notes", `Int memory_compaction.after_notes);
                  ("memory_compaction_dropped_notes", `Int memory_compaction.dropped_notes);
                  ("memory_compaction_dedup_dropped", `Int memory_compaction.dedup_dropped);
                  ("memory_compaction_invalid_dropped", `Int memory_compaction.invalid_dropped);
                  ("interesting_alert", interesting_alert_result_to_json interesting_alert);
                ] in
                (true, Yojson.Safe.pretty_to_string json)
              end else begin
                (* Auto-handoff: hydrate successor context + rotate trace_id. *)
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
                  ~working_ctx:ctx_work
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
                 with exn -> Printf.eprintf "[keeper] save_checkpoint (succession) failed: %s\n%!" (Printexc.to_string exn));

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
                 with exn -> Printf.eprintf "[keeper] write_meta (succession) failed: %s\n%!" (Printexc.to_string exn));

                (try
                   let metrics_json = `Assoc [
                     ("ts", `String (now_iso ()));
                     ("ts_unix", `Float now_ts);
                     ("channel", `String "turn");
                     ("name", `String meta'.name);
                     ("agent_name", `String meta'.agent_name);
                     ("trace_id", `String prev_trace_id);
                     ("generation", `Int meta_turn.generation);
                     ("model_used", `String final_model_used);
                     ("usage", `Assoc [
                       ("input_tokens", `Int final_usage.input_tokens);
                       ("output_tokens", `Int final_usage.output_tokens);
                       ("total_tokens", `Int final_usage.total_tokens);
                     ]);
                     ("latency_ms", `Int final_latency_ms);
                     ("cost_usd", `Float total_cost_usd_turn);
                     ("context_ratio", `Float ctx_ratio);
                     ("context_tokens", `Int ctx_work.token_count);
                     ("context_max", `Int ctx_work.max_tokens);
                     ("message_count", `Int (List.length ctx_work.messages));
                     ("compacted", `Bool compacted);
                     ("compaction_before_tokens", `Int before_compact_tokens);
                     ("compaction_after_tokens", `Int after_compact_tokens);
                     ( "compaction_trigger",
                       match compaction_trigger with
                       | Some reason -> `String reason
                       | None -> `Null );
	                     ("work_kind", `String work_kind);
	                     ("tool_call_count", `Int tool_call_count);
	                     ("tools_used", `List (List.map (fun s -> `String s) tools_used));
		                     ("skill_primary", `String effective_skill_route.primary_skill);
		                     ("skill_secondary",
		                       `List (List.map (fun s -> `String s) effective_skill_route.secondary_skills));
			                     ("skill_reason", `String effective_skill_route.reason);
                             ("skill_selection_mode",
                               `String skill_route_resolution.selection_mode);
                             ("skill_provenance",
                               `String skill_route_resolution.provenance);
			                     ("memory_check", memory_check_json);
                     ("auto_rules", keeper_auto_rule_eval_to_json auto_rules);
                     ("reflection", keeper_reflection_payload_of_auto_rules auto_rules);
                     ("auto_reflect", `Bool auto_rules.reflect);
                     ("auto_plan", `Bool auto_rules.plan);
                     ("auto_compact", `Bool auto_rules.compact);
                     ("auto_handoff", `Bool auto_rules.handoff);
                     ("guardrail_stop", `Bool auto_rules.guardrail_stop);
                     ("guardrail_stop_reason",
                       match auto_rules.guardrail_reason with
                       | Some reason -> `String reason
                       | None -> `Null);
	                     ("repetition_risk", `Float repetition_risk);
	                     ("goal_alignment", `Float goal_alignment);
                     ("response_alignment", `Float response_alignment);
                     ("goal_drift", `Float auto_rules.goal_drift);
		                     ("drift", `Assoc [
	                       ("enabled", `Bool meta_turn.drift_enabled);
                       ("applied", `Bool drift_applied);
                       ("reason",
                         match drift_reason with
                         | Some reason -> `String reason
                         | None -> `Null);
                       ("min_turn_gap", `Int meta_turn.drift_min_turn_gap);
                       ("count_total", `Int meta_turn.drift_count_total);
                       ("last_turn", `Int meta_turn.last_drift_turn);
                       ("last_reason",
                         if String.trim meta_turn.last_drift_reason = ""
                         then `Null
                         else `String meta_turn.last_drift_reason);
                     ]);
                     ("memory_notes_added", `Int memory_notes_added);
                     ("memory_note_kinds",
                       `List (List.map (fun s -> `String s) memory_note_kinds));
                     ("memory_top_kind",
                       match memory_top_kind with
                       | Some kind -> `String kind
                       | None -> `Null);
                     ("memory_compaction_performed", `Bool memory_compaction.performed);
                     ("memory_compaction_reason",
                       match memory_compaction.reason with
                       | Some reason -> `String reason
                       | None -> `Null);
                     ("memory_compaction_target_notes", `Int memory_compaction.target_notes);
                     ("memory_compaction_before_notes", `Int memory_compaction.before_notes);
                     ("memory_compaction_after_notes", `Int memory_compaction.after_notes);
                     ("memory_compaction_dropped_notes", `Int memory_compaction.dropped_notes);
                     ("memory_compaction_dedup_dropped", `Int memory_compaction.dedup_dropped);
                     ("memory_compaction_invalid_dropped", `Int memory_compaction.invalid_dropped);
                     ("interesting_alert_triggered", `Bool interesting_alert.triggered);
                     ("interesting_alert_score", `Float interesting_alert.score);
                     ("interesting_alert", interesting_alert_result_to_json interesting_alert);
                     ("handoff", `Assoc [
                       ("performed", `Bool true);
                       ("prev_trace_id", `String prev_trace_id);
                       ("new_trace_id", `String meta'.trace_id);
                       ("to_model", `String next_model.model_id);
                       ("new_generation", `Int meta'.generation);
                     ]);
                   ] in
                   append_jsonl_line metrics_path metrics_json
                 with exn ->
                   Printf.eprintf "[keeper] handoff metrics JSONL write failed: %s\n%!" (Printexc.to_string exn));
                (* SSE: keeper_handoff — generation succession event *)
                (try Sse.broadcast (`Assoc [
                  ("type", `String "keeper_handoff");
                  ("name", `String meta_turn.name);
                  ("from_generation", `Int meta_turn.generation);
                  ("to_generation", `Int next_generation);
                  ("to_model", `String next_model.model_id);
                ]) with exn ->
               Printf.eprintf "[keeper] SSE keeper_handoff broadcast failed: %s\n%!" (Printexc.to_string exn));

                let json = `Assoc [
                  ("name", `String meta'.name);
                  ("soul_profile", `String meta'.soul_profile);
                  ("will", if String.trim meta'.will = "" then `Null else `String meta'.will);
                  ("needs", if String.trim meta'.needs = "" then `Null else `String meta'.needs);
                  ("desires", if String.trim meta'.desires = "" then `Null else `String meta'.desires);
                  ("reply", `String safe_reply);
                  ("model_used", `String final_model_used);
                  ("latency_ms", `Int final_latency_ms);
                  ("cost_usd", `Float total_cost_usd_turn);
                  ("context_ratio", `Float ctx_ratio);
                  ("compacted", `Bool compacted);
                  ( "compaction_trigger",
                    match compaction_trigger with
                    | Some reason -> `String reason
                    | None -> `Null );
	                  ("work_kind", `String work_kind);
	                  ("tool_call_count", `Int tool_call_count);
	                  ("tools_used", `List (List.map (fun s -> `String s) tools_used));
		                  ("skill_primary", `String effective_skill_route.primary_skill);
		                  ("skill_secondary",
		                    `List (List.map (fun s -> `String s) effective_skill_route.secondary_skills));
			                  ("skill_reason", `String effective_skill_route.reason);
                          ("skill_selection_mode",
                            `String skill_route_resolution.selection_mode);
                          ("skill_provenance",
                            `String skill_route_resolution.provenance);
			                  ("memory_check", memory_check_json);
                  ("auto_rules", keeper_auto_rule_eval_to_json auto_rules);
                  ("reflection", keeper_reflection_payload_of_auto_rules auto_rules);
                  ("auto_reflect", `Bool auto_rules.reflect);
                  ("auto_plan", `Bool auto_rules.plan);
                  ("auto_compact", `Bool auto_rules.compact);
                  ("auto_handoff", `Bool auto_rules.handoff);
                  ("guardrail_stop", `Bool auto_rules.guardrail_stop);
                  ("guardrail_stop_reason",
                    match auto_rules.guardrail_reason with
                    | Some reason -> `String reason
                    | None -> `Null);
	                  ("repetition_risk", `Float repetition_risk);
	                  ("goal_alignment", `Float goal_alignment);
                  ("response_alignment", `Float response_alignment);
                  ("goal_drift", `Float auto_rules.goal_drift);
		                  ("drift", `Assoc [
	                    ("enabled", `Bool meta_turn.drift_enabled);
                    ("applied", `Bool drift_applied);
                    ("reason",
                      match drift_reason with
                      | Some reason -> `String reason
                      | None -> `Null);
                    ("min_turn_gap", `Int meta_turn.drift_min_turn_gap);
                    ("count_total", `Int meta_turn.drift_count_total);
                    ("last_turn", `Int meta_turn.last_drift_turn);
                    ("last_reason",
                      if String.trim meta_turn.last_drift_reason = ""
                      then `Null
                      else `String meta_turn.last_drift_reason);
                  ]);
                  ("memory_notes_added", `Int memory_notes_added);
                  ("memory_note_kinds",
                    `List (List.map (fun s -> `String s) memory_note_kinds));
                  ("memory_top_kind",
                    match memory_top_kind with
                    | Some kind -> `String kind
                    | None -> `Null);
                  ("memory_compaction_performed", `Bool memory_compaction.performed);
                  ("memory_compaction_reason",
                    match memory_compaction.reason with
                    | Some reason -> `String reason
                    | None -> `Null);
                  ("memory_compaction_target_notes", `Int memory_compaction.target_notes);
                  ("memory_compaction_before_notes", `Int memory_compaction.before_notes);
                  ("memory_compaction_after_notes", `Int memory_compaction.after_notes);
                  ("memory_compaction_dropped_notes", `Int memory_compaction.dropped_notes);
                  ("memory_compaction_dedup_dropped", `Int memory_compaction.dedup_dropped);
                  ("memory_compaction_invalid_dropped", `Int memory_compaction.invalid_dropped);
                  ("interesting_alert", interesting_alert_result_to_json interesting_alert);
                  ("handoff", `Assoc [
                    ("performed", `Bool true);
                    ("prev_trace_id", `String prev_trace_id);
                    ("new_trace_id", `String meta'.trace_id);
                    ("to_model", `String next_model.model_id);
                    ("new_generation", `Int meta'.generation);
                  ]);
                ] in
                (true, Yojson.Safe.pretty_to_string json)
              end))

let annotate_keeper_json ~runtime_class ~desired ~resident_registered json =
  match json with
  | `Assoc fields ->
      `Assoc
        (("runtime_class", `String runtime_class)
        :: ("desired", `Bool desired)
        :: ("resident_registered", `Bool resident_registered)
        :: fields)
  | other -> other

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

let handle_resident_keeper_model_set ctx args : tool_result =
  let name = get_string args "name" "" in
  match read_resident_keeper ctx.config name with
  | Error e -> (false, "❌ " ^ e)
  | Ok None -> (false, Printf.sprintf "resident keeper not found: %s" name)
  | Ok (Some _spec) ->
      let ok, body = handle_keeper_model_set ctx args in
      if not ok then (ok, body)
      else begin
        (match read_meta ctx.config name with
        | Ok (Some meta) -> ignore (register_resident_keeper_from_meta ctx.config meta)
        | _ -> ());
        let json =
          try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
        in
        (true,
         Yojson.Safe.pretty_to_string
           (annotate_keeper_json ~runtime_class:"resident_keeper" ~desired:true
              ~resident_registered:true json))
      end

let handle_keeper_policy_set ctx args : tool_result =
  let name = get_string args "name" "" in
  let policy_mode_raw = get_string args "policy_mode" "" |> String.trim in
  let action_budget_opt = get_string_opt args "action_budget" |> Option.map String.trim in
  let reward_model_path =
    get_string_opt args "reward_model_path" |> Option.value ~default:"" |> String.trim
  in
  let policy_mode_result =
    match policy_mode_raw with
    | "heuristic" | "learned_offline_v1" -> Ok policy_mode_raw
    | "" -> Error "policy_mode is required"
    | other -> Error (Printf.sprintf "invalid policy_mode: %s" other)
  in
  let action_budget_result =
    match action_budget_opt with
    | None -> Ok "conversation"
    | Some "conversation" -> Ok "conversation"
    | Some "board" -> Ok "board"
    | Some other -> Error (Printf.sprintf "invalid action_budget: %s" other)
  in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else if Result.is_error policy_mode_result then
    (false, "❌ " ^ Result.get_error policy_mode_result)
  else if Result.is_error action_budget_result then
    (false, "❌ " ^ Result.get_error action_budget_result)
  else
    let policy_mode = Result.get_ok policy_mode_result in
    let action_budget = Result.get_ok action_budget_result in
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some meta) ->
        let effective_reward_model_path_raw =
          if reward_model_path <> "" then reward_model_path else meta.policy_reward_model_path
        in
        let effective_reward_model_path =
          if effective_reward_model_path_raw <> ""
             && Filename.is_relative effective_reward_model_path_raw
          then
            Filename.concat ctx.config.base_path effective_reward_model_path_raw
          else
            effective_reward_model_path_raw
        in
        if policy_mode = "learned_offline_v1" then
          match load_keeper_reward_model effective_reward_model_path with
          | Error e -> (false, "❌ " ^ e)
          | Ok reward_model ->
              let updated =
                {
                  meta with
                  policy_mode;
                  policy_action_budget = action_budget;
                  policy_reward_model_path = reward_model.path;
                  updated_at = now_iso ();
                }
              in
              (match write_meta ctx.config updated with
               | Error e -> (false, "❌ " ^ e)
               | Ok () ->
                   ( true,
                     Yojson.Safe.pretty_to_string
                       (`Assoc
                         [
                           ("name", `String updated.name);
                           ("policy_mode", `String updated.policy_mode);
                           ("action_budget", `String updated.policy_action_budget);
                           ("reward_model_path", `String updated.policy_reward_model_path);
                           ("reward_model_version", `String reward_model.version);
                         ]) ))
        else
          let updated =
            {
              meta with
              policy_mode;
              policy_action_budget = action_budget;
              policy_reward_model_path = effective_reward_model_path;
              updated_at = now_iso ();
            }
          in
          match write_meta ctx.config updated with
          | Error e -> (false, "❌ " ^ e)
          | Ok () ->
              ( true,
                Yojson.Safe.pretty_to_string
                  (`Assoc
                    [
                      ("name", `String updated.name);
                      ("policy_mode", `String updated.policy_mode);
                      ("action_budget", `String updated.policy_action_budget);
                      ("reward_model_path",
                        if String.trim updated.policy_reward_model_path = ""
                        then `Null
                        else `String updated.policy_reward_model_path);
                    ]) )

let handle_keeper_feedback_record ctx args : tool_result =
  let name = get_string args "name" "" in
  let action_id = get_string args "action_id" "" |> String.trim in
  let verdict = get_string args "verdict" "" |> String.trim in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else if action_id = "" then
    (false, "❌ action_id is required")
  else if verdict = "" then
    (false, "❌ verdict is required")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some meta) ->
        let score_json =
          match Yojson.Safe.Util.member "score" args with
          | `Float score -> Some (`Float score)
          | `Int n -> Some (`Float (float_of_int n))
          | `Intlit raw ->
              Some (`Float (Safe_ops.float_of_string_with_default ~default:0.0 raw))
          | _ -> None
        in
        let note = get_string_opt args "note" |> Option.value ~default:"" |> String.trim in
        let json =
          `Assoc
            [
              ("ts", `String (now_iso ()));
              ("ts_unix", `Float (Time_compat.now ()));
              ("keeper", `String name);
              ("trace_id", `String meta.trace_id);
              ("action_id", `String action_id);
              ("verdict", `String verdict);
              ("score", Option.value ~default:`Null score_json);
              ("note", if note = "" then `Null else `String note);
            ]
        in
        append_jsonl_line (keeper_feedback_log_path ctx.config name) json;
        (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_dataset_export ctx args : tool_result =
  let name = get_string args "name" "" in
  let limit = max 1 (get_int args "limit" 200) in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some meta) ->
        let policy_rows =
          read_jsonl_rows
            (keeper_policy_log_path ctx.config name)
            ~max_bytes:600000
            ~max_lines:limit
        in
        let feedback_rows =
          read_jsonl_rows
            (keeper_feedback_log_path ctx.config name)
            ~max_bytes:400000
            ~max_lines:(limit * 4)
        in
        let feedback_by_action =
          List.fold_left
            (fun acc json ->
              match Safe_ops.json_string_opt "action_id" json with
              | Some action_id when String.trim action_id <> "" ->
                  let current =
                    acc
                    |> List.find_map (fun (key, value) ->
                           if key = action_id then Some value else None)
                    |> Option.value ~default:[]
                  in
                  (action_id, json :: current)
                  :: List.filter (fun (key, _) -> key <> action_id) acc
              | _ -> acc)
            []
            feedback_rows
        in
        let examples =
          policy_rows
          |> List.map (fun row ->
                 let action_id =
                   Safe_ops.json_string_opt "action_id" row |> Option.value ~default:""
                 in
                 let feedback =
                   feedback_by_action
                   |> List.find_map (fun (key, rows) ->
                          if key = action_id then Some (List.rev rows) else None)
                   |> Option.value ~default:[]
                 in
                 `Assoc
                   [
                     ("action", row);
                     ("feedback", `List feedback);
                   ])
        in
        let output_path =
          get_string_opt args "output_path"
          |> Option.value ~default:(keeper_dataset_export_path ctx.config name)
        in
        let resolved_output_path =
          if Filename.is_relative output_path then
            Filename.concat ctx.config.base_path output_path
          else
            output_path
        in
        mkdir_p (Filename.dirname resolved_output_path);
        let json =
          `Assoc
            [
              ("keeper", `String name);
              ("trace_id", `String meta.trace_id);
              ("exported_at", `String (now_iso ()));
              ("policy_row_count", `Int (List.length policy_rows));
              ("feedback_row_count", `Int (List.length feedback_rows));
              ("examples", `List examples);
            ]
        in
        let oc = open_out resolved_output_path in
        Common.protect
          ~module_name:"tool_keeper"
          ~finally_label:"close_out"
          ~finally:(fun () -> close_out_noerr oc)
          (fun () -> output_string oc (Yojson.Safe.pretty_to_string json));
        ( true,
          Yojson.Safe.pretty_to_string
            (`Assoc
              [
                ("keeper", `String name);
                ("output_path", `String resolved_output_path);
                ("policy_row_count", `Int (List.length policy_rows));
                ("feedback_row_count", `Int (List.length feedback_rows));
              ]) )

let handle_keeper_action_explain ctx args : tool_result =
  let name = get_string args "name" "" in
  let action_id = get_string_opt args "action_id" |> Option.value ~default:"" |> String.trim in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some _) ->
        let rows =
          read_jsonl_rows
            (keeper_policy_log_path ctx.config name)
            ~max_bytes:400000
            ~max_lines:120
        in
        let selected =
          if action_id = "" then
            match List.rev rows with row :: _ -> Some row | [] -> None
          else
            find_jsonl_row_by_action_id rows action_id
        in
        (match selected with
         | None -> (false, "❌ no policy action found")
         | Some row -> (true, Yojson.Safe.pretty_to_string row))

let handle_keeper_eval_replay ctx args : tool_result =
  let name = get_string args "name" "" in
  let limit = max 1 (get_int args "limit" 50) in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some meta) -> (
        match load_keeper_reward_model meta.policy_reward_model_path with
        | Error e -> (false, "❌ " ^ e)
        | Ok reward_model ->
            let rows =
              read_jsonl_rows
                (keeper_policy_log_path ctx.config name)
                ~max_bytes:500000
                ~max_lines:limit
            in
            let replayed =
              rows
              |> List.filter_map (fun row ->
                     let feature_vector =
                       match Yojson.Safe.Util.member "feature_vector" row with
                       | `Assoc fields ->
                           fields
                           |> List.filter_map (fun (feature, value) ->
                                  match value with
                                  | `Float v -> Some (feature, v)
                                  | `Int n -> Some (feature, float_of_int n)
                                  | _ -> None)
                       | _ -> []
                     in
                     let chosen_action = Safe_ops.json_string_opt "chosen_action" row in
                     let observation = Yojson.Safe.Util.member "observation" row in
                     let direct_mention =
                       Safe_ops.json_bool ~default:false "direct_mention" observation
                     in
                     let heuristic_action =
                       deterministic_policy_baseline_action
                         {
                           source_kind =
                             Safe_ops.json_string ~default:"room_message" "source_kind" observation;
                           room_id = Safe_ops.json_string_opt "room_id" observation;
                           from_agent =
                             Safe_ops.json_string ~default:"" "from_agent" observation;
                           message =
                             Safe_ops.json_string ~default:"" "message" observation;
                           direct_mention;
                           has_question =
                             Safe_ops.json_bool ~default:false "has_question" observation;
                           message_chars =
                             Safe_ops.json_int ~default:0 "message_chars" observation;
                           total_turns =
                             Safe_ops.json_int ~default:0 "total_turns" observation;
                           active_goal_count =
                             Safe_ops.json_int ~default:0 "active_goal_count" observation;
                           joined_room_count =
                             Safe_ops.json_int ~default:0 "joined_room_count" observation;
                           room_scope =
                             Safe_ops.json_string ~default:"current" "room_scope" observation;
                           trigger_mode =
                             Safe_ops.json_string ~default:"legacy" "trigger_mode" observation;
                           last_turn_ago_s =
                             Safe_ops.json_float ~default:0.0 "last_turn_ago_s" observation;
                         }
                     in
                     let candidate_names =
                       match Yojson.Safe.Util.member "candidates" row with
                       | `List xs ->
                           xs
                           |> List.filter_map (fun candidate ->
                                  Safe_ops.json_string_opt "action" candidate)
                       | _ -> []
                     in
                     let rescored =
                       candidate_names
                       |> List.map (fun action ->
                              score_keeper_policy_candidate
                                ~model:reward_model
                                ~features:feature_vector
                                ~action
                                ~allowed:true)
                     in
                     choose_policy_action rescored
                     |> Option.map (fun learned_candidate ->
                            `Assoc
                              [
                                ("action_id",
                                  match Safe_ops.json_string_opt "action_id" row with
                                  | Some value -> `String value
                                  | None -> `Null);
                                ("chosen_action",
                                  match chosen_action with
                                  | Some value -> `String value
                                  | None -> `Null);
                                ("heuristic_action", `String heuristic_action);
                                ("replayed_action", `String learned_candidate.action);
                                ("replayed_score", `Float learned_candidate.score);
                                ("matches_logged",
                                  `Bool
                                    (match chosen_action with
                                     | Some value -> value = learned_candidate.action
                                     | None -> false));
                                ("differs_from_heuristic",
                                  `Bool (heuristic_action <> learned_candidate.action));
                              ]))
            in
            let matches_logged =
              replayed
              |> List.fold_left
                   (fun acc json ->
                     if Safe_ops.json_bool ~default:false "matches_logged" json then acc + 1
                     else acc)
                   0
            in
            let differs_from_heuristic =
              replayed
              |> List.fold_left
                   (fun acc json ->
                     if Safe_ops.json_bool ~default:false "differs_from_heuristic" json then acc + 1
                     else acc)
                   0
            in
            let json =
              `Assoc
                [
                  ("keeper", `String name);
                  ("reward_model_path", `String reward_model.path);
                  ("reward_model_version", `String reward_model.version);
                  ("replayed_count", `Int (List.length replayed));
                  ("matches_logged_count", `Int matches_logged);
                  ("differs_from_heuristic_count", `Int differs_from_heuristic);
                  ("entries", `List replayed);
                ]
            in
            (true, Yojson.Safe.pretty_to_string json))

let handle_persona_list _ctx args : tool_result =
  let detailed = get_bool args "detailed" true in
  let personas = list_persona_summaries () in
  let payload =
    if detailed then
      `List (List.map persona_summary_to_json personas)
    else
      string_list_to_json (List.map (fun persona -> persona.persona_name) personas)
  in
  let json =
    `Assoc
      [
        ("count", `Int (List.length personas));
        ("personas", payload);
      ]
  in
  (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_create_from_persona ctx args : tool_result =
  match resolved_keeper_args_from_persona args with
  | Error e -> (false, "❌ " ^ e)
  | Ok (persona, resolved_args) ->
      let errors = validate_resolved_keeper_create_json resolved_args in
      let dry_run = get_bool args "dry_run" false in
      if dry_run then
        let json =
          `Assoc
            [
              ("persona", persona_summary_to_json persona);
              ("ready", `Bool (errors = []));
              ("errors", string_list_to_json errors);
              ("resolved_args", resolved_args);
            ]
        in
        (true, Yojson.Safe.pretty_to_string json)
      else if errors <> [] then
        ( false,
          Yojson.Safe.pretty_to_string
            (`Assoc
              [
                ("persona", persona_summary_to_json persona);
                ("ready", `Bool false);
                ("errors", string_list_to_json errors);
                ("resolved_args", resolved_args);
              ]) )
      else
        let ok, body = handle_keeper_up ctx resolved_args in
        if not ok then
          (false, body)
        else
          let created_json =
            try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
          in
          let json =
            `Assoc
              [
                ("persona", persona_summary_to_json persona);
                ("created", `Bool true);
                ("result", created_json);
                ("resolved_args", resolved_args);
              ]
          in
          (true, Yojson.Safe.pretty_to_string json)

let handle_resident_keeper_create_from_persona ctx args : tool_result =
  match resolved_keeper_args_from_persona args with
  | Error e -> (false, "❌ " ^ e)
  | Ok (persona, resolved_args) ->
      let dry_run = get_bool args "dry_run" false in
      if dry_run then
        let json =
          `Assoc
            [
              ("persona", persona_summary_to_json persona);
              ("created", `Bool false);
              ("resident", `Bool true);
              ("resolved_args", resolved_args);
            ]
        in
        (true, Yojson.Safe.pretty_to_string json)
      else
        let ok, body = handle_keeper_up ctx resolved_args in
        if not ok then
          (false, body)
        else
          let name =
            match resolved_args with
            | `Assoc fields -> (
                match List.assoc_opt "name" fields with
                | Some (`String value) -> value
                | _ -> "")
            | _ -> ""
          in
          let register_result =
            match read_meta ctx.config name with
            | Ok (Some meta) -> register_resident_keeper_from_meta ctx.config meta
            | Ok None -> Error "resident keeper meta missing after persona create"
            | Error e -> Error e
          in
          (match register_result with
          | Error e -> (false, "❌ " ^ e)
          | Ok () ->
              let created_json =
                try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
              in
              let json =
                `Assoc
                  [
                    ("persona", persona_summary_to_json persona);
                    ("created", `Bool true);
                    ("resident", `Bool true);
                    ("result", annotate_keeper_json ~runtime_class:"resident_keeper" ~desired:true ~resident_registered:true created_json);
                    ("resolved_args", resolved_args);
                  ]
              in
              (true, Yojson.Safe.pretty_to_string json))

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
      if remove_meta then
        Safe_ops.remove_file_logged ~context:"keeper_down" (keeper_meta_path ctx.config name);
      if remove_session then begin
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
        if validate_name m.trace_id then
          let dir = Filename.concat (session_base_dir ctx.config) m.trace_id in
          (try rm_rf dir with exn ->
          Printf.eprintf "[keeper] session dir cleanup failed: %s\n%!" (Printexc.to_string exn))
      end;
      let json = `Assoc [
        ("name", `String name);
        ("stopped", `Bool true);
        ("remove_meta", `Bool remove_meta);
        ("remove_session", `Bool remove_session);
      ] in
      (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_list ctx args : tool_result =
  let limit = max 0 (get_int args "limit" 50) in
  let detailed = get_bool args "detailed" false in
  let dir = keeper_dir ctx.config in
  match Safe_ops.list_dir_safe dir with
  | Error e -> (false, "❌ " ^ e)
  | Ok files ->
    let keeper_names =
      files
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.map Filename.remove_extension
      |> List.filter validate_name
      |> List.sort String.compare
      |> take limit
    in
    if not detailed then
      let json = `Assoc [
        ("count", `Int (List.length keeper_names));
        ("keepers", `List (List.map (fun k -> `String k) keeper_names));
      ] in
      (true, Yojson.Safe.pretty_to_string json)
    else
      let now_ts = Time_compat.now () in
      let keepers =
        List.filter_map (fun name ->
          match read_meta ctx.config name with
          | Error _ -> None
          | Ok None -> None
          | Ok (Some m) ->
            let created_ts =
              Resilience.Time.parse_iso8601_opt m.created_at |> Option.value ~default:0.0
            in
            let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
            let last_turn_ago_s = if m.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.last_turn_ts in
            let last_proactive_ago_s =
              if m.last_proactive_ts <= 0.0 then 0.0 else now_ts -. m.last_proactive_ts
            in
            let active_model = active_model_of_meta m in
            let next_model_hint = next_model_hint_of_meta m in
            let trace_history_count = List.length m.trace_history in
            let last_compaction_saved_tokens =
              max 0 (m.last_compaction_before_tokens - m.last_compaction_after_tokens)
            in
            let (compact_ratio_gate, compact_message_gate, compact_token_gate) =
              compaction_policy_of_keeper m
            in
	            let metrics_path = keeper_metrics_path ctx.config m.name in
	            let metrics_window_lines =
	              read_file_tail_lines metrics_path ~max_bytes:120000 ~max_lines:120
	            in
	            let last_metrics =
	              match List.rev metrics_window_lines with
	              | line :: _ -> (try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None)
	              | [] -> None
	            in
	            let metrics_overview =
	              summarize_metrics_lines metrics_window_lines ~default_generation:m.generation
	            in
	            let last_skill_metrics =
	              let rec find_latest = function
	                | [] -> None
	                | line :: tl ->
	                    (try
	                       let j = Yojson.Safe.from_string line in
	                       match Safe_ops.json_string_opt "skill_primary" j with
	                       | Some primary when String.trim primary <> "" -> Some j
	                       | _ -> find_latest tl
	                     with Yojson.Json_error _ -> find_latest tl)
	              in
	              find_latest (List.rev metrics_window_lines)
	            in
            let memory_bank_summary =
              read_keeper_memory_summary
                ctx.config
                ~name:m.name
                ~max_bytes:120000
                ~max_lines:180
                ~recent_limit:3
            in
            let memory_recent_note =
              match memory_bank_summary.recent_notes with
              | row :: _ -> Some row.text
              | [] -> None
            in
            let continuity_reflection_hold_s =
              let cooldown = Float.of_int m.continuity_compaction_cooldown_sec in
              let last_reflection_ts =
                max m.last_continuity_update_ts m.last_proactive_ts
              in
              if cooldown <= 0.0 then
                0.0
              else if last_reflection_ts <= 0.0 then
                cooldown
              else
                let elapsed = now_ts -. last_reflection_ts in
                max 0.0 (cooldown -. elapsed)
            in
	            let context_json =
	              match last_metrics with
	              | None -> `Assoc [("source", `String "none")]
	              | Some metrics ->
	                `Assoc [
	                  ("source", `String "metrics");
	                  ("context_ratio", `Float (Safe_ops.json_float "context_ratio" metrics));
	                  ("context_tokens", `Int (Safe_ops.json_int "context_tokens" metrics));
	                  ("context_max", `Int (Safe_ops.json_int "context_max" metrics));
	                  ("message_count", `Int (Safe_ops.json_int "message_count" metrics));
	                ]
	            in
	            let skill_route_json =
	              let open Yojson.Safe.Util in
                  let configured_selection_mode = keeper_skill_selection_mode () in
                  let fallback_selection_mode_string, fallback_selection_provenance =
                    match configured_selection_mode with
                    | SkillSelectAgent -> ("agent", "judgment")
                    | SkillSelectHeuristic -> ("heuristic", "fallback")
                  in
	              match last_skill_metrics with
	              | None -> `Null
	              | Some metrics ->
	                  let primary = Safe_ops.json_string_opt "skill_primary" metrics in
	                  let secondary =
	                    match metrics |> member "skill_secondary" with
	                    | `List xs ->
	                        xs
	                        |> List.filter_map (fun v ->
	                             match v with `String s when String.trim s <> "" -> Some s | _ -> None)
	                    | _ -> []
	                  in
	                  let reason = Safe_ops.json_string_opt "skill_reason" metrics in
	                  `Assoc [
	                    ("primary", match primary with Some s -> `String s | None -> `Null);
	                    ("secondary", `List (List.map (fun s -> `String s) secondary));
	                    ("reason", match reason with Some s -> `String s | None -> `Null);
                        ( "selection_mode",
                          `String
                            (Safe_ops.json_string_opt "skill_selection_mode" metrics
                             |> Option.value ~default:fallback_selection_mode_string) );
                        ( "provenance",
                          `String
                            (Safe_ops.json_string_opt "skill_provenance" metrics
                             |> Option.value ~default:fallback_selection_provenance) );
                        ("authoritative", `Bool false);
	                  ]
	            in
	            Some (`Assoc [
              ("name", `String m.name);
              ("agent_name", `String m.agent_name);
              ("trace_id", `String m.trace_id);
              ("generation", `Int m.generation);
              ("goal", `String m.goal);
              ("short_goal", `String m.short_goal);
              ("mid_goal", `String m.mid_goal);
              ("long_goal", `String m.long_goal);
              ("goal_horizons", `Assoc [
                ("short", `String m.short_goal);
                ("mid", `String m.mid_goal);
                ("long", `String m.long_goal);
              ]);
              ("soul_profile", `String m.soul_profile);
              ("will", if String.trim m.will = "" then `Null else `String m.will);
              ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
              ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
              ("keepalive_running", `Bool (Hashtbl.mem keepalives m.name));
              ("active_model", `String active_model);
              ("next_model_hint", match next_model_hint with Some s -> `String s | None -> `Null);
              ("keeper_age_s", `Float keeper_age_s);
              ("last_turn_ago_s", `Float last_turn_ago_s);
              ("last_proactive_ago_s", `Float last_proactive_ago_s);
              ("trace_history_count", `Int trace_history_count);
              ("handoff_count_total", `Int trace_history_count);
              ("compaction_count", `Int m.compaction_count);
              ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
              ("compaction_profile", `String m.compaction_profile);
              ("compaction_ratio_gate", `Float compact_ratio_gate);
              ("compaction_message_gate", `Int compact_message_gate);
              ("compaction_token_gate", `Int compact_token_gate);
              ("proactive_enabled", `Bool m.proactive_enabled);
              ("proactive_idle_sec", `Int m.proactive_idle_sec);
              ("proactive_cooldown_sec", `Int m.proactive_cooldown_sec);
              ("proactive_count_total", `Int m.proactive_count_total);
              ("last_compaction_check_ts", `Float m.last_compaction_check_ts);
              ("last_compaction_decision",
                if String.trim m.last_compaction_decision = "" then `Null
                else `String m.last_compaction_decision);
              ("last_proactive_ts", `Float m.last_proactive_ts);
              ("last_proactive_reason",
                if String.trim m.last_proactive_reason = ""
                then `Null
                else `String m.last_proactive_reason);
              ("last_proactive_preview",
                if String.trim m.last_proactive_preview = ""
                then `Null
                else `String m.last_proactive_preview);
              ("continuity_summary",
                if String.trim m.continuity_summary = ""
                then `Null
                else `String m.continuity_summary);
              ("continuity_compaction_cooldown_sec", `Int m.continuity_compaction_cooldown_sec);
              ("continuity_reflection_hold_s", `Float continuity_reflection_hold_s);
              ("last_continuity_update_ts", `Float m.last_continuity_update_ts);
              ("drift_enabled", `Bool m.drift_enabled);
              ("drift_min_turn_gap", `Int m.drift_min_turn_gap);
              ("drift_count_total", `Int m.drift_count_total);
              ("policy_mode", `String m.policy_mode);
              ("policy_action_budget", `String m.policy_action_budget);
              ("policy_reward_model_path",
                if String.trim m.policy_reward_model_path = ""
                then `Null
                else `String m.policy_reward_model_path);
              ("last_drift_turn", `Int m.last_drift_turn);
              ("last_drift_reason",
                if String.trim m.last_drift_reason = ""
                then `Null
                else `String m.last_drift_reason);
              ("memory_note_count", `Int memory_bank_summary.total_notes);
              ("memory_top_kind",
                match memory_bank_summary.top_kind with
                | Some kind -> `String kind
                | None -> `Null);
	              ("memory_recent_note",
	                match memory_recent_note with
	                | Some text -> `String text
	                | None -> `Null);
	              ("context", context_json);
	              ("skill_route", skill_route_json);
	              ("metrics_overview", metrics_summary_to_json metrics_overview);
	              ("memory_bank", memory_summary_to_json memory_bank_summary);
              ("storage_paths", `Assoc [
                ("meta", `String (keeper_meta_path ctx.config m.name));
                ("metrics", `String metrics_path);
                ("memory_bank", `String (keeper_memory_bank_path ctx.config m.name));
                ("policy", `String (keeper_policy_log_path ctx.config m.name));
                ("feedback", `String (keeper_feedback_log_path ctx.config m.name));
                ("dataset_export", `String (keeper_dataset_export_path ctx.config m.name));
                ("session_dir", `String (keeper_session_dir ctx.config m.trace_id));
                ("history", `String (keeper_history_path ctx.config m.trace_id));
              ]);
            ])
        ) keeper_names
      in
      let json = `Assoc [
        ("count", `Int (List.length keepers));
        ("keepers", `List keepers);
      ] in
      (true, Yojson.Safe.pretty_to_string json)

let maybe_promote_live_legacy_keeper config name =
  match read_meta config name with
  | Error _ | Ok None -> ()
  | Ok (Some meta) ->
      if is_resident_keeper config meta.name then ()
      else
        match parse_agent_status config ~agent_name:meta.agent_name with
        | `Assoc fields -> (
            let status =
              match List.assoc_opt "status" fields with
              | Some (`String value) -> String.lowercase_ascii value
              | _ -> "offline"
            in
            let agent_type =
              match List.assoc_opt "agent_type" fields with
              | Some (`String value) -> String.lowercase_ascii value
              | _ -> ""
            in
            if agent_type = "keeper" && List.mem status [ "active"; "busy"; "idle"; "listening" ] then
              ignore (register_resident_keeper_from_meta config meta))
        | _ -> ()

let ensure_resident_meta config (spec : resident_keeper_spec) =
  match read_meta config spec.persistent_name with
  | Ok (Some meta) -> Ok meta
  | Ok None -> (
      match meta_of_json spec.seed_meta with
      | Ok meta ->
          let meta =
            { meta with
              name = spec.persistent_name;
              agent_name = keeper_agent_name spec.persistent_name;
              updated_at = now_iso ();
            }
          in
          (match write_meta config meta with
          | Ok () -> Ok meta
          | Error msg -> Error msg)
      | Error msg -> Error msg)
  | Error msg -> Error msg

let handle_resident_keeper_up ctx args : tool_result =
  let ok, body = handle_keeper_up ctx args in
  if not ok then (ok, body)
  else
    let name = get_string args "name" "" in
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, "❌ resident keeper meta missing after up")
    | Ok (Some meta) ->
        (match register_resident_keeper_from_meta ctx.config meta with
        | Error e -> (false, "❌ " ^ e)
        | Ok () ->
            let json =
              try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
            in
            (true,
             Yojson.Safe.pretty_to_string
               (annotate_keeper_json ~runtime_class:"resident_keeper" ~desired:true
                  ~resident_registered:true json)))

let handle_resident_keeper_status ctx args : tool_result =
  let name = get_string args "name" "" in
  if validate_name name then maybe_promote_live_legacy_keeper ctx.config name;
  match read_resident_keeper ctx.config name with
  | Error e -> (false, "❌ " ^ e)
  | Ok None -> (false, Printf.sprintf "resident keeper not found: %s" name)
  | Ok (Some _spec) ->
      let ok, body = handle_keeper_status ctx args in
      if not ok then (ok, body)
      else
        let json =
          try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
        in
        (true,
         Yojson.Safe.pretty_to_string
           (annotate_keeper_json ~runtime_class:"resident_keeper" ~desired:true
              ~resident_registered:true json))

let handle_resident_keeper_msg ctx args : tool_result =
  let name = get_string args "name" "" in
  if validate_name name then maybe_promote_live_legacy_keeper ctx.config name;
  let ensure_result =
    match read_resident_keeper ctx.config name with
    | Ok (Some _) -> Ok ()
    | _ ->
        let ok, body = handle_resident_keeper_up ctx args in
        if ok then Ok () else Error body
  in
  match ensure_result with
  | Error err -> (false, err)
  | Ok _ ->
      let ok, body = handle_keeper_msg ctx args in
      if not ok then (ok, body)
      else begin
        (match read_meta ctx.config name with
        | Ok (Some meta) ->
            ignore (register_resident_keeper_from_meta ctx.config meta)
        | _ -> ());
        let json =
          try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
        in
        (true,
         Yojson.Safe.pretty_to_string
           (annotate_keeper_json ~runtime_class:"resident_keeper" ~desired:true
              ~resident_registered:true json))
      end

let handle_resident_keeper_down ctx args : tool_result =
  let name = get_string args "name" "" in
  if validate_name name then remove_resident_keeper ctx.config name;
  handle_keeper_down ctx args

let handle_resident_keeper_list ctx args : tool_result =
  let limit = max 0 (get_int args "limit" 50) in
  let detailed = get_bool args "detailed" false in
  let resident =
    resident_keeper_names ctx.config
    |> take limit
  in
  if not detailed then
    let json =
      `Assoc
        [
          ("count", `Int (List.length resident));
          ("keepers", `List (List.map (fun name -> `String name) resident));
        ]
    in
    (true, Yojson.Safe.pretty_to_string json)
  else
    let rows =
      resident
      |> List.filter_map (fun name ->
             let status_args =
               `Assoc
                 [
                   ("name", `String name);
                   ("tail_turns", `Int 3);
                   ("tail_messages", `Int 5);
                   ("tail_compactions", `Int 10);
                   ("tail_bytes", `Int 60000);
                 ]
             in
             let ok, body = handle_resident_keeper_status ctx status_args in
             if not ok then None
             else
               try Some (Yojson.Safe.from_string body)
               with Yojson.Json_error _ -> None)
    in
    let json =
      `Assoc
        [
          ("count", `Int (List.length rows));
          ("keepers", `List rows);
        ]
    in
    (true, Yojson.Safe.pretty_to_string json)

let handle_persistent_agent_list ctx args : tool_result =
  let limit = max 0 (get_int args "limit" 50) in
  let detailed = get_bool args "detailed" false in
  let names = persistent_agent_names ctx.config |> take limit in
  if not detailed then
    let json =
      `Assoc
        [
          ("count", `Int (List.length names));
          ("persistent_agents", `List (List.map (fun name -> `String name) names));
        ]
    in
    (true, Yojson.Safe.pretty_to_string json)
  else
    let rows =
      names
      |> List.filter_map (fun name ->
             let status_args =
               `Assoc
                 [
                   ("name", `String name);
                   ("tail_turns", `Int 3);
                   ("tail_messages", `Int 5);
                   ("tail_compactions", `Int 10);
                   ("tail_bytes", `Int 60000);
                 ]
             in
             let ok, body = handle_keeper_status ctx status_args in
             if not ok then None
             else
               try
                 let json = Yojson.Safe.from_string body in
                 Some
                   (annotate_keeper_json ~runtime_class:"persistent_agent"
                      ~desired:false ~resident_registered:false json)
               with Yojson.Json_error _ -> None)
    in
    let json =
      `Assoc
        [
          ("count", `Int (List.length rows));
          ("persistent_agents", `List rows);
        ]
    in
    (true, Yojson.Safe.pretty_to_string json)

let handle_persistent_agent_up ctx args : tool_result =
  let ok, body = handle_keeper_up ctx args in
  if not ok then (ok, body)
  else
    let json =
      try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
    in
    (true,
     Yojson.Safe.pretty_to_string
       (annotate_keeper_json ~runtime_class:"persistent_agent" ~desired:false
          ~resident_registered:false json))

let handle_persistent_agent_status ctx args : tool_result =
  let ok, body = handle_keeper_status ctx args in
  if not ok then (ok, body)
  else
    let name = get_string args "name" "" in
    let json =
      try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
    in
    (true,
     Yojson.Safe.pretty_to_string
       (annotate_keeper_json ~runtime_class:"persistent_agent" ~desired:false
          ~resident_registered:(validate_name name && is_resident_keeper ctx.config name)
          json))

let handle_persistent_agent_msg ctx args : tool_result =
  let ok, body = handle_keeper_msg ctx args in
  if not ok then (ok, body)
  else
    let json =
      try Yojson.Safe.from_string body with Yojson.Json_error _ -> `String body
    in
    (true,
     Yojson.Safe.pretty_to_string
       (annotate_keeper_json ~runtime_class:"persistent_agent" ~desired:false
          ~resident_registered:false json))

let handle_persistent_agent_down ctx args : tool_result =
  handle_keeper_down ctx args

let handle_persistent_agent_model_set ctx args : tool_result =
  handle_keeper_model_set ctx args

let handle_persistent_agent_create_from_persona ctx args : tool_result =
  handle_keeper_create_from_persona ctx args

(* Start keepalive fibers for existing keepers (best-effort). *)
type keeper_bootstrap_stats = {
  enabled: bool;
  scanned: int;
  started: int;
  stale: int;
}

let bootstrap_existing_keepers ctx : keeper_bootstrap_stats =
  if not Env_config.KeeperBootstrap.enabled then
    { enabled = false; scanned = 0; started = 0; stale = 0 }
  else
    let dir = keeper_dir ctx.config in
    (match Safe_ops.list_dir_safe dir with
    | Ok files ->
        files
        |> List.filter (fun f -> Filename.check_suffix f ".json")
        |> List.iter (fun f ->
               let name = Filename.remove_extension f in
               if validate_name name then maybe_promote_live_legacy_keeper ctx.config name)
    | Error _ -> ());
    let now_ts = Time_compat.now () in
    let proactive_warmup_sec = keeper_bootstrap_proactive_warmup_sec () in
    let stale_turn_sec =
      max 0.0 Env_config.KeeperBootstrap.stale_turn_seconds
    in
    let max_scan =
      max 0 Env_config.KeeperBootstrap.max_scan
    in
    let max_keepers = Env_config.KeeperBootstrap.max_active_keepers in
    let remaining_slots =
      ref
        (if max_keepers > 0 then
           max 0 (max_keepers - running_keepers ())
         else
           max_int)
    in
    let specs =
      list_resident_keepers ctx.config
      |> take max_scan
    in
    let (scanned, started, stale) =
      List.fold_left
        (fun (scanned_acc, started_acc, stale_acc) spec ->
          match ensure_resident_meta ctx.config spec with
          | Error _ -> (scanned_acc + 1, started_acc, stale_acc)
          | Ok m ->
              let stale_now =
                stale_turn_sec > 0.0
                && (m.last_turn_ts <= 0.0
                    || now_ts -. m.last_turn_ts >= stale_turn_sec)
              in
              let already_running = Hashtbl.mem keepalives m.name in
              let started_here =
                if stale_now then false
                else if already_running then false
                else if max_keepers > 0 && !remaining_slots <= 0 then false
                else (
                  start_keepalive ~proactive_warmup_sec ctx m;
                  if max_keepers > 0 then remaining_slots := !remaining_slots - 1;
                  true
                )
              in
              ( scanned_acc + 1,
                started_acc + (if started_here then 1 else 0),
                stale_acc + (if stale_now then 1 else 0) ))
        (0, 0, 0)
        specs
    in
    { enabled = true; scanned; started; stale }

let existing_keepalive_bootstrap_done = ref false

let start_existing_keepalives ctx =
  if !existing_keepalive_bootstrap_done then ()
  else begin
    existing_keepalive_bootstrap_done := true;
    try
      let stats = bootstrap_existing_keepers ctx in
      if keeper_debug then
        Printf.eprintf
          "[KEEPER-DEBUG] bootstrap_existing_keepers enabled=%b scanned=%d started=%d stale=%d\n%!"
          stats.enabled stats.scanned stats.started stats.stale
    with exn ->
      (* Retry bootstrap on next keeper tool call if this attempt failed. *)
      existing_keepalive_bootstrap_done := false;
      raise exn
  end

(* ================================================================ *)
(* Phase 4: Keeper Autonomy MCP Tool Handlers                      *)
(* ================================================================ *)

let handle_keeper_autonomy ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "read error: " ^ e)
    | Ok None -> (false, Printf.sprintf "keeper not found: %s" name)
    | Ok (Some m) ->
      let level_opt = get_string_opt args "level" in
      (match level_opt with
       | None ->
         (* GET mode: return current autonomy info *)
         let info = Printf.sprintf
           "Keeper: %s\nAutonomy Level: %s\nActive Goals: [%s]\nAutonomous Actions: %d\nLast Autonomous Action: %s"
           m.name
           (String.uppercase_ascii m.autonomy_level)
           (String.concat ", " m.active_goal_ids)
           m.autonomous_action_count
           (if m.last_autonomous_action_at = "" then "never" else m.last_autonomous_action_at)
         in
         (true, info)
       | Some level_str ->
         (* SET mode: validate and update autonomy level *)
         (match Keeper_autonomy.autonomy_level_of_string level_str with
          | None ->
            (false, Printf.sprintf "invalid autonomy level: %s (use L1_Reactive..L5_Independent)" level_str)
          | Some al ->
            let canonical = Keeper_autonomy.autonomy_level_to_string al in
            let updated = { m with autonomy_level = String.lowercase_ascii canonical } in
            (match write_meta ctx.config updated with
             | Error e -> (false, "write error: " ^ e)
             | Ok () ->
               (true, Printf.sprintf "Keeper %s autonomy level updated to %s" name canonical))))

let handle_keeper_goals ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "read error: " ^ e)
    | Ok None -> (false, Printf.sprintf "keeper not found: %s" name)
    | Ok (Some m) ->
      let action = get_string_opt args "action" in
      (match action with
       | None ->
         (* LIST mode: show active goals with details *)
         let goals = Goal_store.list_goals ctx.config () in
         let active =
           List.filter
             (fun (g : Goal_store.goal) -> List.mem g.id m.active_goal_ids)
             goals
         in
         if active = [] then
           (true, Printf.sprintf "Keeper %s has no active goals." name)
         else
           let lines =
             List.map
               (fun (g : Goal_store.goal) ->
                 Printf.sprintf "- [%s] %s (horizon:%s, priority:%d, status:%s)"
                   g.id g.title g.horizon g.priority g.status)
               active
           in
           (true, Printf.sprintf "Keeper %s goals (%d):\n%s"
              name (List.length active) (String.concat "\n" lines))
       | Some "link" ->
         let goal_id = get_string args "goal_id" "" in
         if goal_id = "" then
           (false, "goal_id is required for link action")
         else if List.mem goal_id m.active_goal_ids then
           (true, Printf.sprintf "Goal %s already linked to keeper %s" goal_id name)
         else begin
           (* Verify goal exists *)
           let goals = Goal_store.list_goals ctx.config () in
           match List.find_opt (fun (g : Goal_store.goal) -> g.id = goal_id) goals with
           | None -> (false, Printf.sprintf "Goal %s not found in goal_store" goal_id)
           | Some g ->
             let updated = { m with active_goal_ids = goal_id :: m.active_goal_ids } in
             (match write_meta ctx.config updated with
              | Error e -> (false, "write error: " ^ e)
              | Ok () ->
                (true, Printf.sprintf "Linked goal [%s] %s to keeper %s" g.id g.title name))
         end
       | Some "unlink" ->
         let goal_id = get_string args "goal_id" "" in
         if goal_id = "" then
           (false, "goal_id is required for unlink action")
         else if not (List.mem goal_id m.active_goal_ids) then
           (true, Printf.sprintf "Goal %s not linked to keeper %s" goal_id name)
         else
           let updated = { m with
             active_goal_ids = List.filter (fun gid -> gid <> goal_id) m.active_goal_ids
           } in
           (match write_meta ctx.config updated with
            | Error e -> (false, "write error: " ^ e)
            | Ok () ->
              (true, Printf.sprintf "Unlinked goal %s from keeper %s" goal_id name))
       | Some other ->
         (false, Printf.sprintf "unknown action: %s (use link | unlink)" other))

let handle_keeper_trajectory ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "read error: " ^ e)
    | Ok None -> (false, Printf.sprintf "keeper not found: %s" name)
    | Ok (Some m) ->
      let limit = get_int args "limit" 20 in
      let masc_root = Filename.concat ctx.config.base_path ".masc" in
      let entries =
        Trajectory.read_entries ~masc_root ~keeper_name:m.name ~trace_id:m.trace_id
      in
      let total = List.length entries in
      (* Take the last N entries (most recent) *)
      let recent =
        if total <= limit then entries
        else
          let drop = total - limit in
          List.filteri (fun i _e -> i >= drop) entries
      in
      if recent = [] then
        (true, Printf.sprintf "Keeper %s (trace: %s) has no trajectory entries." name m.trace_id)
      else
        let json_list = List.map Trajectory.entry_to_json recent in
        let json = `Assoc [
          ("keeper", `String name);
          ("trace_id", `String m.trace_id);
          ("generation", `Int m.generation);
          ("total_entries", `Int total);
          ("showing", `Int (List.length recent));
          ("entries", `List json_list);
        ] in
        (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_eval ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "read error: " ^ e)
    | Ok None -> (false, Printf.sprintf "keeper not found: %s" name)
    | Ok (Some m) ->
      let scenario_file = get_string_opt args "scenario_file" in
      let masc_root = Filename.concat ctx.config.base_path ".masc" in
      let entries =
        Trajectory.read_entries ~masc_root ~keeper_name:m.name ~trace_id:m.trace_id
      in
      if entries = [] then
        (true, Printf.sprintf "Keeper %s has no trajectory data to evaluate." name)
      else
        let total = List.length entries in
        (* Build a lightweight eval summary from trajectory *)
        let tool_names =
          List.map (fun (e : Trajectory.tool_call_entry) -> e.tool_name) entries
        in
        let unique_tools =
          List.sort_uniq String.compare tool_names
        in
        let tool_counts =
          List.map
            (fun tn ->
              let c = List.length (List.filter (fun n -> n = tn) tool_names) in
              (tn, c))
            unique_tools
        in
        let tool_stats =
          List.map
            (fun (tn, c) -> `Assoc [("tool", `String tn); ("count", `Int c)])
            (List.sort (fun (_, a) (_, b) -> compare b a) tool_counts)
        in
        (* Check if scenario file is provided for deeper eval *)
        let scenario_info =
          match scenario_file with
          | None -> `String "none (trajectory-only eval)"
          | Some sf ->
            (match Eval_harness.load_scenarios_from_file sf with
             | Error e -> `String (Printf.sprintf "failed to load: %s" e)
             | Ok scenarios ->
               `String (Printf.sprintf "loaded %d scenarios from %s"
                 (List.length scenarios) sf))
        in
        let json = `Assoc [
          ("keeper", `String name);
          ("trace_id", `String m.trace_id);
          ("generation", `Int m.generation);
          ("total_tool_calls", `Int total);
          ("unique_tools", `Int (List.length unique_tools));
          ("tool_distribution", `List tool_stats);
          ("scenario_file", scenario_info);
          ("autonomy_level", `String m.autonomy_level);
          ("autonomous_action_count", `Int m.autonomous_action_count);
        ] in
        (true, Yojson.Safe.pretty_to_string json)

let dispatch ctx ~name ~args : tool_result option =
  (* Resident keepers are bootstrapped lazily on tool use as a fallback.
     Server startup also calls bootstrap_existing_keepers for always-on presence. *)
  (try start_existing_keepalives ctx with exn ->
    Printf.eprintf "[keeper] start_existing_keepalives failed: %s\n%!" (Printexc.to_string exn));
  match name with
  | "masc_persona_list" -> Some (handle_persona_list ctx args)
  | "masc_keeper_create_from_persona" -> Some (handle_resident_keeper_create_from_persona ctx args)
  | "masc_keeper_up" -> Some (handle_resident_keeper_up ctx args)
  | "masc_keeper_status" -> Some (handle_resident_keeper_status ctx args)
  | "masc_keeper_msg" -> Some (handle_resident_keeper_msg ctx args)
  | "masc_keeper_model_set" -> Some (handle_resident_keeper_model_set ctx args)
  | "masc_keeper_policy_set" -> Some (handle_keeper_policy_set ctx args)
  | "masc_keeper_feedback_record" -> Some (handle_keeper_feedback_record ctx args)
  | "masc_keeper_dataset_export" -> Some (handle_keeper_dataset_export ctx args)
  | "masc_keeper_action_explain" -> Some (handle_keeper_action_explain ctx args)
  | "masc_keeper_eval_replay" -> Some (handle_keeper_eval_replay ctx args)
  | "masc_keeper_down" -> Some (handle_resident_keeper_down ctx args)
  | "masc_keeper_list" -> Some (handle_resident_keeper_list ctx args)
  | "masc_keeper_autonomy" -> Some (handle_keeper_autonomy ctx args)
  | "masc_keeper_goals" -> Some (handle_keeper_goals ctx args)
  | "masc_keeper_trajectory" -> Some (handle_keeper_trajectory ctx args)
  | "masc_keeper_eval" -> Some (handle_keeper_eval ctx args)
  | "masc_persistent_agent_create_from_persona" ->
      Some (handle_persistent_agent_create_from_persona ctx args)
  | "masc_persistent_agent_up" -> Some (handle_persistent_agent_up ctx args)
  | "masc_persistent_agent_status" -> Some (handle_persistent_agent_status ctx args)
  | "masc_persistent_agent_msg" -> Some (handle_persistent_agent_msg ctx args)
  | "masc_persistent_agent_model_set" -> Some (handle_persistent_agent_model_set ctx args)
  | "masc_persistent_agent_policy_set" -> Some (handle_keeper_policy_set ctx args)
  | "masc_persistent_agent_feedback_record" ->
      Some (handle_keeper_feedback_record ctx args)
  | "masc_persistent_agent_dataset_export" ->
      Some (handle_keeper_dataset_export ctx args)
  | "masc_persistent_agent_action_explain" ->
      Some (handle_keeper_action_explain ctx args)
  | "masc_persistent_agent_eval_replay" ->
      Some (handle_keeper_eval_replay ctx args)
  | "masc_persistent_agent_down" -> Some (handle_persistent_agent_down ctx args)
  | "masc_persistent_agent_list" -> Some (handle_persistent_agent_list ctx args)
  | "masc_persistent_agent_autonomy" -> Some (handle_keeper_autonomy ctx args)
  | "masc_persistent_agent_goals" -> Some (handle_keeper_goals ctx args)
  | "masc_persistent_agent_trajectory" -> Some (handle_keeper_trajectory ctx args)
  | "masc_persistent_agent_eval" -> Some (handle_keeper_eval ctx args)
  | _ -> None
