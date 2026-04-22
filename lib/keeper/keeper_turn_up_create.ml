(** Keeper_turn_up_create -- create a new keeper from parsed arguments.

    Extracted from keeper_turn_up.ml (Ok None branch).
    Handles initial keeper meta construction, checkpoint creation,
    keepalive start, and response JSON generation. *)

open Keeper_types
open Keeper_keepalive
open Keeper_execution
open Keeper_turn_up_args

(* #8605 family: warn-and-default parser for profile_defaults.tool_preset
   lifted to [Keeper_preset_defaults] so this file and
   [keeper_exec_persona] share one SSOT instead of two diverging copies
   (#8923). *)
let preset_of_defaults defaults =
  Keeper_preset_defaults.preset_of_defaults_warn
    ~call_site:"keeper_turn_up_create"
    ~defaults_tool_preset:defaults.tool_preset

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
  let autoboot_enabled =
    first_some p.autoboot_enabled_opt p.profile_defaults.autoboot_enabled
    |> Option.value ~default:true
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
  let sandbox_profile =
    resolve_sandbox_profile
      ~preferred:p.sandbox_profile_opt
      ~fallback:p.profile_defaults.sandbox_profile
  in
  let network_mode =
    resolve_network_mode
      ~sandbox_profile
      ~preferred:p.network_mode_opt
      ~fallback:p.profile_defaults.network_mode
  in
  let shared_memory_scope =
    resolve_shared_memory_scope
      ~preferred:p.shared_memory_scope_opt
      ~fallback:p.profile_defaults.shared_memory_scope
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
  let room_signal_prompt_enabled =
    match keeper_room_signal_prompt_enabled_override () with
    | Some value -> value
    | None ->
        Option.value
          ~default:default_room_signal_prompt_enabled
          p.profile_defaults.room_signal_prompt_enabled
  in
  if goal = "" then begin
    Log.Keeper.warn "create_keeper failed: goal is required (name=%s)" p.name;
    (false, "goal is required when creating a keeper")
  end
  else
    match
      validate_sandbox_settings
        ~config:ctx.config
        ~keeper_name:p.name
        ~sandbox_profile
        ~network_mode
        ~allowed_paths
    with
    | Error err ->
        Log.Keeper.warn "create_keeper failed sandbox validation for %s: %s"
          p.name err;
        (false, err)
    | Ok () ->
        match
          Keeper_sandbox_runtime.ensure_keeper_startup_preflight
            ~timeout_sec:15.0 ~sandbox_profile
        with
        | Error err ->
            Log.Keeper.warn "create_keeper failed sandbox preflight for %s: %s"
              p.name err;
            (false, err)
        | Ok () ->
            let max_active_keepers =
              Keeper_runtime_resolved.bootstrap_max_active_keepers ()
            in
            let active_keepers = Keeper_registry.count_running () in
            if max_active_keepers > 0 && active_keepers >= max_active_keepers then begin
              Log.Keeper.warn
                "create_keeper failed: max active keepers reached (%d/%d) for name=%s"
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
                    (Option.value ~default:default_proactive_enabled
                       p.profile_defaults.proactive_enabled)
                  p.proactive_enabled_opt
              in
              let proactive_idle_sec =
                Option.value
                  ~default:
                    (Option.value ~default:default_proactive_idle_sec
                       p.profile_defaults.proactive_idle_sec)
                  p.proactive_idle_sec_opt
                |> normalize_proactive_idle_sec
              in
              let proactive_cooldown_sec =
                Option.value
                  ~default:
                    (Option.value ~default:default_proactive_cooldown_sec
                       p.profile_defaults.proactive_cooldown_sec)
                  p.proactive_cooldown_sec_opt
                |> normalize_proactive_cooldown_sec
              in
              let auto_handoff = Option.value ~default:true p.auto_handoff_opt in
              let handoff_threshold =
                match p.handoff_threshold_opt with
                | Some threshold -> threshold
                | None ->
                    Runtime_params.get Governance_registry.keeper_handoff_threshold
              in
              let handoff_cooldown_sec =
                match p.handoff_cooldown_sec_opt with
                | Some cooldown_sec -> cooldown_sec
                | None ->
                    Runtime_params.get Governance_registry.keeper_handoff_cooldown_sec
              in
              let tool_access =
                match p.tool_access_opt with
                | Some access -> access
                | None ->
                    let tool_preset =
                      Option.value ~default:Research
                        (first_some p.tool_preset_opt
                           (preset_of_defaults p.profile_defaults))
                    in
                    let tool_also_allow =
                      resolve_tool_name_list
                        ~preferred:p.tool_also_allow_opt
                        ~fallback:p.profile_defaults.tool_also_allow
                    in
                    Preset { preset = tool_preset; also_allow = tool_also_allow }
              in
              let tool_denylist =
                resolve_tool_name_list
                  ~preferred:p.tool_denylist_opt
                  ~fallback:p.profile_defaults.tool_denylist
              in
              let social_model =
                p.profile_defaults.social_model
                |> Option.value ~default:default_social_model
                |> Keeper_social_model.normalize_social_model
              in
              let will =
                Option.value
                  ~default:
                    (Option.value ~default:default_keeper_will
                       p.profile_defaults.will)
                  p.will_opt
              in
              let needs =
                Option.value
                  ~default:
                    (Option.value ~default:default_keeper_needs
                       p.profile_defaults.needs)
                  p.needs_opt
              in
              let desires =
                Option.value
                  ~default:
                    (Option.value ~default:default_keeper_desires
                       p.profile_defaults.desires)
                  p.desires_opt
              in
              let (short_goal, mid_goal, long_goal) =
                resolve_goal_horizons
                  ~goal
                  ~short_goal_opt:
                    (first_some p.short_goal_opt p.profile_defaults.short_goal)
                  ~mid_goal_opt:(first_some p.mid_goal_opt p.profile_defaults.mid_goal)
                  ~long_goal_opt:
                    (first_some p.long_goal_opt p.profile_defaults.long_goal)
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
              let
                ( compaction_profile,
                  compaction_ratio_gate,
                  compaction_message_gate,
                  compaction_token_gate )
                =
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
              let cascade_models =
                Cascade_runtime.models_of_cascade_name
                  Keeper_config.default_cascade_name
              in
              ignore
                (Cascade_runtime.refresh_local_discovery_if_possible
                   cascade_models);
              let primary_max_context =
                match p.max_context_override_opt with
                | Some v -> v
                | None ->
                    let resolved =
                      Cascade_runtime.resolve_max_cascade_context cascade_models
                    in
                    Cascade_runtime.clamp_context_for_pure_local_labels
                      ~labels:cascade_models ~max_context:resolved
              in
              Progress.Tracker.step tracker ~message:"Initializing session directory" ();
              let trace_id = generate_trace_id () in
              match Keeper_id.Trace_id.of_string trace_id with
              | Error err ->
                  Log.Keeper.error
                    "create_keeper failed: generated invalid trace_id for name=%s: %s"
                    p.name err;
                  Progress.stop_tracking task_id;
                  (false, "internal keeper trace_id generation failed")
              | Ok trace_id_t ->
                  let base_dir = session_base_dir ctx.config in
                  (* Ensure full session dir tree, not just base_dir (issue #3019) *)
                  ignore (Keeper_fs.ensure_dir (Filename.concat base_dir trace_id));
                  ignore
                    (Keeper_alerting_path.ensure_playground_bundle ~config:ctx.config
                       ~name:p.name);
                  let session =
                    Keeper_exec_context.create_session ~session_id:trace_id
                      ~base_dir
                  in
        let persona_extended =
          Keeper_types_profile.resolved_persona_name ~keeper_name:p.name
            p.profile_defaults
          |> Keeper_types_profile.load_persona_extended
          |> Option.value ~default:""
        in
        let system_prompt =
          build_keeper_system_prompt
            ~goal
            ~short_goal
            ~mid_goal
            ~long_goal
            ~will
            ~needs
            ~desires
            ~instructions
            ~persona_extended
            ~keeper_name:p.name
            ~allowed_orgs:(Keeper_tool_policy.git_clone_allowed_orgs ())
            ~denied_repos:(Keeper_tool_policy.git_clone_denied_repos ())
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

        social_model;
        cascade_name = (match p.profile_defaults.cascade_name with
          | Some name -> name
          | None -> Keeper_config.default_cascade_name);
        (* Empty = "use cascade_name". Injecting any default here would silently
           override the keeper's declared cascade_name in oas_worker_named. *)
        models = Option.value ~default:[] p.profile_defaults.models;
        will;
        needs;
        desires;
        instructions;
        policy_voice_enabled;
        execution_scope;
        sandbox_profile;
        network_mode;
        shared_memory_scope;
        allowed_paths;
        tool_access;
        tool_denylist;
        voice_enabled;
        voice_channel;
        voice_agent_id;
        mention_targets;
        room_signal_prompt_enabled;
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
          (* Honour [Keeper_context_core.default_max_checkpoint_messages]
             instead of the 80 literal that used to ship here.  The
             literal shadowed the declared default (120) for 13/15
             keepers.  Per-keeper overrides set by the operator via the
             keeper JSON still win.  See #7859. *)
          max_checkpoint_messages =
            Keeper_context_core.default_max_checkpoint_messages;
        };
        auto_handoff;
        handoff_threshold;
        handoff_cooldown_sec;
        created_at = now_iso ();
        updated_at = now_iso ();
        max_context_override = p.max_context_override_opt;
        continuity_summary = "";
        active_goal_ids = [];
        paused = false;
        autoboot_enabled;
        current_task_id = None;
        work_discovery_enabled = p.profile_defaults.work_discovery_enabled;
        work_discovery_sources = p.profile_defaults.work_discovery_sources;
        work_discovery_interval_sec = p.profile_defaults.work_discovery_interval_sec;
        work_discovery_guidance = p.profile_defaults.work_discovery_guidance;
        telemetry_feedback_enabled = p.profile_defaults.telemetry_feedback_enabled;
        telemetry_feedback_window_hours = p.profile_defaults.telemetry_feedback_window_hours;
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
            visible_count_total = 0;
            last_visible_ts = 0.0;
            last_outcome = Proactive_never_started;
            last_reason = "";
            last_preview = "";
            last_work_discovery_ts = 0.0;
            work_discovery_count = 0;
            consecutive_noop_count = 0;
          };
          generation = 0;
          trace_id = trace_id_t;
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
          consecutive_noop_count = 0;
          last_speech_act = "";
          last_social_transition_reason = "";
          last_active_desire = "";
          last_current_intention = "";
          last_blocker = "";
          last_blocker_class = None;
          last_need = "";
        };
      } in
      Progress.Tracker.step tracker ~message:"Saving initial checkpoint" ();
      let init_save_result =
        try
          Keeper_exec_context.save_oas_checkpoint
            ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
            ~session
            ~agent_name:meta.agent_name
            ~model:(Keeper_exec_context.checkpoint_model_of_meta meta)
            ~ctx:ctx0
            ~generation:0
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            log_keeper_exn ~label:"save_oas_checkpoint (init) exception" exn;
            Error (Printexc.to_string exn)
      in
      match init_save_result with
      | Error e ->
        Log.Keeper.error
          "create_keeper failed: initial checkpoint save error for name=%s: %s"
          p.name e;
        Progress.stop_tracking task_id;
        (false, Printf.sprintf "initial checkpoint save failed: %s" e)
      | Ok _ ->
      Progress.Tracker.step tracker ~message:"Writing keeper metadata" ();
      match write_meta ctx.config meta with
      | Error e ->
        Log.Keeper.error "create_keeper failed: write_meta error for name=%s: %s" p.name e;
        Progress.stop_tracking task_id;
        (false, e)
      | Ok () ->
        Log.Keeper.debug "create_keeper: metadata written for name=%s trace_id=%s"
          p.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
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
        Log.Keeper.info "create_keeper: completed for name=%s trace_id=%s" p.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
        let json = `Assoc [
          ("name", `String meta.name);
          ("agent_name", `String meta.agent_name);
          ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
          ("generation", `Int meta.runtime.generation);
          ("goal", `String meta.goal);
          ("short_goal", `String meta.short_goal);
          ("mid_goal", `String meta.mid_goal);
          ("long_goal", `String meta.long_goal);
          ("will", `String meta.will);
          ("needs", `String meta.needs);
          ("desires", `String meta.desires);
          ("instructions", `String meta.instructions);
          ("cascade_name", `String meta.cascade_name);
          ("voice_enabled", `Bool meta.voice_enabled);
          ("voice_channel", `String meta.voice_channel);
          ("voice_agent_id", `String meta.voice_agent_id);
          ("social_model", `String meta.social_model);
          ("tool_access", tool_access_to_json meta.tool_access);
          ("tool_preset",
            match tool_access_preset meta.tool_access with
            | Some preset -> `String (tool_preset_to_string preset)
            | None -> `Null);
          ("tool_also_allow",
            `List
              (List.map (fun value -> `String value)
                 (tool_access_also_allowlist meta.tool_access)));
          ("tool_denylist",
            `List (List.map (fun value -> `String value) meta.tool_denylist));
          ("proactive_enabled", `Bool meta.proactive.enabled);
          ("proactive_idle_sec", `Int meta.proactive.idle_sec);
          ("proactive_cooldown_sec", `Int meta.proactive.cooldown_sec);
          ("compaction_profile", `String meta.compaction.profile);
          ("compaction_ratio_gate", `Float meta.compaction.ratio_gate);
          ("compaction_message_gate", `Int meta.compaction.message_gate);
          ("compaction_token_gate", `Int meta.compaction.token_gate);
          ("max_context_override", Json_util.int_opt_to_json meta.max_context_override);
          ("auto_handoff", `Bool meta.auto_handoff);
          ("handoff_threshold", `Float meta.handoff_threshold);
        ] in
        (true, Yojson.Safe.to_string json)
