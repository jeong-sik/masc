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


let write_initial_meta ~intake_token config meta =
  match
    Keeper_owner_registry.create_meta
      ~intake_token
      ~base_path:config.Workspace.base_path
      meta
  with
  | Ok (Some _) -> Ok ()
  | Ok None -> Error "Keeper owner removed metadata during create"
  | Error error -> Error (Keeper_owner_registry.command_error_to_string error)

let with_config_warnings warnings result =
  match warnings with
  | [] -> result
  | warnings ->
    Tool_result.with_metadata
      (`Assoc
         [ ( "keeper_config_warnings"
           , `List
               (List.map
                  Keeper_turn_up_config_persistence.warning_to_yojson
                  warnings) )
         ])
      result

let create_keeper ~expected_config_revision (ctx : _ context)
    (p : parsed_args) : tool_result =
  Log.Keeper.info "create_keeper: starting for name=%s" p.name;
  let task_id = Printf.sprintf "keeper_create_%s" p.name in
  let tracker = Progress.start_tracking ~task_id ~total_steps:7 () in
  Progress.Tracker.step tracker ~message:"Resolving keeper configuration" ();
  let autoboot_enabled =
    Dashboard_utils.first_some p.autoboot_enabled_opt p.profile_defaults.autoboot_enabled
    |> Option.value ~default:true
  in
  (* Two ways to have no usable profile, kept apart because they send the
     operator to different places: nobody named one, or someone named [local]
     while the playground is gated off. Folding the first into the second is
     what produced "local is disabled" for callers who never wrote "local". *)
  let sandbox_profile_res =
    match
      resolve_sandbox_profile
        ?requested:p.sandbox_profile_opt
        ~fallback:p.profile_defaults.sandbox_profile
        ()
    with
    | None ->
      Error
        (Keeper_meta_contract.missing_required_sandbox_profile_error
           ~keeper_name:p.name
           p.profile_defaults)
    | Some sandbox_profile -> Ok sandbox_profile
  in
    match sandbox_profile_res with
    | Error err ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string LifecycleDispatchRejections)
          ~labels:[("keeper", p.name); ("event", "create_sandbox_validation")]
          ();
        Log.Keeper.warn "create_keeper failed sandbox validation for %s: %s"
          p.name err;
        tool_result_error ~class_:Tool_result.Policy_rejection err
    | Ok sandbox_profile ->
            let network_mode =
              resolve_network_mode
                ~sandbox_profile
                ~fallback:p.profile_defaults.network_mode
            in
            let mention_targets =
              resolve_mention_targets
                ~mention_targets_opt:p.mention_targets_opt
                ~fallback_targets:p.profile_defaults.mention_targets
                ~name:p.name
            in
            let proactive_enabled =
                Option.value
                  ~default:
                    (Option.value ~default:default_proactive_enabled
                       p.profile_defaults.proactive_enabled)
                  p.proactive_enabled_opt
            in
              let instructions = Option.value ~default:"" p.instructions_opt in
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
                  tool_result_error ~class_:Tool_result.Runtime_failure "internal keeper trace_id generation failed"
              | Ok trace_id_t ->
                  (match
                     Keeper_shutdown_intake_fence.run_durable_intake_observing
                       ~base_path:ctx.config.base_path
                       ~keeper_name:p.name
                       (fun intake_token ->
      let meta : Keeper_meta_contract.keeper_meta = {
        id = None;
        name = p.name;
        instructions;
        sandbox_profile;
        sandbox_image = None;
        network_mode;
        mention_targets;
        proactive = {
          enabled = proactive_enabled;
        };
        created_at = now_iso ();
        updated_at = now_iso ();
        max_context_override = p.max_context_override_opt;
        paused = false;
        latched_reason = None;
        autoboot_enabled;
        current_task_id = None;
        telemetry_feedback_enabled = p.profile_defaults.telemetry_feedback_enabled;
        telemetry_feedback_window_hours = p.profile_defaults.telemetry_feedback_window_hours;
        always_allow = p.profile_defaults.always_allow;
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
            last_usage_reported_at = None;
            last_latency_ms = 0;
          };
          proactive_rt = {
            count_total = 0;
            last_ts = 0.0;
            visible_count_total = 0;
            last_visible_ts = 0.0;
            last_outcome = Proactive_never_started;
            last_reason = "";
            last_preview = "";
          };
          trace_id = trace_id_t;
          trace_history = [];
          last_handoff_ts = 0.0;
          message_scope_ack_id = None;
	          last_runtime_attempt = None;
	        };
      keeper_id = Some (Keeper_id.Uid.generate ());
      agent_core_env = p.profile_defaults.agent_core_env;
      } in
      let system_prompt =
        Keeper_run_context.build_base_system_prompt
          ~config:ctx.config
          ~profile_defaults:p.profile_defaults
          ~meta
      in
      let ctx0 =
        Keeper_context_runtime.create ~eio:true ~system_prompt
      in
      Progress.Tracker.step tracker ~message:"Writing declarative keeper configuration" ();
      (match
         Keeper_turn_up_config_persistence.persist_with_publication
           ~expected_revision:expected_config_revision
           ~config:ctx.config
           ~parsed:p
           ~meta
           ~publish:(fun runtime_transaction _outcome ->
             let base_dir = session_base_dir ctx.config in
             ignore (Keeper_fs.ensure_dir (Filename.concat base_dir trace_id));
             let bundle_paths =
               Cancel_safe.protect
                 ~on_exn:(fun exn ->
                   Log.Keeper.error
                     "create_keeper sandbox bundle init raised: keeper=%s exn=%s"
                     p.name
                     (Printexc.to_string exn);
                   Otel_metric_store.inc_counter
                     Keeper_metrics.(to_string LifecycleDispatchRejections)
                     ~labels:
                       [ ("keeper", p.name); ("event", "sandbox_bundle_init_raised") ]
                     ();
                   [])
                 (fun () ->
                   Keeper_alerting_path.ensure_sandbox_bundle_for_profile
                     ~config:ctx.config
                     ~name:p.name
                     ~sandbox_profile)
             in
             List.iter
               (fun path ->
                 if not (Sys.file_exists path)
                 then (
                   Log.Keeper.warn
                     "create_keeper sandbox bundle path missing post-init: keeper=%s path=%s"
                     p.name
                     path;
                   Otel_metric_store.inc_counter
                     Keeper_metrics.(to_string LifecycleDispatchRejections)
                     ~labels:
                       [ ("keeper", p.name)
                       ; ("event", "sandbox_bundle_missing_post_init")
                       ]
                     ()))
               bundle_paths;
             let session =
               Keeper_context_runtime.create_session ~session_id:trace_id ~base_dir
             in
             Progress.Tracker.step tracker ~message:"Saving initial checkpoint" ();
             let checkpoint_result =
               try
                 Keeper_context_runtime.save_agent_core_checkpoint
                   ~runtime_id:(Keeper_meta_contract.runtime_id_of_meta meta)
                   ~keeper_name:meta.name
                   ~session
                   ~agent_name:meta.name
                   ~ctx:ctx0
                 |> Result.map_error (fun error ->
                   Keeper_context_core.checkpoint_write_error_to_string
                     ~persistence_error_to_string:Fun.id
                     error)
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn ->
                 log_keeper_exn
                   ~label:"save_agent_core_checkpoint (init) exception"
                   exn;
                 Error (Printexc.to_string exn)
             in
             match checkpoint_result with
             | Error detail ->
               Keeper_turn_up_config_persistence.Rollback
                 (Error (`Checkpoint detail))
             | Ok _ ->
               Progress.Tracker.step tracker ~message:"Writing keeper metadata" ();
               (match
                  Runtime.commit_keeper_assignment runtime_transaction
                    ~runtime_id:p.runtime_id_opt
                with
                | Error error ->
                  Keeper_turn_up_config_persistence.Rollback
                    (Error (`Runtime_assignment error))
                | Ok runtime_write ->
                  let runtime_warnings =
                    Keeper_turn_up_config_persistence
                    .warnings_of_runtime_assignment_write runtime_write
                  in
                  (match write_initial_meta ~intake_token ctx.config meta with
                   | Ok () ->
                     Keeper_turn_up_config_persistence.Commit_with_warnings
                       (Ok (), runtime_warnings)
                   | Error error ->
                     Keeper_turn_up_config_persistence.Rollback
                       (Error (`Metadata error)))))
           ()
       with
       | Error e ->
         let detail = Keeper_turn_up_config_persistence.error_to_string e in
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string LifecycleDispatchRejections)
           ~labels:[("keeper", p.name); ("event", "create_config_persistence")]
           ();
         Log.Keeper.error
           "create_keeper failed: declarative config write error for name=%s: %s"
           p.name
           detail;
         Progress.stop_tracking task_id;
         tool_result_error ~class_:Tool_result.Runtime_failure
           (Printf.sprintf "declarative keeper config write failed: %s" detail)
       | Ok { value = Error (`Checkpoint detail); warnings } ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string CheckpointFailures)
           ~labels:
             [ ("keeper", p.name)
             ; ( "site"
               , Keeper_checkpoint_failure_operation.(to_label Create_initial_save) )
             ]
           ();
         Log.Keeper.error
           "create_keeper failed: initial checkpoint save error for name=%s: %s"
           p.name
           detail;
         Progress.stop_tracking task_id;
         tool_result_error
           ~class_:Tool_result.Runtime_failure
           (Printf.sprintf "initial checkpoint save failed: %s" detail)
         |> with_config_warnings warnings
       | Ok { value = Error (`Metadata e); warnings } ->
         Otel_metric_store.inc_counter Keeper_metrics.(to_string WriteMetaFailures)
           ~labels:[("keeper", p.name); ("phase", "create_keeper")] ();
         Log.Keeper.error
           "create_keeper failed: owner metadata commit error for name=%s: %s"
           p.name
           e;
         Progress.stop_tracking task_id;
         tool_result_error ~class_:Tool_result.Runtime_failure e
         |> with_config_warnings warnings
       | Ok { value = Error (`Runtime_assignment e); warnings } ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string LifecycleDispatchRejections)
           ~labels:[("keeper", p.name); ("event", "create_runtime_assignment")]
           ();
         Progress.stop_tracking task_id;
         tool_result_error ~class_:Tool_result.Runtime_failure e
         |> with_config_warnings warnings
       | Ok { value = Ok (); warnings } ->
        Log.Keeper.debug "create_keeper: metadata written for name=%s trace_id=%s"
          p.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
        Progress.Tracker.step tracker ~message:"Starting keepalive loop" ();
        Log.Keeper.info "create_keeper: starting keepalive for name=%s" p.name;
        let launch_outcome = start_keepalive ~intake_token ctx meta in
        (match launch_outcome with
         | Keepalive_started _ ->
        Progress.Tracker.complete tracker ~message:"Keeper created" ();
        Log.Keeper.info "create_keeper: completed for name=%s trace_id=%s" p.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
        let json = `Assoc [
          ("name", `String meta.name);
          ("agent_name", `String meta.name);
          ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
          ("instructions", `String meta.instructions);
          ("proactive_enabled", `Bool meta.proactive.enabled);
          ("max_context_override", Json_util.int_opt_to_json meta.max_context_override);
          ("agent_core_env", `Assoc (List.map (fun (k, v) -> (k, `String v)) meta.agent_core_env));
        ] in
        tool_result_ok_data json
         | ( Keepalive_already_registered _
           | Keepalive_lifecycle_denied _
           | Keepalive_registration_rejected _
           | Keepalive_fiber_start_rejected _
           | Keepalive_memory_lane_not_ready _
           | Keepalive_launch_callback_failed _
           | Keepalive_lane_ownership_lost
           | Keepalive_fork_rejected _ ) as rejected ->
           Progress.stop_tracking task_id;
           tool_result_error ~class_:Tool_result.Runtime_failure
             (Printf.sprintf
                "keeper metadata was created but lane launch failed: %s"
                (start_keepalive_outcome_to_string rejected)))
        |> with_config_warnings warnings))
                   with
                   | result, None -> result
                   | result, Some operation_id ->
                     (* Observed, not obeyed. A reservation records that a
                        shutdown began; a shutdown that never finalises never
                        clears it, and refusing here left the sweep re-trying
                        every 30s against a slot nothing could release —
                        15h32m and 38,910 abandoned sessions on 2026-08-20
                        (#29566). Creation proceeds and names what it saw. *)
                     Otel_metric_store.inc_counter
                       Keeper_metrics.(to_string LifecycleDispatchRejections)
                       ~labels:
                         [ ("keeper", p.name)
                         ; ("event", "create_over_shutdown_admission")
                         ]
                       ();
                     Log.Keeper.warn
                       "keeper created while a shutdown reservation stood: \
                        keeper=%s operation=%s"
                       p.name
                       (Keeper_shutdown_types.Operation_id.to_string operation_id);
                     result)
