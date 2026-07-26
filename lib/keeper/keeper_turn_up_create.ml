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

let after_runtime_assignment_hook_key : (unit -> unit) Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let invoke_after_runtime_assignment_hook () =
  Option.iter
    (fun hook -> hook ())
    (Eio.Fiber.get after_runtime_assignment_hook_key)
;;

module For_testing = struct
  let with_after_runtime_assignment ~after_runtime_assignment fn =
    Eio.Fiber.with_binding
      after_runtime_assignment_hook_key
      after_runtime_assignment
      fn
  ;;
end


(* #9749: bootstrap can race a heartbeat/supervisor meta write after
   crash recovery. Retry on CAS conflict while keeping heartbeat-owned
   cursors from disk. *)
let write_initial_meta permit witness config meta =
  match
    Keeper_lifecycle_admission.Durable_transaction.with_permit_lease
      permit
      ~base_path:config.Workspace.base_path
      meta.Keeper_meta_contract.name
      (fun () ->
         Keeper_meta_store.create_meta permit witness config meta)
  with
  | Keeper_lifecycle_admission.Durable_transaction.Permit_lease_completed
      result ->
    result
  | Keeper_lifecycle_admission.Durable_transaction.Permit_lease_denied ->
    Error "keeper initial metadata write lost durable lifecycle admission"

