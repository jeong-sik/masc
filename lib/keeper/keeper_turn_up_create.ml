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

(* #9749: bootstrap can race a heartbeat/supervisor meta write after
   crash recovery. Retry on CAS conflict while keeping heartbeat-owned
   cursors from disk. *)
let write_initial_meta config meta =
  write_meta_with_merge
    ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
    config meta

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
  let active_goal_ids =
    match p.active_goal_ids_opt with
    | Some ids -> ids
    | None -> Option.value ~default:[] p.profile_defaults.active_goal_ids
  in
  let active_goal_ids_error =
    match p.active_goal_ids_opt with
    | None -> None
    | Some _ ->
        let missing =
          List.filter
            (fun goal_id -> Option.is_none (Goal_store.get_goal ctx.config ~goal_id))
            active_goal_ids
        in
        if missing = [] then None
        else
          Some
            (Printf.sprintf "unknown active_goal_ids: %s"
               (String.concat ", " missing))
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
  else match active_goal_ids_error with
  | Some msg -> (false, msg)
  | None ->
    match
      validate_sandbox_settings
        ~config:ctx.config
        ~keeper_name:p.name
        ~github_identity:p.profile_defaults.github_identity
        ~sandbox_profile
        ~network_mode
        ~allowed_paths
    with
    | Error err ->
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
          ~labels:[("keeper", p.name); ("event", "create_sandbox_validation")]
          ();
        Log.Keeper.warn "create_keeper failed sandbox validation for %s: %s"
          p.name err;
        (false, err)
    | Ok () ->
        match
          Keeper_sandbox_runtime.ensure_keeper_startup_preflight
            ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Turn_up ()) ~sandbox_profile
        with
        | Error err ->
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
              ~labels:[("keeper", p.name); ("event", "create_sandbox_preflight")]
              ();
            Log.Keeper.warn "create_keeper failed sandbox preflight for %s: %s"
              p.name err;
            (false, err)
        | Ok () ->
            let max_active_keepers =
              Keeper_runtime_resolved.bootstrap_max_active_keepers ()
            in
            let active_keepers = Keeper_registry.count_running () in
            if max_active_keepers > 0 && active_keepers >= max_active_keepers then begin
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
                ~labels:[("keeper", p.name); ("event", "create_max_active_reached")]
                ();
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
              let room_signal_prompt_enabled =
                match keeper_room_signal_prompt_enabled_override () with
                | Some value -> value
                | None ->
                    Option.value
                      ~default:
                        (tool_access_default_room_signal_prompt_enabled
                           ~default:default_room_signal_prompt_enabled
                           tool_access)
                      p.profile_defaults.room_signal_prompt_enabled
              in
              let tool_denylist =
                resolve_tool_name_list
                  ~preferred:p.tool_denylist_opt
                  ~fallback:p.profile_defaults.tool_denylist
              in
              let social_model =
                p.profile_defaults.social_model
                |> Option.value ~default:(Env_config_core.keeper_social_model ())
                |> Keeper_social_model.normalize_social_model
              in
              let will =
                Option.value
                  ~default:
                    (Option.value ~default:(Env_config_core.keeper_will ())
                       p.profile_defaults.will)
                  p.will_opt
              in
              let needs =
                Option.value
                  ~default:
                    (Option.value ~default:(Env_config_core.keeper_needs ())
                       p.profile_defaults.needs)
                  p.needs_opt
              in
              let desires =
                Option.value
                  ~default:
                    (Option.value ~default:(Env_config_core.keeper_desires ())
                       p.profile_defaults.desires)
                  p.desires_opt
              in
              (* Layer 1 boundary check: warn (not truncate) when persona
                 fields exceed the prompt-render cap.  Disk preserves the
                 raw value; only prompt rendering applies the cap.  This
                 surfaces the situation at create time so the operator can
                 decide whether to shorten the source. *)
              let warn_personality_cap field value =
                let len = String.length value in
                if len > Keeper_config.prompt_render_max_bytes then
                  Log.Keeper.warn
                    "create_keeper personality.%s for %s exceeds prompt cap \
                     (%d bytes > %d). Stored as-is; truncated only at prompt \
                     rendering."
                    field p.name len Keeper_config.prompt_render_max_bytes
              in
              warn_personality_cap "will" will;
              warn_personality_cap "needs" needs;
              warn_personality_cap "desires" desires;
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
                  (Keeper_cascade_profile.Runtime_name
                     (Keeper_config.default_cascade_name ()))
              in
              (match
                 Keeper_turn_helpers.ensure_local_discovery_ready
                   cascade_models
               with
               | Ok () -> ()
               | Error msg ->
                   Log.Keeper.warn
                     "create_keeper local discovery refresh incomplete for \
                      name=%s: %s"
                     p.name
                     msg;
                   Prometheus.inc_counter
                     Keeper_metrics.metric_keeper_local_discovery_failures
                     ~labels:
                       [
                         ("keeper", p.name);
                         ("site", "create_local_discovery_refresh");
                       ]
                     ());
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
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
                    ~labels:[("keeper", p.name); ("event", "create_invalid_trace_id")]
                    ();
                  Log.Keeper.error
                    "create_keeper failed: generated invalid trace_id for name=%s: %s"
                    p.name err;
                  Progress.stop_tracking task_id;
                  (false, "internal keeper trace_id generation failed")
              | Ok trace_id_t ->
                  let base_dir = session_base_dir ctx.config in
                  (* Ensure full session dir tree, not just base_dir (issue #3019) *)
                  ignore (Keeper_fs.ensure_dir (Filename.concat base_dir trace_id));
                  let bundle_paths =
                    try
                      Keeper_alerting_path.ensure_sandbox_bundle_for_profile
                        ~config:ctx.config ~name:p.name
                        ~sandbox_profile
                    with exn ->
                      (* Surface masc-improver/sangsu sandbox boot
                         silent-failure (2026-05-05).  Keeper_fs.ensure_dir
                         raises on filesystem error; the previous [ignore]
                         discarded it.  Now we log + emit a Prometheus
                         counter so the dashboard makes failure visible
                         without aborting keeper boot. *)
                      Log.Keeper.error
                        "create_keeper sandbox bundle init raised: keeper=%s exn=%s"
                        p.name (Printexc.to_string exn);
                      Prometheus.inc_counter
                        Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
                        ~labels:[("keeper", p.name);
                                 ("event", "sandbox_bundle_init_raised")]
                        ();
                      []
                  in
                  List.iter (fun bp ->
                    if not (Sys.file_exists bp) then begin
                      Log.Keeper.warn
                        "create_keeper sandbox bundle path missing post-init: keeper=%s path=%s"
                        p.name bp;
                      Prometheus.inc_counter
                        Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
                        ~labels:[("keeper", p.name);
                                 ("event", "sandbox_bundle_missing_post_init")]
                        ()
                    end) bundle_paths;
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
        let active_goals =
          List.filter_map
            (fun goal_id ->
               match Goal_store.get_goal ctx.config ~goal_id with
               | Some { Goal_store.id; title; horizon } ->
                   let horizon_str =
                     match horizon with
                     | Goal_store.Short -> "short"
                     | Goal_store.Mid -> "mid"
                     | Goal_store.Long -> "long"
                   in
                   Some (id, title, horizon_str)
               | None -> None)
            active_goal_ids
        in
        let git_clone_allowed_orgs =
          Keeper_tool_policy.git_clone_allowed_orgs ()
        in
        let git_clone_denied_repos =
          Keeper_tool_policy.git_clone_denied_repos ()
        in
        let git_clone_policy_loaded =
          Option.is_some git_clone_allowed_orgs
          && Option.is_some git_clone_denied_repos
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
            ~allowed_orgs:(Option.value git_clone_allowed_orgs ~default:[])
            ~denied_repos:(Option.value git_clone_denied_repos ~default:[])
            ~git_clone_policy_loaded
            ~active_goals
            ()
      in
      let ctx0 = Keeper_exec_context.create ~system_prompt ~max_tokens:primary_max_context in
      let meta = {
        id = None;
        name = p.name;
        agent_name = keeper_agent_name p.name;
        goal;
        short_goal;
        mid_goal;
        long_goal;

        social_model;
        cascade_ref =
          Some Cascade_ref.{
            group = (match p.profile_defaults.cascade_name with
              | Some name -> name
              | None -> (Keeper_config.default_cascade_name ()));
            item = None;
          };
        (* RFC-0041 (post-step-4): cascade_ref is the SSOT; the legacy
           cascade_name field was removed from keeper_meta. *)
        models = Option.value ~default:[] p.profile_defaults.models;
        will;
        needs;
        desires;
        instructions;
        policy_voice_enabled;
        sandbox_profile;
        sandbox_image = None;
        network_mode;
        allowed_paths;
        tool_access;
        tool_preset_source = p.profile_defaults.tool_preset_source;
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
        active_goal_ids =
          active_goal_ids;
        paused = false;
        auto_resume_after_sec = None;
        autoboot_enabled;
        current_task_id = None;
        work_discovery_enabled = p.profile_defaults.work_discovery_enabled;
        work_discovery_sources = p.profile_defaults.work_discovery_sources;
        work_discovery_interval_sec = p.profile_defaults.work_discovery_interval_sec;
        work_discovery_guidance = p.profile_defaults.work_discovery_guidance;
        telemetry_feedback_enabled = p.profile_defaults.telemetry_feedback_enabled;
        telemetry_feedback_window_hours = p.profile_defaults.telemetry_feedback_window_hours;
        per_provider_timeout_s = p.profile_defaults.per_provider_timeout;
        always_approve = p.profile_defaults.always_approve;
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
            last_decision = compaction_runtime_decision_of_string "initialized";
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
          last_blocker = None;
          last_need = "";
        };
      keeper_id = None;
      oas_env = p.profile_defaults.oas_env;
      meta_version = 0;
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
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_checkpoint_failures
          ~labels:[("keeper", p.name); ("site", Checkpoint_failure_operation.(to_label Create_initial_save))]
          ();
        Log.Keeper.error
          "create_keeper failed: initial checkpoint save error for name=%s: %s"
          p.name e;
        Progress.stop_tracking task_id;
        (false, Printf.sprintf "initial checkpoint save failed: %s" e)
      | Ok _ ->
      Progress.Tracker.step tracker ~message:"Writing keeper metadata" ();
      match write_initial_meta ctx.config meta with
      | Error e ->
        Prometheus.inc_counter Keeper_metrics.metric_keeper_write_meta_failures
          ~labels:[("keeper", p.name); ("phase", "create_keeper")] ();
        Log.Keeper.error "create_keeper failed: write_meta error for name=%s: %s" p.name e;
        Progress.stop_tracking task_id;
        (false, e)
      | Ok () ->
        Log.Keeper.debug "create_keeper: metadata written for name=%s trace_id=%s"
          p.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
        (* Auto-generate credential file if missing (#A10) *)
        let agent_name = keeper_agent_name p.name in
        (match Auth.ensure_keeper_credential ctx.config.base_path ~agent_name with
         | Ok _ ->
             Log.Keeper.debug "create_keeper: credential ensured for %s" agent_name
         | Error err ->
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
               ~labels:[("keeper", agent_name); ("event", "create_credential_ensure")]
               ();
             Log.Keeper.warn "create_keeper: credential ensure failed for %s: %s"
               agent_name (Masc_domain.show_masc_error err));
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
          ("cascade_name", `String (cascade_name_of_meta meta));
          ("voice_enabled", `Bool meta.voice_enabled);
          ("voice_channel", `String meta.voice_channel);
          ("voice_agent_id", `String meta.voice_agent_id);
          ("social_model", `String meta.social_model);
          ("tool_access", tool_access_to_json meta.tool_access);
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
          ("oas_env", `Assoc (List.map (fun (k, v) -> (k, `String v)) meta.oas_env));
        ] in
        (true, Yojson.Safe.to_string json)
