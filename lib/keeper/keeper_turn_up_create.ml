(** Keeper_turn_up_create -- create a new keeper from parsed arguments.

    Extracted from keeper_turn_up.ml (Ok None branch).
    Handles initial keeper meta construction, checkpoint creation,
    keepalive start, and response JSON generation. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_keepalive
open Keeper_execution
open Keeper_turn_up_args


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
    | Some goal -> normalize_goal_text goal
    | None ->
        p.profile_defaults.goal |> Option.value ~default:""
        |> normalize_goal_text
  in
  let autoboot_enabled =
    Dashboard_utils.first_some p.autoboot_enabled_opt p.profile_defaults.autoboot_enabled
    |> Option.value ~default:true
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
    resolve_sandbox_profile ~fallback:p.profile_defaults.sandbox_profile
  in
  let network_mode =
    resolve_network_mode
      ~sandbox_profile
      ~fallback:p.profile_defaults.network_mode
  in
  (* RFC vision-delegation §2.4: take the profile's policy if set, else the
     safe default (Inherit). *)
  let multimodal_policy =
    match p.profile_defaults.multimodal_policy with
    | Some policy -> policy
    | None -> Keeper_types_profile.default_multimodal_policy
  in
  let mention_targets =
    resolve_mention_targets
      ~mention_targets_opt:p.mention_targets_opt
      ~fallback_targets:p.profile_defaults.mention_targets
      ~name:p.name
  in
  if goal = "" then begin
    Log.Keeper.warn "create_keeper failed: goal is required (name=%s)" p.name;
    tool_result_error "goal is required when creating a keeper"
  end
  else match active_goal_ids_error with
  | Some msg -> tool_result_error msg
  | None ->
    match
      validate_sandbox_settings ~sandbox_profile ~network_mode ~allowed_paths
    with
    | Error err ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string LifecycleDispatchRejections)
          ~labels:[("keeper", p.name); ("event", "create_sandbox_validation")]
          ();
        Log.Keeper.warn "create_keeper failed sandbox validation for %s: %s"
          p.name err;
        tool_result_error err
    | Ok () ->
        match
          Keeper_sandbox_runtime.ensure_keeper_startup_preflight
            ~timeout_sec:
              (Env_config_sandbox.Shell_timeout.timeout_sec
                 ~bucket:Env_config_sandbox.Shell_timeout.Io
                 ())
            ~sandbox_profile
        with
        | Error err ->
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string LifecycleDispatchRejections)
              ~labels:[("keeper", p.name); ("event", "create_sandbox_preflight")]
              ();
            Log.Keeper.warn "create_keeper failed sandbox preflight for %s: %s"
              p.name err;
            tool_result_error err
        | Ok () ->
            let max_active_keepers =
              Keeper_runtime_resolved.bootstrap_max_active_keepers ()
            in
            let active_keepers = Keeper_registry.count_running () in
            if max_active_keepers > 0 && active_keepers >= max_active_keepers then begin
              Otel_metric_store.inc_counter
                Keeper_metrics.(to_string LifecycleDispatchRejections)
                ~labels:[("keeper", p.name); ("event", "create_max_active_reached")]
                ();
              Log.Keeper.warn
                "create_keeper failed: max active keepers reached (%d/%d) for name=%s"
                active_keepers max_active_keepers p.name;
              tool_result_error
                (Printf.sprintf
                   "keeper max active reached (%d/%d). Stop/remove a keeper or set MASC_KEEPER_MAX_ACTIVE_KEEPERS."
                   active_keepers
                   max_active_keepers)
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
                    (match p.profile_defaults.tool_access with
                     | Some tools -> normalize_tool_names tools
                     | None -> [])
              in
              let tool_denylist =
                resolve_tool_name_list
                  ~preferred:p.tool_denylist_opt
                  ~fallback:p.profile_defaults.tool_denylist
              in
              let instructions = Option.value ~default:"" p.instructions_opt in
              let (env_ratio_gate, env_message_gate, env_token_gate) =
                keeper_compaction_policy_from_env ()
              in
              let compaction_cooldown_sec =
                Option.value
                  ~default:(keeper_compaction_cooldown_sec ())
                  p.compaction_cooldown_sec_opt
                |> normalize_compaction_cooldown_sec
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
              let primary_max_context =
                match p.max_context_override_opt with
                | Some v -> v
                (* Boundary: Keeper consumes an opaque context budget, not a
                   provider/model identity. *)
                | None -> Runtime.default_max_context ()
              in
              Progress.Tracker.step tracker ~message:"Initializing session directory" ();
              let trace_id = generate_trace_id () in
              match Keeper_id.Trace_id.of_string trace_id with
              | Error err ->
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string LifecycleDispatchRejections)
                    ~labels:[("keeper", p.name); ("event", "create_invalid_trace_id")]
                    ();
                  Log.Keeper.error
                    "create_keeper failed: generated invalid trace_id for name=%s: %s"
                    p.name err;
                  Progress.stop_tracking task_id;
                  tool_result_error "internal keeper trace_id generation failed"
              | Ok trace_id_t ->
                  let base_dir = session_base_dir ctx.config in
                  (* Ensure full session dir tree, not just base_dir (issue #3019) *)
                  ignore (Keeper_fs.ensure_dir (Filename.concat base_dir trace_id));
                  let bundle_paths =
                    (* Surface masc-improver/sangsu sandbox boot
                       silent-failure (2026-05-05).  Keeper_fs.ensure_dir
                       raises on filesystem error; the previous [ignore]
                       discarded it.  Now we log + emit a Otel_metric_store
                       counter so the dashboard makes failure visible
                       without aborting keeper boot.  ensure_dir runs under an
                       Eio.Mutex and re-raises [Eio.Cancel.Cancelled], so route
                       through the RFC-0106 SSOT combinator: a bare catch-all
                       would swallow Cancelled and let a cancelled create keep
                       booting a keeper that should not exist. *)
                    Cancel_safe.protect
                      ~on_exn:(fun exn ->
                        Log.Keeper.error
                          "create_keeper sandbox bundle init raised: keeper=%s exn=%s"
                          p.name (Printexc.to_string exn);
                        Otel_metric_store.inc_counter
                          Keeper_metrics.(to_string LifecycleDispatchRejections)
                          ~labels:[("keeper", p.name);
                                   ("event", "sandbox_bundle_init_raised")]
                          ();
                        [])
                      (fun () ->
                        Keeper_alerting_path.ensure_sandbox_bundle_for_profile
                          ~config:ctx.config ~name:p.name ~sandbox_profile)
                  in
                  List.iter (fun bp ->
                    if not (Sys.file_exists bp) then begin
                      Log.Keeper.warn
                        "create_keeper sandbox bundle path missing post-init: keeper=%s path=%s"
                        p.name bp;
                      Otel_metric_store.inc_counter
                        Keeper_metrics.(to_string LifecycleDispatchRejections)
                        ~labels:[("keeper", p.name);
                                 ("event", "sandbox_bundle_missing_post_init")]
                        ()
                    end) bundle_paths;
                  let session =
                    Keeper_context_runtime.create_session ~session_id:trace_id
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
               (* RFC-0294: active_goals tuple dropped its horizon element. *)
               | Some { Goal_store.id; title; _ } ->
                   Some (id, title)
               | None -> None)
            active_goal_ids
        in
        let system_prompt =
          build_keeper_system_prompt
            ~goal
            ~instructions
            ~persona_extended
            ~keeper_name:p.name
            ~active_goals
            ()
      in
      let ctx0 =
        Keeper_context_runtime.create ~eio:true ~system_prompt
          ~max_tokens:primary_max_context
      in
      (* next_generation keys the per-(keeper, trace) counter by the trace_id
         string; episodes live under that same string dir (ensure_dir/of
         session_id above), so pass the raw [trace_id] string, not the typed
         [trace_id_t]. Reuse the reservation for metadata and checkpoint
         creation so they cannot diverge. *)
      let generation =
        Keeper_memory_os_io.next_generation ~keeper_id:p.name ~trace_id
      in
      let meta = {
        id = None;
        name = p.name;
        agent_name = Keeper_identity.keeper_agent_name p.name;
        persona = Some persona_extended;
        goal;
        instructions;
        sandbox_profile;
        sandbox_image = None;
        network_mode;
        multimodal_policy;
        allowed_paths;
        tool_access;
        tool_denylist;
        mention_targets;
        proactive = {
          enabled = proactive_enabled;
          idle_sec = proactive_idle_sec;
          cooldown_sec = proactive_cooldown_sec;
        };
        compaction = {
          profile = compaction_profile;
          mode = Keeper_config.keeper_compaction_mode_default ();
          ratio_gate = compaction_ratio_gate;
          message_gate = compaction_message_gate;
          token_gate = compaction_token_gate;
          cooldown_sec = compaction_cooldown_sec;
          (* Honour [Keeper_context_core.default_max_checkpoint_messages]
             instead of the 80 literal that used to ship here.  The
             literal shadowed the declared default (120) for 13/15
             keepers.  Per-keeper overrides set by the operator via the
             keeper JSON still win.  See #7859. *)
          max_checkpoint_messages =
            Keeper_context_core.default_max_checkpoint_messages;
          keep_recent_tool_results =
            Keeper_config.default_keep_recent_tool_results;
        };
        auto_handoff;
        handoff_threshold;
        handoff_cooldown_sec;
        created_at = now_iso ();
        updated_at = now_iso ();
        max_context_override = p.max_context_override_opt;
        active_goal_ids =
          active_goal_ids;
        paused = false;
        latched_reason = None;
        auto_resume_after_sec = None;
        autoboot_enabled;
        current_task_id = None;
        telemetry_feedback_enabled = p.profile_defaults.telemetry_feedback_enabled;
        telemetry_feedback_window_hours = p.profile_defaults.telemetry_feedback_window_hours;
        always_approve = p.profile_defaults.always_approve;
        runtime = {
          usage = {
            total_turns = 0;
            total_input_tokens = 0;
            total_output_tokens = 0;
            total_tokens = 0;
            total_cost_usd = 0.0;
            last_turn_ts = 0.0;
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
            consecutive_noop_count = 0;
          };
          generation;
          trace_id = trace_id_t;
          trace_history = [];
          last_handoff_ts = 0.0;
          last_autonomous_action_at = "";
          autonomous_action_count = 0;
          autonomous_turn_count = 0;
          autonomous_text_turn_count = 0;
          autonomous_tool_turn_count = 0;
          board_reactive_turn_count = 0;
          mention_reactive_turn_count = 0;
          noop_turn_count = 0;
          last_seen_message_seq = 0;
	          last_blocker = None;
	          last_runtime_attempt = None;
	          last_turn_tool_calls = [];
	        };
      keeper_id = Some (Keeper_id.Uid.generate ());
      oas_env = p.profile_defaults.oas_env;
      meta_version = 0;
      } in
      Progress.Tracker.step tracker ~message:"Saving initial checkpoint" ();
      let init_save_result =
        try
          Keeper_context_runtime.save_oas_checkpoint
            ~max_checkpoint_messages:meta.compaction.max_checkpoint_messages
            ~multimodal_policy:meta.multimodal_policy
            ~keeper_name:meta.name
            ~session
            ~agent_name:meta.agent_name
            ~ctx:ctx0
            ~generation
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            log_keeper_exn ~label:"save_oas_checkpoint (init) exception" exn;
            Error (Printexc.to_string exn)
      in
      match init_save_result with
      | Error e ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string CheckpointFailures)
          ~labels:[("keeper", p.name); ("site", Keeper_checkpoint_failure_operation.(to_label Create_initial_save))]
          ();
        Log.Keeper.error
          "create_keeper failed: initial checkpoint save error for name=%s: %s"
          p.name e;
        Progress.stop_tracking task_id;
        tool_result_error (Printf.sprintf "initial checkpoint save failed: %s" e)
      | Ok _ ->
      let runtime_assignment_result =
        match p.runtime_id_opt with
        | None -> Ok ()
        | Some runtime_id ->
          Runtime.set_runtime_id_for_keeper
            ~keeper_name:p.name
            ~runtime_id
            ()
      in
      (match runtime_assignment_result with
       | Error e ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string LifecycleDispatchRejections)
           ~labels:[("keeper", p.name); ("event", "create_runtime_assignment")]
           ();
         Log.Keeper.error
           "create_keeper failed: runtime assignment error for name=%s: %s"
           p.name
           e;
         Progress.stop_tracking task_id;
         tool_result_error e
       | Ok () ->
      Progress.Tracker.step tracker ~message:"Writing keeper metadata" ();
      match write_initial_meta ctx.config meta with
      | Error e ->
        Otel_metric_store.inc_counter Keeper_metrics.(to_string WriteMetaFailures)
          ~labels:[("keeper", p.name); ("phase", "create_keeper")] ();
        Log.Keeper.error "create_keeper failed: write_meta error for name=%s: %s" p.name e;
        Progress.stop_tracking task_id;
        tool_result_error e
      | Ok () ->
        Log.Keeper.debug "create_keeper: metadata written for name=%s trace_id=%s"
          p.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
        Progress.Tracker.step tracker ~message:"Starting keepalive loop" ();
        Log.Keeper.info "create_keeper: starting keepalive for name=%s" p.name;
        let launch_outcome = start_keepalive ctx meta in
        (* Apply per-persona shard configuration if present *)
        (match p.profile_defaults.shards with
         | Some (_ :: _ as shard_names) ->
             Log.Keeper.debug "create_keeper: applying shard config for name=%s shards=%d"
               p.name (List.length shard_names);
             Tool_shard.set_agent_shards p.name shard_names
         | Some [] | None -> ());
        (match launch_outcome with
         | Keepalive_started _ ->
        Progress.Tracker.complete tracker ~message:"Keeper created" ();
        Log.Keeper.info "create_keeper: completed for name=%s trace_id=%s" p.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
        let json = `Assoc [
          ("name", `String meta.name);
          ("agent_name", `String meta.agent_name);
          ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
          ("generation", `Int meta.runtime.generation);
          ("goal", `String meta.goal);
          ("instructions", `String meta.instructions);
          ("tool_access", Json_util.json_string_list meta.tool_access);
          ("tool_denylist",
            `List (List.map (fun value -> `String value) meta.tool_denylist));
          ("proactive_enabled", `Bool meta.proactive.enabled);
          ("proactive_idle_sec", `Int meta.proactive.idle_sec);
          ("proactive_cooldown_sec", `Int meta.proactive.cooldown_sec);
          ("compaction_profile", `String meta.compaction.profile);
          ("compaction_mode",
            `String (Keeper_config.compaction_mode_to_string meta.compaction.mode));
          ("compaction_ratio_gate", `Float meta.compaction.ratio_gate);
          ("compaction_message_gate", `Int meta.compaction.message_gate);
          ("compaction_token_gate", `Int meta.compaction.token_gate);
          ("max_context_override", Json_util.int_opt_to_json meta.max_context_override);
          ("auto_handoff", `Bool meta.auto_handoff);
          ("handoff_threshold", `Float meta.handoff_threshold);
          ("oas_env", `Assoc (List.map (fun (k, v) -> (k, `String v)) meta.oas_env));
        ] in
        tool_result_ok (Yojson.Safe.to_string json)
         | ( Keepalive_already_registered _
           | Keepalive_lifecycle_denied _
           | Keepalive_identity_unrepairable
           | Keepalive_spawn_slot_denied _
           | Keepalive_registration_rejected _
           | Keepalive_fiber_start_rejected _
           | Keepalive_lane_ownership_lost
           | Keepalive_fork_rejected _ ) as rejected ->
           Progress.stop_tracking task_id;
           tool_result_error
             (Printf.sprintf
                "keeper metadata was created but lane launch failed: %s"
                (start_keepalive_outcome_to_string rejected))))