let create_keeper_admitted_body
      (permit : Keeper_lifecycle_admission.Durable_transaction.permit)
      (ctx : _ context)
      (p : parsed_args)
  : tool_result
  =
  match Keeper_meta_store.read_meta ctx.config p.name with
  | Error detail -> tool_result_error detail
  | Ok (Some _) -> tool_result_error ("keeper already exists: " ^ p.name)
  | Ok None ->
  Log.Keeper.info "create_keeper: starting for name=%s" p.name;
  let task_id = Printf.sprintf "keeper_create_%s" p.name in
  let tracker = Progress.start_tracking ~task_id ~total_steps:6 () in
  Progress.Tracker.step tracker ~message:"Resolving keeper configuration" ();
  let now_ts = Time_compat.now () in
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
  (* [None] cannot reach here: the tool gate rejects a turn-up that states no sandbox
     profile in either the argument or the keeper TOML
     (keeper_turn_up_args.ml, sandbox_profile_error). Raising rather than choosing one
     keeps that contract checkable — a quiet default here would decide an isolation
     boundary on behalf of a caller who stated nothing, which is the requirement this
     tool exists to enforce. *)
  let sandbox_profile =
    match
      resolve_sandbox_profile
        ?requested:p.sandbox_profile_opt
        ~fallback:p.profile_defaults.sandbox_profile
        ()
    with
    | Some sp -> sp
    | None ->
      invalid_arg
        "Keeper_turn_up_create: no sandbox_profile in argument or keeper TOML; the \
         turn-up gate must reject this before creation"
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
  match active_goal_ids_error with
  | Some msg -> tool_result_error msg
  | None ->
    match
      validate_sandbox_settings ~allowed_paths
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
            ~instructions
            ~persona_extended
            ~keeper_name:p.name
            ~active_goals
            ()
      in
      let ctx0 =
        Keeper_context_runtime.create ~eio:true ~system_prompt
      in
      (* Lifecycle identity has its own durable authority. Reuse the exact
         reservation for metadata and checkpoint creation so they cannot
         diverge. *)
      let nonce_result =
        Result.bind
          (Keeper_lifecycle_nonce.create
             permit
             ~base_path:ctx.config.base_path
             ~keeper_id:p.name
             ~owner_id:trace_id
             ())
          (fun witness ->
             Keeper_lifecycle_nonce.runtime_int_of_nonce
               (Keeper_lifecycle_nonce.identity_nonce
                  (Keeper_lifecycle_nonce.witness_target witness))
             |> Result.map (fun nonce -> witness, nonce))
      in
      match nonce_result with
      | Error error ->
        let detail = Keeper_lifecycle_nonce.error_to_string error in
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string LifecycleDispatchRejections)
          ~labels:[ "keeper", p.name; "event", "create_lifecycle_nonce" ]
          ();
        Log.Keeper.error
          "create_keeper failed lifecycle nonce allocation name=%s: %s"
          p.name
          detail;
        Progress.stop_tracking task_id;
        tool_result_error detail
      | Ok (nonce_witness, nonce) ->
      let meta = {
        id = None;
        name = p.name;
        agent_name = Keeper_identity.keeper_agent_name p.name;
        persona = Some persona_extended;
        instructions;
        sandbox_profile;
        sandbox_image = None;
        network_mode;
        multimodal_policy;
        allowed_paths;
        mention_targets;
        proactive = {
          enabled = proactive_enabled;
        };
        created_at = now_iso ();
        updated_at = now_iso ();
        max_context_override = p.max_context_override_opt;
        active_goal_ids =
          active_goal_ids;
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
            last_latency_ms = 0;
          };
          compaction_rt = {
            count = 0;
            last_ts = 0.0;
            last_before_tokens = 0;
            last_after_tokens = 0;
            last_check_ts = now_ts;
            last_decision = compaction_runtime_decision_of_string "initialized";
            consecutive_failures = 0;
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
          nonce;
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
          message_scope_ack_id = None;
	          last_blocker = None;
	          last_runtime_attempt = None;
	        };
      keeper_id = Some (Keeper_id.Uid.generate ());
      oas_env = p.profile_defaults.oas_env;
      meta_version = 0;
      } in
      Progress.Tracker.step tracker ~message:"Saving initial checkpoint" ();
      let init_save_result =
        try
          Keeper_context_runtime.save_oas_checkpoint
            ~multimodal_policy:meta.multimodal_policy
            ~keeper_name:meta.name
            ~session
            ~agent_name:meta.agent_name
            ~ctx:ctx0
            ~generation:nonce
          |> Result.map_error (fun error -> `Write_error error)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            log_keeper_exn ~label:"save_oas_checkpoint (init) exception" exn;
            Error (`Unexpected_exception (Printexc.to_string exn))
      in
      match init_save_result with
      | Error error ->
        let detail =
          match error with
          | `Write_error error ->
            Keeper_context_core.checkpoint_write_error_to_string
              ~persistence_error_to_string:Fun.id
              error
          | `Unexpected_exception detail -> detail
        in
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string CheckpointFailures)
          ~labels:[("keeper", p.name); ("site", Keeper_checkpoint_failure_operation.(to_label Create_initial_save))]
          ();
        Log.Keeper.error
          "create_keeper failed: initial checkpoint save error for name=%s: %s"
          p.name detail;
        Progress.stop_tracking task_id;
        tool_result_error (Printf.sprintf "initial checkpoint save failed: %s" detail)
        | Ok _ ->
        Eio.Cancel.protect (fun () ->
        let previous_runtime = Runtime.runtime_id_for_keeper p.name in
        let candidate_runtime =
          match p.runtime_id_opt with
          | None -> previous_runtime
          | Some runtime_id -> Some runtime_id
        in
        match
          Keeper_runtime_meta_transaction.prepare
            ~operation:Keeper_runtime_meta_journal.Create
            ~config:ctx.config
            ~keeper_name:p.name
            ~previous_runtime
            ~candidate_runtime
            ~previous_meta:None
            ~candidate_meta:meta
        with
        | Error failure ->
          Progress.stop_tracking task_id;
          tool_result_error
            (Keeper_runtime_meta_transaction.recovery_failure_to_string
               failure)
        | Ok runtime_meta_intent ->
        let runtime_assignment_changed = ref false in
      let same_runtime_target target =
        Option.equal
          String.equal
          (Runtime.runtime_id_for_keeper p.name)
          target
      in
      let converge_runtime_assignment target =
        if same_runtime_target target
        then Ok ()
        else
          let result =
            match target with
            | Some runtime_id ->
              Runtime.set_runtime_id_for_keeper
                ~keeper_name:p.name
                ~runtime_id
                ()
            | None ->
              Runtime.clear_runtime_id_for_keeper ~keeper_name:p.name ()
          in
          match result with
          | Ok () -> Ok ()
          | Error detail ->
            if same_runtime_target target then Ok () else Error detail
      in
      let restore_runtime_assignment () =
        if not !runtime_assignment_changed
        then Ok ()
        else converge_runtime_assignment previous_runtime
      in
      let runtime_assignment_result =
        match p.runtime_id_opt with
        | None -> Ok ()
        | Some runtime_id
          when Option.equal String.equal previous_runtime (Some runtime_id) ->
          Ok ()
        | Some runtime_id ->
          runtime_assignment_changed := true;
          (match
             Runtime.set_runtime_id_for_keeper
               ~keeper_name:p.name
               ~runtime_id
               ()
           with
           | Ok () -> Ok ()
           | Error detail ->
             if same_runtime_target (Some runtime_id)
             then Ok ()
             else
               (match restore_runtime_assignment () with
                | Ok () -> Error detail
                | Error rollback_detail ->
                  Error
                    (detail
                     ^ "; runtime assignment rollback failed: "
                     ^ rollback_detail)))
      in
      (match runtime_assignment_result with
       | Error e ->
         let recovery_detail =
           match
             Keeper_runtime_meta_transaction.recover
               permit
               ctx.config
               runtime_meta_intent
               ~prefer:`Rollback
           with
           | Ok _ -> ""
           | Error failure ->
             "; recovery failed: "
             ^ Keeper_runtime_meta_transaction.recovery_failure_to_string
                 failure
         in
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string LifecycleDispatchRejections)
           ~labels:[("keeper", p.name); ("event", "create_runtime_assignment")]
           ();
         Log.Keeper.error
           "create_keeper failed: runtime assignment error for name=%s: %s"
           p.name
           e;
         Progress.stop_tracking task_id;
         tool_result_error (e ^ recovery_detail)
        | Ok () ->
        invoke_after_runtime_assignment_hook ();
        Progress.Tracker.step tracker ~message:"Writing keeper metadata" ();
        let committed_meta = { meta with meta_version = 1 } in
      let same_committed_meta current =
        String.equal
          (Yojson.Safe.to_string (Keeper_meta_json.meta_to_json current))
            (Yojson.Safe.to_string
               (Keeper_meta_json.meta_to_json committed_meta))
        in
        let settle_create_state () =
          match
            Keeper_runtime_meta_transaction.recover
              permit
              ctx.config
              runtime_meta_intent
              ~prefer:`Rollback
          with
          | Ok Keeper_runtime_meta_transaction.Rolled_back ->
            Ok `Rolled_back
          | Ok Keeper_runtime_meta_transaction.Forward_committed ->
            Ok `Forward
          | Error failure ->
            Error
              (Keeper_runtime_meta_transaction.recovery_failure_to_string
                 failure)
        in
        let write_result =
        match write_initial_meta permit nonce_witness ctx.config meta with
        | Ok () -> Ok ()
        | Error initial_error ->
          (match Keeper_meta_store.read_meta ctx.config p.name with
           | Ok (Some current) when same_committed_meta current ->
             Log.Keeper.warn
               "create_keeper: metadata write returned error after exact \
                candidate publication name=%s error=%s"
               p.name
               initial_error;
             Ok ()
           | Ok None -> Error initial_error
           | Ok (Some _) ->
             Error
               (initial_error
                ^ "; metadata authority differs after failed write")
           | Error reread_error ->
             Error
               (initial_error
                ^ "; metadata publication could not be reconciled: "
                ^ reread_error))
      in
      match write_result with
        | Error e ->
        Otel_metric_store.inc_counter Keeper_metrics.(to_string WriteMetaFailures)
          ~labels:[("keeper", p.name); ("phase", "create_keeper")] ();
        Log.Keeper.error "create_keeper failed: write_meta error for name=%s: %s" p.name e;
          let detail =
            match settle_create_state () with
            | Ok `Rolled_back -> e
            | Ok `Forward ->
              e ^ "; exact candidate create state retained"
            | Error recovery ->
              Log.Keeper.error
                "create_keeper exact recovery failed name=%s detail=%s"
                p.name
                recovery;
              e ^ "; " ^ recovery
        in
        Progress.stop_tracking task_id;
        tool_result_error detail
      | Ok () ->
        Log.Keeper.debug "create_keeper: metadata written for name=%s trace_id=%s"
          p.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
        Progress.Tracker.step tracker ~message:"Starting keepalive loop" ();
        Log.Keeper.info "create_keeper: starting keepalive for name=%s" p.name;
        let launch_gate = create_launch_gate () in
        let launch_outcome =
          start_keepalive_under_admission
            ~launch_gate
            ~durable_meta_bootstrap:Durable_meta_already_committed
            permit
            ctx
            committed_meta
        in
        (match launch_outcome with
         | Keepalive_started _ ->
        commit_launch_gate launch_gate;
        (match
           Keeper_runtime_meta_transaction.complete_forward
             permit
             ctx.config
             runtime_meta_intent
         with
         | Error failure ->
           Progress.stop_tracking task_id;
           tool_result_error
             ("keeper creation committed but runtime/meta authority cleanup \
               failed: "
              ^ Keeper_runtime_meta_transaction.recovery_failure_to_string
                  failure)
         | Ok () ->
           Progress.Tracker.complete tracker ~message:"Keeper created" ();
           Log.Keeper.info "create_keeper: completed for name=%s trace_id=%s" p.name (Keeper_id.Trace_id.to_string meta.runtime.trace_id);
           let json = `Assoc [
             ("name", `String meta.name);
             ("agent_name", `String meta.agent_name);
             ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
             ("generation", `Int meta.runtime.nonce);
             ("instructions", `String meta.instructions);
             ("proactive_enabled", `Bool meta.proactive.enabled);
             ("max_context_override", Json_util.int_opt_to_json meta.max_context_override);
             ("oas_env", `Assoc (List.map (fun (k, v) -> (k, `String v)) meta.oas_env));
           ] in
           tool_result_ok_data json)
         | ( Keepalive_already_registered _
           | Keepalive_lifecycle_denied _
           | Keepalive_transaction_admission_denied _
           | Keepalive_identity_unrepairable
           | Keepalive_registration_rejected _
           | Keepalive_fiber_start_rejected _
           | Keepalive_lane_ownership_lost
           | Keepalive_fork_rejected _ ) as rejected ->
           abort_launch_gate launch_gate;
           let cleanup_errors = ref [] in
           (match Keeper_registry.get ~base_path:ctx.config.base_path p.name with
            | Some entry
              when Keeper_id.Trace_id.equal
                     entry.meta.runtime.trace_id
                     meta.runtime.trace_id
                   && Int.equal entry.meta.runtime.nonce meta.runtime.nonce ->
              request_entry_stop entry;
              let _lane_exit = Keeper_lane.await_exit entry.lane in
              let _terminal = Eio.Promise.await entry.done_p in
              (match Keeper_registry.unregister_exact entry with
               | Keeper_registry.Exact_unregistered
               | Keeper_registry.Exact_entry_missing -> ()
               | Keeper_registry.Exact_entry_replaced ->
                 cleanup_errors :=
                   "candidate registry entry was replaced during rollback"
                   :: !cleanup_errors
               | Keeper_registry.Exact_unregister_lifecycle_reserved owner ->
                 cleanup_errors :=
                   ("candidate registry rollback was reserved: "
                    ^ Keeper_lifecycle_reservation.snapshot_to_string owner)
                   :: !cleanup_errors)
             | Some _ | None -> ());
             (match settle_create_state () with
              | Ok `Rolled_back -> ()
              | Ok `Forward ->
                cleanup_errors :=
                  "launch failed; exact candidate create state retained"
                  :: !cleanup_errors
              | Error detail ->
                Log.Keeper.error
                  "create_keeper launch recovery failed name=%s detail=%s"
                  p.name
                  detail;
                cleanup_errors := detail :: !cleanup_errors);
           Progress.stop_tracking task_id;
           let cleanup_detail =
             match List.rev !cleanup_errors with
             | [] -> ""
             | errors ->
               "; recovery failed: " ^ String.concat "; " errors
           in
           tool_result_error
             (Printf.sprintf
                "keeper creation lane launch failed: %s%s"
                (start_keepalive_outcome_to_string rejected)
                cleanup_detail))))
