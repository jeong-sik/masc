(** Keeper_unified_turn — Single entry point for keeper cycles via OAS Agent.run().

    Replaces the 3-path dispatcher (social/proactive/autonomy) with a unified
    observe -> prompt -> Agent.run(tools, guardrails, hooks) loop.
    The model decides what to do; code only enforces safety and observes results.

    @since Unified Keeper Loop *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_context_runtime
include Keeper_turn_helpers
include Keeper_turn_runtime_budget
include Keeper_unified_turn_types

(* RFC-0132 PR-2: removed dead [runtime_lane_label] (0 callers). *)

include Keeper_unified_turn_phase_plan

type source_lease_disposition =
  | Follow_failure_route
  | Requeue_after_context_compaction
  | Acknowledge_after_in_turn_handling

type turn_failure =
  { error : Agent_sdk.Error.sdk_error
  ; runtime_id : string
  ; route : Keeper_runtime_failure_route.route
  ; source_lease_disposition : source_lease_disposition
  }

type turn_success =
  | Turn_completed of keeper_meta
  | Turn_cancelled of keeper_meta
  | Turn_skipped of keeper_meta

let user_message_with_hitl_resolution ~base_path ~user_message = function
  | Some
      { Keeper_event_queue.approval_id
      ; decision = Hitl_approved
      ; _
      } ->
    (match
       Keeper_approval_queue.approved_resolution_request
         ~base_path
         ~id:approval_id
     with
     | Ok (Some request) ->
       String.concat
         "\n"
         [ user_message
         ; ""
         ; "Gate resolution delivered:"
         ; Printf.sprintf "- approval_id: %s" approval_id
         ; Printf.sprintf "- operation: %s" request.tool_name
         ; "- exact input:"
         ; "```json"
         ; Yojson.Safe.pretty_to_string request.input
         ; "```"
         ; "The one-shot authorization belongs to this exact operation and input. Other external effects follow the ordinary Gate independently."
         ]
     | Ok None ->
       Log.Keeper.info
         "approved Gate request already consumed approval=%s"
         approval_id;
       String.concat
         "\n"
         [ user_message
         ; ""
         ; "Gate resolution delivered:"
         ; Printf.sprintf "- approval_id: %s" approval_id
         ; "- state: authorization already consumed"
         ; "This replay grants no authorization. Continue independent work; any new external effect follows the ordinary Gate."
         ]
     | Error error ->
       Log.Keeper.error
         "approved Gate request unavailable approval=%s: %s"
         approval_id
         (Keeper_approval_queue.grant_error_to_string error);
       String.concat
         "\n"
         [ user_message
         ; ""
         ; Printf.sprintf
             "Gate resolution %s could not be read from its durable journal. Continue independent work; this event will be retried."
             approval_id
         ])
  | Some
      { Keeper_event_queue.approval_id
      ; decision = Hitl_rejected rationale
      ; _
      } ->
    String.concat
      "\n"
      [ user_message
      ; ""
      ; "Gate resolution delivered:"
      ; Printf.sprintf "- approval_id: %s" approval_id
      ; "- decision: rejected"
      ; Printf.sprintf "- rationale: %s" rationale
      ; "This resolution grants no authorization. Continue independent work or revise the request using the rationale."
      ]
  | Some
      { Keeper_event_queue.approval_id
      ; decision = Hitl_edited edited_input
      ; _
      } ->
    String.concat
      "\n"
      [ user_message
      ; ""
      ; "Gate resolution delivered:"
      ; Printf.sprintf "- approval_id: %s" approval_id
      ; "- decision: edited"
      ; "- edited input:"
      ; "```json"
      ; Yojson.Safe.pretty_to_string edited_input
      ; "```"
      ; "This edit grants no authorization. Treat the edited input as operator guidance; any external effect follows the ordinary Gate independently."
      ]
  | None -> user_message
;;

type provider_overflow_recovery =
  | Not_provider_overflow
  | Provider_overflow_applied of
      { trigger : Compaction_trigger.t
      ; recovery : Keeper_context_runtime.overflow_retry_recovery
      }
  | Provider_overflow_retry of
      { trigger : Compaction_trigger.t
      ; reason : string
      ; recovery : Keeper_context_runtime.overflow_retry_recovery option
      }

let recover_provider_context_overflow_in_lane
      ~(config : Workspace.config)
      ~base_dir
      ~(meta : keeper_meta)
      ~primary_model_max_tokens
      error
  =
  match context_overflow_event_of_error error with
  | None -> Not_provider_overflow
  | Some
      ((Keeper_state_machine.Context_overflow_detected { limit_tokens }) as
       overflow_event) ->
    let origin = Keeper_registry.Post_turn_lifecycle in
    let trigger = Compaction_trigger.Provider_overflow { limit_tokens } in
    let dispatch stage event =
      match
        dispatch_keeper_phase_event_result
          ~config
          ~origin
          ~keeper_name:meta.name
          event
      with
      | Ok () -> Ok ()
      | Error error ->
        let detail = lifecycle_dispatch_error_to_string error in
        Log.Keeper.error
          ~keeper_name:meta.name
          "provider overflow recovery lifecycle rejected stage=%s: %s"
          stage
          detail;
        Error detail
    in
    let release_failed_lifecycle reason =
      match
        dispatch
          "compaction_failed"
          (Keeper_state_machine.Compaction_failed { reason })
      with
      | Ok () -> ()
      | Error detail ->
        Log.Keeper.error
          ~keeper_name:meta.name
          "provider overflow recovery could not release compaction lifecycle: %s"
          detail
    in
    let retry_after_started ?recovery reason =
      record_overflow_failure ~config ~meta ~reason;
      release_failed_lifecycle reason;
      Provider_overflow_retry { trigger; reason; recovery }
    in
    (match dispatch "context_overflow_detected" overflow_event with
     | Error reason ->
       record_overflow_failure ~config ~meta ~reason;
       Provider_overflow_retry { trigger; reason; recovery = None }
     | Ok () ->
       (match dispatch "compaction_started" Keeper_state_machine.Compaction_started with
        | Error reason -> retry_after_started reason
        | Ok () ->
          (try
             match
               recover_latest_checkpoint_for_overflow_retry
                 ~base_dir
                 ~meta
                 ~trigger
                 ~primary_model_max_tokens
             with
             | Error error ->
               retry_after_started
                 (Keeper_post_turn.compaction_recovery_error_to_string error)
             | Ok recovery ->
               (match
                  dispatch_compaction_completed
                    ~config
                    ~origin
                    ~keeper_name:meta.name
                with
                | Ok () ->
                    Log.Keeper.info
                      ~keeper_name:meta.name
                      "provider overflow compaction committed; source stimulus will be requeued";
                    Provider_overflow_applied { trigger; recovery }
                | Error error ->
                  retry_after_started
                    ~recovery
                    (lifecycle_dispatch_error_to_string error))
           with
           | Eio.Cancel.Cancelled _ as exn ->
             let backtrace = Printexc.get_raw_backtrace () in
             Eio.Cancel.protect (fun () ->
               try release_failed_lifecycle "provider overflow compaction cancelled" with
               | cleanup_exn ->
                 Log.Keeper.error
                   ~keeper_name:meta.name
                   "provider overflow cancellation cleanup failed: %s"
                   (Printexc.to_string cleanup_exn));
             Printexc.raise_with_backtrace exn backtrace
           | exn -> retry_after_started (Printexc.to_string exn))))
  | Some event ->
    Log.Keeper.error
      ~keeper_name:meta.name
      "context overflow classifier returned a non-overflow event: %s"
      (Keeper_state_machine.event_to_string event);
    Not_provider_overflow
;;

let append_provider_overflow_manifest
      ~config
      ~runtime_manifest_context
      ~turn_start
      ~turn_state
      ~base_dir
      outcome
  =
  let append_recovery ~status ~error ~trigger ~recovery turn_state =
    let evidence = recovery.evidence in
    let session_id = recovery.checkpoint.session_id in
    let checkpoint_path =
      Keeper_checkpoint_store.oas_checkpoint_path
        ~session_dir:(Filename.concat base_dir session_id)
        ~session_id
    in
    let turn_state =
      Keeper_unified_turn_manifest.append_manifest
        ~config
        ~runtime_manifest_context
        ~turn_start
        ~turn_state
        ~site:"provider_overflow_compaction"
        ~status
        ?runtime_id:evidence.selected_runtime_id
        ~compaction_source:"provider_overflow"
        ~checkpoint_path
        ~decision:
          (Keeper_runtime_manifest.with_payload_role
             ~payload_role:Checkpoint
             (`Assoc
               [ "trigger", `String (Compaction_trigger.to_label trigger)
               ; "trigger_detail", Compaction_trigger.to_detail_json trigger
               ; "source_requeued", `Bool true
               ; "error", error
               ; ( "exact_evidence"
                 , Keeper_compact_policy.compaction_evidence_to_json evidence )
               ]))
        Keeper_runtime_manifest.Context_compacted
    in
    turn_state
  in
  match outcome with
  | Not_provider_overflow -> Follow_failure_route, turn_state
  | Provider_overflow_applied { trigger; recovery } ->
    let turn_state =
      append_recovery
        ~status:"compacted"
        ~error:`Null
        ~trigger
        ~recovery
        turn_state
    in
    Requeue_after_context_compaction, turn_state
  | Provider_overflow_retry { trigger; reason; recovery = Some recovery } ->
    let turn_state =
      append_recovery
        ~status:"retryable_failure"
        ~error:(`String reason)
        ~trigger
        ~recovery
        turn_state
    in
    Requeue_after_context_compaction, turn_state
  | Provider_overflow_retry { trigger; reason; recovery = None } ->
    let turn_state =
      Keeper_unified_turn_manifest.append_manifest
        ~config
        ~runtime_manifest_context
        ~turn_start
        ~turn_state
        ~site:"provider_overflow_compaction_failed"
        ~status:"retryable_failure"
        ~compaction_source:"provider_overflow"
        ~decision:
          (Keeper_runtime_manifest.with_payload_role
             ~payload_role:Checkpoint
             (`Assoc
               [ "trigger", `String (Compaction_trigger.to_label trigger)
               ; "trigger_detail", Compaction_trigger.to_detail_json trigger
               ; "source_requeued", `Bool true
               ; "error", `String reason
               ]))
        Keeper_runtime_manifest.Context_compacted
    in
    Requeue_after_context_compaction, turn_state
;;

let run_keeper_cycle
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(publication_recovery_provider :
          Keeper_publication_recovery_availability.provider)
      ~(observation : Keeper_world_observation.world_observation)
      ~(generation : int)
      ~(wake : Keeper_registry.wake_reason)
      ?(channel : Keeper_world_observation.keeper_cycle_channel = Scheduled_autonomous)
      ?(turn_decision : Keeper_world_observation.keeper_cycle_decision option)
      ?shared_context
      ?event_bus
      ?hitl_resolution
      ?continuation_delivery_channel
      ()
  : (turn_success, turn_failure) result
  =
  match
    Keeper_publication_recovery_scope.resolve_turn_resources
      ~provider:publication_recovery_provider
      ~base_path:config.base_path
      ~keeper_name:meta.name
  with
  | Error failure ->
    let error =
      Agent_sdk.Error.Config
        (Agent_sdk.Error.InvalidConfig
           { field = "keeper.publication_recovery_scope"
           ; detail =
               Keeper_publication_recovery_scope.failure_to_string failure
           })
    in
    Error
      { error
      ; runtime_id = Keeper_meta_contract.runtime_id_of_meta meta
      ; route =
          Keeper_runtime_failure_route.route_of_error
            ~boundary:Keeper_runtime_failure_route.Masc_execution
            error
      ; source_lease_disposition = Follow_failure_route
      }
  | Ok { entry; publication_recovery } ->
  let meta = entry.meta in
  (* Spec navigation: see specs/keeper-state-machine/KeeperTaskAcquisition.tla
     (Cycle 8/Tier B2, PR #11412).  Action mapping:
     SubmitTask=external producers, AssignTask=channel decision below,
     EmptyQueueSleep=scheduled_autonomous else, TurnComplete=run_turn body,
     TaskRejected=NoTaskOrphan invariant (every claim reaches Ok/Error). *)
  (* Cycle 45: KeeperTaskAcquisition.tla TurnComplete bracket — the
     cycle_completed flag is set to true on the [Ok updated_meta] return at
     the end of this function; an [Error _] branch leaves it false and
     skips the wrap, mirroring the spec's "completed-on-success" semantics. *)
  (* 0. Phase gate + state-aware runtime routing.
     The gate owns turn executability; select_runtime remains a total helper
     so dashboards/tests can inspect the same routing contract for blocked
     phases like Overflowed. *)
  let registry_base_path = config.base_path in
  let exact_failure_execution = ref None in
  (* Decide turn_id at function entry so phase-gate and runtime-routing
     terminal paths can include it in the receipt and observability stream. *)
  let keeper_turn_id = meta.runtime.usage.total_turns + 1 in
  let runtime_manifest_context : Keeper_runtime_manifest.turn_context =
    { manifest_keeper_name = meta.name
    ; manifest_agent_name = Some meta.agent_name
    ; manifest_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id
    ; manifest_generation = Some generation
    ; manifest_keeper_turn_id = Some keeper_turn_id
    }
  in
  let turn_start = Mtime_clock.now () in
  let initial_turn_state : Keeper_unified_turn_types.turn_state =
    { cycle_completed = false
    ; manifest_seq = 0
    ; current_turn_blocker_info = None
    ; last_execution = None
    ; degraded_retry_info = None
    ; runtime_rotation_attempts = []
    ; failure_reason = None
    ; retry_phase_started_at = None
    }
  in
  let turn_state =
    Keeper_unified_turn_manifest.append_manifest
      ~config
      ~runtime_manifest_context
      ~turn_start
      ~turn_state:initial_turn_state
      ~site:"turn_started"
      ~decision:
        (`Assoc
          [
            ( "channel",
              `String (Keeper_world_observation.channel_to_string channel) );
            ("usage_total_turns", `Int meta.runtime.usage.total_turns);
          ])
      Keeper_runtime_manifest.Turn_started
  in
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.name
    ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Idle
    Keeper_turn_fsm.Phase_gating;
  (* SupervisorRequestsStop / HonorStopSignal — check stop signal at turn entry.
     If the supervisor set [fiber_stop] between the [should_run_turn] gate in the
     heartbeat loop and this point, honor it cooperatively before any I/O is issued.
     Satisfies the FSM contract: active state observed → SupervisorRequestsStop
     (Phase_gating → Phase_gating, stop signal acknowledged) then HonorStopSignal
     (Phase_gating → Cancelled supervisor_stop). *)
  (* RFC-0136 PR-1: phase gate stage extracted to
     [Keeper_unified_turn_phase_gate].  The main turn body is wrapped
     as a nested [main_path] function so the caller can match on a
     typed [phase_gate_outcome] and dispatch each terminal outcome at
     the top of the function body, rather than burying early-exits in
     deeply nested match arms.

     State-aware runtime routing (TLA+ KeeperCoreTriad.SelectRuntime)
     resumes inside [main_path]; at that point [phase_opt] is whatever
     the registry returned for an executable phase. *)
  let main_path (turn_state : Keeper_unified_turn_execution.turn_state) phase_opt
    : (keeper_meta, Agent_sdk.Error.sdk_error) result
      * Keeper_unified_turn_execution.turn_state
    =
      let _ = phase_opt in
      let effective_runtime_id = Keeper_meta_contract.runtime_id_of_meta meta in
      let source =
        match Runtime.runtime_id_for_keeper meta.name with
        | Some id when String.trim id <> "" -> "assigned"
        | _ -> "default"
      in
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string RuntimeSelected)
        ~labels:[("keeper", meta.name); ("runtime_id", effective_runtime_id); ("source", source)]
        ();
      let turn_state =
        Keeper_unified_turn_manifest.append_manifest
          ~config
          ~runtime_manifest_context
          ~turn_start
          ~turn_state
          ~site:"runtime_routed"
          ~runtime_id:effective_runtime_id
          (* RFC-0132-EXEMPT: internal observability — manifest decision reason label, not a redacted public surface *)
          ~decision:(`Assoc [ "reason", `String "runtime" ])
          Keeper_runtime_manifest.Runtime_routed
      in
      (* Concrete runtime health/capacity is owned by OAS/provider adapters.
         Keeper routing no longer rewrites runtimes from provider cooldown or
         process-queue probes. *)
      (match None with
       | Some meta_after_skip -> Ok meta_after_skip, turn_state
       | None ->
         (* RFC-0136 PR-3: pre-dispatch validation extracted to
            [Keeper_unified_turn_pre_dispatch].  profile_defaults stays
            in scope so the retry-loop block below can also call the
            extracted builder with the same defaults. *)
         let effective_runtime_runtime_name = effective_runtime_id in
         let profile_and_execution =
           match
             Keeper_unified_turn_pre_dispatch.load_profile_defaults
               ~base_path:config.base_path
               ~keeper_name:meta.name
           with
           | Error _ as error -> error
           | Ok profile_defaults ->
             Keeper_unified_turn_pre_dispatch.build_runtime_execution
               ~meta
               ~runtime_id:effective_runtime_runtime_name
             |> Result.map (fun execution -> profile_defaults, execution)
         in
         (match profile_and_execution
          with
          | Error err ->
            let terminal_reason_code =
              Printf.sprintf
                "pre_dispatch_%s"
                (Keeper_agent_error.terminal_reason_code_of_sdk_error err)
            in
            let error_message = Agent_sdk.Error.to_string err in
            Log.Keeper.error
              ~keeper_name:meta.name
              "%s: pre_dispatch failed: %s"
              meta.name
              error_message;
            record_pre_dispatch_terminal_observation
              ~config
              ~meta
              ~generation
              ~runtime_id:effective_runtime_runtime_name
              ~outcome:`Error
              ~terminal_reason_code
              ~activity_kind:"keeper.turn_blocked"
              ~trajectory_outcome:(Trajectory.Failed terminal_reason_code)
              ~error_kind:
                (Keeper_execution_receipt.error_kind_of_string (sdk_error_kind err))
              ~error_message
              ~keeper_turn_id
              ();
            let failure_reason =
              match Keeper_turn_driver.classify_masc_internal_error err with
              | _ when EC.is_runtime_exhausted_error err ->
                Keeper_turn_fsm.Failure_runtime_unavailable
                  { base = effective_runtime_runtime_name
                  ; resolved = None
                  }
              | _ ->
                Keeper_turn_fsm.Failure_provider_error
                  { kind = sdk_error_kind err; detail = error_message }
            in
            Keeper_turn_fsm.emit_transition
              ~keeper_name:meta.name
              ~turn_id:keeper_turn_id
              ~prev:Keeper_turn_fsm.Runtime_routing
              (Keeper_turn_fsm.Failed failure_reason);
            Error err, turn_state
          | Ok (profile_defaults, initial_execution) ->
            let turn_state =
              Keeper_unified_turn_manifest.append_manifest
                ~config
                ~runtime_manifest_context
                ~turn_start
                ~turn_state
                ~site:"runtime_execution_built"
                ~runtime_id:effective_runtime_runtime_name
                ~decision:
                  (`Assoc
                    [ "runtime_execution_built", `Bool true
                    ; "routing_action", `String "runtime_execution_built"
                    ; "routing_reason", `String "pre_dispatch_success"
                    ])
                Keeper_runtime_manifest.Runtime_execution_built
            in
            Keeper_event_publisher.publish_runtime_execution_built
              ~keeper_name:meta.name
              ~runtime_id:initial_execution.runtime_id
              ~max_context:initial_execution.max_context
              ~effective_budget:initial_execution.max_context_resolution.effective_budget
              ~temperature:initial_execution.temperature
              ~generation;
            let turn_id = keeper_turn_id in
            let (_ : Keeper_turn_attempt_observer.start_observation) =
              Keeper_turn_attempt_observer.record_turn_start
                ~base_path:registry_base_path
                ~keeper:meta.name
                ~turn_id
            in
               Keeper_turn_fsm.emit_transition
                 ~keeper_name:meta.name
                 ~turn_id:keeper_turn_id
                 ~prev:Keeper_turn_fsm.Runtime_routing
                 Keeper_turn_fsm.Awaiting_provider;
               (* Yield before CPU-bound prompt construction so the Eio scheduler
         can service HTTP handlers between keeper turn setups. *)
               Eio.Fiber.yield ();
               (* 2. Build unified prompt — diversity entropy recorded in decision_audit
         (keeper_keepalive.ml), not injected into prompt (#6814). *)
               (* RFC-0315: resolve the claimed task and goal titles here (the
                  turn runner owns config), so the prompt can render what the
                  keeper holds and why it woke. Both reads are total: a failed
                  backlog read yields None, an unknown goal id remains a bare
                  id instead of disappearing from the prompt. *)
               let current_task =
                 Keeper_world_observation_inputs.read_current_task ~config ~meta
               in
               let active_goal_summaries =
                 List.map
                   (fun goal_id ->
                     match Goal_store.get_goal config ~goal_id with
                     | Some { Goal_store.title; _ } -> (goal_id, title)
                     | None -> (goal_id, ""))
                   meta.active_goal_ids
               in
               let system_prompt, user_message =
                 Keeper_unified_prompt.build_prompt
                   ~meta
                   ~base_path:config.base_path
                   ~profile_defaults
                   ?turn_decision
                   ?current_task
                   ~active_goal_summaries
                   ~observation
                   ()
               in
               let user_message =
                 user_message_with_hitl_resolution
                   ~base_path:config.base_path
                   ~user_message
                   hitl_resolution
               in
               Eio.Fiber.yield ();
               let base_dir = session_base_dir config in
               (* Ensure session dir tree for trace artifacts. *)
               let (_ : string) =
                 Keeper_fs.ensure_dir
                   (Filename.concat
                      base_dir
                      (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
               in
               let masc_root = Workspace.masc_root_dir config in
               let trajectory_acc =
                 Trajectory.create_accumulator
                   ~masc_root
                   ~keeper_name:meta.name
                   ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                   ~generation:meta.runtime.generation ()
               in
               (* RFC-0225 §3.3: one carrier per cycle. The pre-request hook
                  writes the effective turn policy here; the decision records
                  below read the same cell, so a concurrent run of this keeper
                  can never substitute its own identity. *)
               let turn_ctx_cell =
                 Keeper_tool_call_log.create_turn_ctx_cell ()
               in
               (* 4. Build turn prompt callback: use our unified system prompt *)
               let build_turn_prompt ~base_system_prompt:_ ~messages:_
                 : Keeper_agent_run.turn_prompt
                 =
                 (* Unified path already places soft context (continuity, worktree)
           in the user_message via Keeper_unified_prompt.build_prompt.
           No dynamic_context needed here. *)
                 { system_prompt; dynamic_context = "" }
               in
               (* 5. Run via OAS Agent.run() with transient-error retry.
                  The turn-local OAS Event_bus preserves factual
                  ToolCalled/ToolCompleted pairing and drives
                  Streaming⇄Awaiting_tool_result FSM transitions. It does
                  not infer tool effects or veto retry. *)
               let turn_state =
                 { turn_state with last_execution = Some initial_execution }
               in
               let turn_event_bus_state =
                 Keeper_unified_turn_event_bus.create
                   ?event_bus
                 (* Mirror the in-flight tool count into the
                    live turn_observation so the supervisor sweep excludes
                    active tool execution from the no-progress window. *)
                   ~on_pending_count_change:(fun count ->
                     Keeper_registry.record_turn_tool_inflight
                       ~base_path:config.base_path
                       meta.name
                       ~count)
                   ~keeper_name:meta.name
                   ~turn_id:keeper_turn_id
                   ()
               in
               (* PR-J: [?site] labels the call-site so metric queries can attribute
         drain pressure to background polling vs unsubscribe vs the
         retry path. [outcome=drained] when at least one event was
         pulled, [outcome=empty] otherwise (the latter is the no-op
         tick that establishes the lock-acquire baseline). *)
               let drain_turn_event_bus ?(site = "unspecified") () =
                 Keeper_unified_turn_event_bus.drain ~site turn_event_bus_state
               in
               let event_bus_integrity_error_snapshot () =
                 Keeper_unified_turn_event_bus.integrity_error turn_event_bus_state
               in
               let tool_completed_count_snapshot () =
                 Keeper_unified_turn_event_bus.tool_completed_count turn_event_bus_state
               in
               let start_background_turn_event_bus_drain ~clock =
                 Keeper_unified_turn_event_bus.start_background_drain
                   ~clock
                   turn_event_bus_state
               in
               let unsubscribe_event_bus () =
                 Keeper_unified_turn_event_bus.unsubscribe turn_event_bus_state
               in
               (* Mark turn boundary for the composite observer (issue #7122).
         [mark_turn_started] installs [current_turn_observation = Some _]
         so the composite observer can surface live in-turn states like
         [`Executing`]. The matching [mark_turn_finished] in the finally
         block clears the field, preventing stale state on idle keepers. *)
               Keeper_registry.mark_turn_started ~base_path:config.base_path ~wake meta.name;
               let meta =
                 match Keeper_registry.get ~base_path:config.base_path meta.name with
                 | Some entry ->
                   let () =
                     match
                       write_meta_with_merge
                         ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                         config
                         entry.meta
                     with
                     | Ok () -> ()
                     | Error err ->
                       Otel_metric_store.inc_counter
                         Keeper_metrics.(to_string WriteMetaFailures)
                         ~labels:[ "keeper", entry.meta.name; "phase", Keeper_oas_execution_error_phase.(to_label Turn_start) ]
                         ();
                       Log.Keeper.warn
                         ~keeper_name:entry.meta.name
                         "%s: turn-start write_meta_with_merge failed: %s"
                         entry.meta.name
                         err
                   in
                   entry.meta
                 | None -> meta
               in
               Keeper_registry.mark_turn_measurement ~base_path:config.base_path meta.name;
               (match Keeper_registry.get ~base_path:config.base_path meta.name with
                | Some { current_turn_observation = Some { measurement = Some _; _ }; _ }
                  ->
                  Keeper_registry.set_turn_decision_stage
                    ~base_path:config.base_path
                    meta.name
                    Keeper_registry.Decision_active_guard_ok
                | _ -> ());
               let (run_result, turn_state), latency_ms =
                 (* Cancel-safe cleanup (#9747): stdlib [Fun.protect] wraps cleanup
           exceptions in [Fun.Finally_raised], losing the outer
           [Eio.Cancel.Cancelled]. Cleanup here swallows Cancelled (the
           outer one is already in flight) and logs non-cancel exceptions
           instead of propagating them. *)
                 let cleanup () =
                   (try unsubscribe_event_bus () with
                    | Eio.Cancel.Cancelled _ -> ()
                    | e ->
                      Log.Keeper.warn
                        ~keeper_name:meta.name
                        "%s: unsubscribe_event_bus in turn cleanup raised: %s"
                        meta.name
                        (Printexc.to_string e);
                      Otel_metric_store.inc_counter
                        Keeper_metrics.(to_string TurnCleanupFailures)
                        ~labels:[ "keeper", meta.name; "site", Keeper_turn_cleanup_failure_site.(to_label Unsubscribe_event_bus) ]
                        ());
                   try
                     Keeper_registry.mark_turn_finished
                       ~base_path:config.base_path
                       meta.name
                   with
                   | Eio.Cancel.Cancelled _ -> ()
                   | e ->
                     Log.Keeper.warn
                       ~keeper_name:meta.name
                       "%s: mark_turn_finished in turn cleanup raised: %s"
                       meta.name
                       (Printexc.to_string e);
                     Otel_metric_store.inc_counter
                       Keeper_metrics.(to_string TurnCleanupFailures)
                       ~labels:[ "keeper", meta.name; "site", Keeper_turn_cleanup_failure_site.(to_label Mark_turn_finished) ]
                       ()
                 in
                 match
                   Keeper_context_runtime.timed (fun () ->
                     match Eio_context.get_clock () with
                     | Error msg -> Error (Agent_sdk.Error.Internal msg), turn_state
                     | Ok clock ->
                       start_background_turn_event_bus_drain ~clock;
                       let { Keeper_unified_turn_retry_setup.current_turn_phase_elapsed_ms }
                         =
                         Keeper_unified_turn_retry_setup.build
                           ~now:(fun () -> Eio.Time.now clock)
                       in
                       let run_result, turn_state =
                         Keeper_unified_turn_execution.run
                           { attempt = 1
                           ; base_dir
                           ; build_turn_prompt
                           ; channel
                           ; continuation_delivery_channel
                           ; hitl_resolution
                           ; cleanup
                           ; config
                           ; drain_turn_event_bus
                           ; event_bus
                           ; event_bus_integrity_error_snapshot
                           ; tool_completed_count_snapshot
                           ; generation
                           ; keeper_turn_id
                           ; meta
                           ; turn_ctx_cell
                           ; observation
                           ; profile_defaults
                           ; publication_recovery
                           ; shared_context
                           ; trajectory_acc
                           ; turn_id = keeper_turn_id
                           }
                           ~initial_execution
                           ~turn_state
                           ~current_turn_phase_elapsed_ms
                           ~user_message
                           ~registry_base_path
                           ~record_streaming_cancelled_observation
                           ~runtime_id_of_meta
                           ~start_background_turn_event_bus_drain
                       in
                       run_result, turn_state
                    )
                 with
                 | result ->
                   cleanup ();
                   result
                 | exception e ->
                   let backtrace = Printexc.get_raw_backtrace () in
                   cleanup ();
                   Printexc.raise_with_backtrace e backtrace
               in
               let turn_event_bus =
                 drain_turn_event_bus ~site:"turn_finalize_capture" ()
               in
               (match turn_event_bus.correlation_id with
                | Some correlation_id ->
                  Keeper_registry.set_last_correlation_id
                    ~base_path:config.base_path
                    meta.name
                    correlation_id
                | None -> ());
               let event_bus_manifest_status =
                 if turn_event_bus.event_count > 0 then "observed" else "empty"
               in
               let turn_state =
                 Keeper_unified_turn_manifest.append_manifest
                   ~config
                   ~runtime_manifest_context
                   ~turn_start
                   ~turn_state
                   ~site:"event_bus_correlated"
                   ~status:event_bus_manifest_status
                   ~clock_refs:
                     (Keeper_runtime_manifest.clock_refs_for_context
                        runtime_manifest_context
                        ~event:Keeper_runtime_manifest.Event_bus_correlated
                        ?event_bus_correlation_id:turn_event_bus.correlation_id
                        ?event_bus_run_id:turn_event_bus.run_id
                        ?caused_by:turn_event_bus.caused_by ())
                   ~decision:
                     (Keeper_runtime_manifest.with_payload_role ~payload_role:Operator_evidence
                        (turn_event_bus_manifest_decision turn_event_bus))
                   Keeper_runtime_manifest.Event_bus_correlated
               in
               let degraded_retry_info = turn_state.degraded_retry_info in
               let degraded_retry_applied = Option.is_some degraded_retry_info in
               let degraded_retry_runtime =
                 Option.map
                   (fun (retry : EC.degraded_retry) -> retry.next_runtime)
                   degraded_retry_info
               in
               let fallback_reason =
                 Option.map
                   (fun (retry : EC.degraded_retry) -> retry.fallback_reason)
                   degraded_retry_info
               in
               (match run_result with
                | Error err when EC.is_input_required_error err ->
                  (* InputRequired: special stop condition (not a failure).
                     mark_terminal_error already emitted FSM Cancelled
                     transition and info-level log. Surface as Ok so the
                     keeper cycle does not enter failure processing. *)
                  finalize_trajectory_acc
                    ~config
                    ~keeper_name:meta.name
                    trajectory_acc
                    (Trajectory.Gated "input_required");
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string Turns)
                    ~labels:[ "keeper", meta.name; "outcome", "input_required" ]
                    ();
                  let turn_state =
                    { turn_state with cycle_completed = true }
                  in
                  post_turn_complete_task ~cycle_completed:turn_state.cycle_completed;
                  Ok meta, turn_state
                | Error err ->
                  (match
                     require_last_execution_for_finalize
                       ~keeper_name:meta.name
                       turn_state
                   with
                   | Error missing_err -> Error missing_err, turn_state
                   | Ok final_execution ->
                     finalize_trajectory_acc
                       ~config
                       ~keeper_name:meta.name
                       trajectory_acc
                       (Trajectory.Failed (Agent_sdk.Error.to_string err));
                  let e_str = Agent_sdk.Error.to_string err in
                  let is_transient = EC.is_transient_network_error err in
                  (match err with
                      | Agent_sdk.Error.Api (Timeout _) ->
                        Otel_metric_store.inc_counter
                          Keeper_metrics.(to_string OasTimeoutClassifications)
                          ~labels:[ "classification", "transient_network" ]
                          ()
                      | _ -> ());
                  let is_server_parse_rejection = EC.is_server_rejected_parse_error err in
                  let is_auto_recoverable = EC.is_auto_recoverable_turn_error err in
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string Turns)
                    ~labels:[ "keeper", meta.name; "outcome", "failure" ]
                    ();
                  (if EC.is_provider_timeout_error err
                   then
                     Keeper_turn_fsm.emit_transition
                       ~keeper_name:meta.name
                       ~turn_id:keeper_turn_id
                       ~prev:Keeper_turn_fsm.Streaming
                       (Keeper_turn_fsm.Cancelled
                          Keeper_turn_fsm.Cancelled_provider_timeout)
                   else
                     let fsm_failure_reason =
                       if EC.is_receipt_lost_error err
                       then
                         Keeper_turn_fsm.Failure_receipt_lost
                           { primary_error = e_str; fallback_path = None }
                      else
                        match Keeper_turn_driver.classify_masc_internal_error err with
                         | _ ->
                           Keeper_turn_fsm.Failure_provider_error
                             { kind = sdk_error_kind err; detail = short_preview e_str }
                     in
                     Keeper_turn_fsm.emit_transition
                       ~keeper_name:meta.name
                       ~turn_id:keeper_turn_id
                       ~prev:Keeper_turn_fsm.Streaming
                       (Keeper_turn_fsm.Failed fsm_failure_reason));
                  let log_keeper_cycle_failed =
                    if EC.should_warn_keeper_cycle_failed err
                    then Log.Keeper.warn
                    else Log.Keeper.error
                  in
                  log_keeper_cycle_failed
                    ~keeper_name:meta.name
                    "%s: keeper cycle FAILED runtime=%s max_context=%d context_budget=%d \
                     primary_budget=%d requested_override=%s system_and_user_bytes=%d \
                     latency=%dms%s error=%s"
                    meta.name
                    final_execution.runtime_id
                    final_execution.max_context
                    final_execution.max_context_resolution.effective_budget
                    final_execution.max_context_resolution.primary_budget
                    (match
                       final_execution.max_context_resolution.requested_override
                     with
                     | Some requested -> string_of_int requested
                     | None -> "none")
                    (String.length system_prompt + String.length user_message)
                    latency_ms
                    (if is_server_parse_rejection
                     then " (server parse rejection, auto-recoverable)"
                     else if is_transient
                     then " (transient, cooldown preserved)"
                     else if EC.should_warn_keeper_cycle_failed err
                     then " (policy handled)"
                     else "")
                    (short_preview e_str);
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string OasExecutionErrors)
                    ~labels:[ "keeper", meta.name; "phase", Keeper_oas_execution_error_phase.(to_label Cycle_failed) ]
                    ();
                  let updated_meta =
                    Keeper_unified_metrics.update_metrics_from_failure
                      meta
                      ~latency_ms
                      ~observation
                      ~reason:e_str
                      ~sdk_error:err
                      ()
                  in
                  let e_str = Agent_sdk.Error.to_string err in
                  let terminal_reason =
                    Keeper_turn_terminal.of_failure
                      ~raw_error:e_str
                      err
                  in
                  (match
                     registry_failure_reason_of_terminal_reason
                       terminal_reason
                       ~raw_error:e_str
                   with
                   | Some failure_reason ->
                     Keeper_registry.set_failure_reason
                       ~base_path:config.base_path
                       meta.name
                       (Some failure_reason)
                   | None -> ());
                  Keeper_unified_metrics.append_decision_record
                    ~config
                    ~meta:updated_meta
                    ~turn_ctx_cell
                    ~observation
                    ~latency_ms
                    ~outcome:"error"
                    ~degraded_retry_applied
                    ?degraded_retry_runtime
                    ?fallback_reason:
                      (Option.map EC.degraded_retry_reason_to_string fallback_reason)
                    ~error:e_str
                    ~terminal_reason
                    ();
                  (* #9769 root fix: heartbeat-field-merge prevents the
             turn-failure retry from clobbering heartbeat-owned fields metadata fields, which was the
dominant source of the observed CAS race exhaustion after
             keeper OAS timeout. *)
                  (match
                     write_meta_with_merge
                       ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                       config
                       updated_meta
                   with
                   | Ok () -> ()
                   | Error msg ->
                     Otel_metric_store.inc_counter
                       Keeper_metrics.(to_string WriteMetaFailures)
                       ~labels:
                         [ "keeper", updated_meta.name
                         ; ( "phase"
                           , if is_version_conflict_error msg
                             then "turn_failure_cas_race"
                             else "turn_failure" )
                         ]
                       ();
                     if is_version_conflict_error msg
                     then
                       Log.Keeper.warn
                         ~keeper_name:updated_meta.name
                         "write_meta lost CAS race after retries (turn failure path): %s"
                         msg
                     else
                       Log.Keeper.error
                         ~keeper_name:updated_meta.name
                         "write_meta failed after unified turn failure: %s"
                         msg);
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string WriteMetaCycleFailures)
                    ~labels:[ "keeper", meta.name; "site", Keeper_write_meta_cycle_failure_site.(to_label Turn_failure) ]
                    ();
                  (* RFC-0313: route the failure (total over sdk_error), retain
                     the exact final execution identity, and record failure plus
                     telemetry here. Queue ownership lives one boundary out:
                     the heartbeat settles the current lease and, for
                     [Escalate_judgment], enqueues its typed successor in the
                     same durable event-queue transaction. *)
                  let failure_route =
                    Keeper_runtime_failure_route.route_of_error
                      ~boundary:Keeper_runtime_failure_route.Oas_execution
                      err
                  in
                  let overflow_recovery =
                    (* The checkpoint helper reports [Ok] only after the
                       compacted checkpoint is durably saved. The heartbeat
                       settles the owning lease after this cycle returns, so
                       no source stimulus is acknowledged ahead of it. *)
                    recover_provider_context_overflow_in_lane
                      ~config
                      ~base_dir
                      ~meta
                      ~primary_model_max_tokens:final_execution.max_context
                      err
                  in
                  let source_lease_disposition, turn_state =
                    append_provider_overflow_manifest
                      ~config
                      ~runtime_manifest_context
                      ~turn_start
                      ~turn_state
                      ~base_dir
                      overflow_recovery
                  in
                  exact_failure_execution :=
                    Some
                      ( final_execution.runtime_id
                      , failure_route
                      , source_lease_disposition );
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string FailureRoute)
                    ~labels:
                      [ "keeper", meta.name
                      ; (* RFC-0132-EXEMPT: internal observability — real runtime identity on a metric label, not a redacted public surface *)
                        "runtime", final_execution.runtime_id
                      ; "route", Keeper_runtime_failure_route.route_kind_label failure_route
                      ; "class", Keeper_runtime_failure_route.route_class_label failure_route
                      ]
                    ();
                  Keeper_unified_turn_failure.record_failure_observation
                    ~config
                    ~meta
                    ~is_auto_recoverable
                    ~err
                    ~error_text:e_str;
                  (* RFC-0221 §3.4: emit turn_completed telemetry on all exit paths
                     after Agent.run() — success path emits via
                     Keeper_unified_turn_success → keeper_unified_metrics_snapshot;
                     failure path emits here directly. *)
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string TurnCompleted)
                    ~labels:[("keeper", meta.name)]
                    ();
                  Error err, turn_state)
                | Ok result ->
                  (match
                     require_last_execution_for_finalize
                       ~keeper_name:meta.name
                       turn_state
                   with
                   | Error missing_err -> Error missing_err, turn_state
                   | Ok final_execution ->
                     finalize_trajectory_acc
                       ~config
                       ~keeper_name:meta.name
                       trajectory_acc
                       Trajectory.Completed;
                  (* SSOT: success-path terminal FSM transitions
                     (Streaming -> Completing -> Done) are emitted once inside
                     [Keeper_unified_turn_success.handle]. Do not duplicate them
                     here; this is the sole caller of that function. *)
                  let success =
                    Keeper_unified_turn_success.handle
                      ~config
                      ~base_dir
                      ~meta
                      ~turn_ctx_cell
                      ~observation
                      ~final_execution
                      ~latency_ms
                      ~degraded_retry_applied
                      ~degraded_retry_runtime
                      ~fallback_reason
                      ~current_turn_blocker_info:turn_state.current_turn_blocker_info
                      ~keeper_turn_id
                      result
                  in
                  (match success with
                   | Keeper_unified_turn_success.Completed updated_meta ->
                     (* Cycle 45: KeeperTaskAcquisition.tla TurnComplete post-action. *)
                     let turn_state =
                       { turn_state with cycle_completed = true }
                     in
                     post_turn_complete_task ~cycle_completed:turn_state.cycle_completed;
                     Ok updated_meta, turn_state)))))
  in
  let append_phase_gate_decision_for_gate turn_plan turn_state =
    Keeper_unified_turn_manifest.append_phase_gate_decision
      ~config
      ~runtime_manifest_context
      ~turn_start
      ~turn_state
      turn_plan
  in
  let phase_gate_outcome, turn_state =
    Keeper_unified_turn_phase_gate.decide_and_record
      ~config
      ~meta
      ~generation
      ~keeper_turn_id
      ~append_phase_gate_decision:append_phase_gate_decision_for_gate
      ~turn_state
      ~registry_base_path
  in
  let failure_of_error error =
    match !exact_failure_execution with
    | Some (runtime_id, route, source_lease_disposition) ->
      { error; runtime_id; route; source_lease_disposition }
    | None ->
      { error
      ; runtime_id = Keeper_meta_contract.runtime_id_of_meta meta
      ; route =
          Keeper_runtime_failure_route.route_of_error
            ~boundary:Keeper_runtime_failure_route.Masc_execution
            error
      ; source_lease_disposition = Follow_failure_route
      }
  in
  match phase_gate_outcome with
  | Keeper_unified_turn_phase_gate.Phase_gate_cancelled meta ->
    Ok (Turn_cancelled meta)
  | Keeper_unified_turn_phase_gate.Phase_gate_skipped meta ->
    Ok (Turn_skipped meta)
  | Keeper_unified_turn_phase_gate.Phase_gate_terminal_error err ->
    Error (failure_of_error err)
  | Keeper_unified_turn_phase_gate.Phase_gate_proceed phase_opt ->
    let result, _turn_state = main_path turn_state phase_opt in
    result
    |> Result.map (fun meta -> Turn_completed meta)
    |> Result.map_error failure_of_error
;;