;;

let create_keeper_admitted permit ctx p =
  match
    Keeper_lifecycle_admission.Durable_transaction.with_permit_lease
      permit
      ~base_path:ctx.config.Workspace.base_path
      p.name
      (fun () -> create_keeper_admitted_body permit ctx p)
  with
  | Keeper_lifecycle_admission.Durable_transaction.Permit_lease_completed
      result ->
    result
  | Keeper_lifecycle_admission.Durable_transaction.Permit_lease_denied ->
    tool_result_error "keeper creation lost durable lifecycle admission"
;;

let create_keeper (ctx : _ context) (p : parsed_args) : tool_result =
  match
    Keeper_lifecycle_admission.Durable_transaction
    .with_durable_lifecycle_admission
      ctx.config
      ~keeper_name:p.name
      (fun permit -> create_keeper_admitted permit ctx p)
  with
  | Keeper_lifecycle_admission.Durable_transaction.Admission_completed result ->
    result
  | Keeper_lifecycle_admission.Durable_transaction
    .Admission_completed_with_attention (result, failure) ->
    Log.Keeper.error
      "keeper creation lifecycle admission release requires attention \
       keeper=%s failure=%s"
      p.name
      (Keeper_lifecycle_admission.Durable_transaction
       .authority_failure_to_wire
         failure);
    result
  | Keeper_lifecycle_admission.Durable_transaction.Admission_blocked reason ->
    let detail =
      Keeper_lifecycle_admission.Durable_transaction.blocked_reason_to_wire
        reason
    in
    Log.Keeper.warn
      "keeper creation blocked by durable lifecycle authority keeper=%s \
       reason=%s"
      p.name
      detail;
    tool_result_error detail
;;
