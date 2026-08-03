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

type source_disposition =
  | Follow_failure_route
  | Pause_after_transcript_corruption of { detail : string }

type turn_failure =
  { error : Agent_sdk.Error.sdk_error
  ; runtime_id : string
  ; route : Keeper_runtime_failure_route.route
  ; source_disposition : source_disposition
  ; deferred_runtime_lane : Keeper_turn_driver.deferred_runtime_lane option
  }

let turn_failure_of_error
      ~runtime_id
      ~fallback_boundary
      ~exact_failure_execution
      ~deferred_runtime_lane
      error
  =
  match exact_failure_execution with
  | Some (runtime_id, route, source_disposition) ->
    { error; runtime_id; route; source_disposition; deferred_runtime_lane }
  | None ->
    { error
    ; runtime_id
    ; route =
        Keeper_runtime_failure_route.route_of_error
          ~boundary:fallback_boundary
          error
    ; source_disposition = Follow_failure_route
    ; deferred_runtime_lane
    }
;;

let transcript_corruption error =
  match Keeper_internal_error.classify_masc_internal_error error with
  | Some (Keeper_internal_error.Incomplete_tool_transcript { detail; _ }) ->
    Some detail
  | Some
      ( Keeper_internal_error.Runtime_exhausted _
      | Keeper_internal_error.Capacity_backpressure _
      | Keeper_internal_error.Resumable_cli_session _
      | Keeper_internal_error.Accept_rejected _
      | Keeper_internal_error.Internal_unhandled_exception _
      | Keeper_internal_error.Internal_bridge_exception _
      | Keeper_internal_error.Internal_contract_rejected _
      | Keeper_internal_error.Terminal_effect_failed _
      | Keeper_internal_error.Receipt_persistence_failed _
      | Keeper_internal_error.Gate_replay_repair_required _ )
  | None ->
    None
;;

let execution_boundary_of_turn_failure ~transcript_corruption error =
  match
    transcript_corruption,
    Keeper_internal_error.classify_masc_internal_error error
  with
  | Some _, (Some _ | None) ->
    Keeper_runtime_failure_route.Masc_execution
  | None, Some (Keeper_internal_error.Gate_replay_repair_required _) ->
    (* This failure is produced by MASC after host replay and before provider
       dispatch. The shared [Agent_sdk.Error.Internal] carrier must not
       misattribute that local replay boundary to OAS. *)
    Keeper_runtime_failure_route.Masc_execution
  | None,
    Some
      ( Keeper_internal_error.Runtime_exhausted _
      | Keeper_internal_error.Capacity_backpressure _
      | Keeper_internal_error.Resumable_cli_session _
      | Keeper_internal_error.Accept_rejected _
      | Keeper_internal_error.Internal_unhandled_exception _
      | Keeper_internal_error.Internal_bridge_exception _
      | Keeper_internal_error.Internal_contract_rejected _
      | Keeper_internal_error.Incomplete_tool_transcript _
      | Keeper_internal_error.Terminal_effect_failed _
      | Keeper_internal_error.Receipt_persistence_failed _ )
  | None, None ->
    Keeper_runtime_failure_route.Oas_execution
;;

type turn_success =
  | Turn_completed of keeper_meta
  | Turn_checkpointed of keeper_meta
  | Turn_input_required of keeper_meta
  | Turn_cancelled of keeper_meta
  | Turn_skipped of keeper_meta

let turn_success_of_stop_reason ~meta = function
  | Runtime_agent.Completed -> Turn_completed meta
  | Runtime_agent.Yielded_to_chat_waiting _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Awaiting_external_effect _
  | Runtime_agent.Yielded_after_repeated_tool_call _ ->
    Turn_checkpointed meta
  | Runtime_agent.InputRequired _ -> Turn_input_required meta
;;

let chat_yield_request ~base_path ~keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | None -> Error (Printf.sprintf "keeper not registered: %s" keeper_name)
  | Some _ ->
    if Keeper_turn_admission.chat_waiting ~base_path ~keeper_name
    then Ok (Some Keeper_agent_run.{ reason = Chat_waiting })
    else Ok None
;;

let autonomous_yield_request ~base_path ~keeper_name =
  match chat_yield_request ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok (Some _) as request -> request
  | Ok None ->
    (match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
     | Error _ as error -> error
     | Ok pending ->
       if Keeper_event_queue.is_empty pending
       then Ok None
       else (
         let summary =
           Keeper_agent_run.durable_stimulus_summary ~now:(Time_compat.now ()) pending
         in
         Log.Keeper.info
           ~keeper_name
           "autonomous turn yields to durable stimulus: %s"
           (Keeper_agent_run.durable_stimulus_summary_to_string summary);
         Ok
           (Some
              Keeper_agent_run.
                { reason = Durable_stimulus_waiting summary })))
;;

let is_manual_compaction_payload = function
  | Keeper_event_queue.Manual_compaction_requested -> true
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Board_attention _
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Fusion_completed _
  | Keeper_event_queue.Bg_completed _
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Hitl_resolved _
  | Keeper_event_queue.Goal_assigned _
  | Keeper_event_queue.Goal_reconciliation_ready _
  | Keeper_event_queue.Completion_authority_rejected _ ->
    false
;;

let manual_compaction_preemption_request ~wake ~now pending =
  let source_can_yield =
    match wake with
    | Keeper_registry.Woken (_ :: _ as payloads) ->
      not (List.exists is_manual_compaction_payload payloads)
    | Keeper_registry.Proactive_tick | Keeper_registry.Woken [] -> false
  in
  if not source_can_yield
  then None
  else
    let stimuli = Keeper_event_queue.to_list pending in
    match
      List.find_opt
        (fun (stimulus : Keeper_event_queue.stimulus) ->
           is_manual_compaction_payload stimulus.payload)
        stimuli
    with
    | None -> None
    | Some selected ->
      let summary = Keeper_agent_run.durable_stimulus_summary ~now pending in
      Some
        Keeper_agent_run.
          { reason =
              Durable_stimulus_waiting
                { summary with
                  head = Some selected
                ; head_age_sec = Float.max 0. (now -. selected.arrived_at)
                }
          }
;;

let manual_compaction_yield_request ~wake ~base_path ~keeper_name =
  match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
  | Error _ as error -> error
  | Ok pending ->
    let now = Time_compat.now () in
    let request = manual_compaction_preemption_request ~wake ~now pending in
    Option.iter
      (fun (request : Keeper_agent_run.autonomous_yield_request) ->
         match request.reason with
         | Keeper_agent_run.Chat_waiting -> ()
         | Keeper_agent_run.Durable_stimulus_waiting summary ->
           Log.Keeper.info
             ~keeper_name
             "autonomous source turn yields to manual compaction: %s"
             (Keeper_agent_run.durable_stimulus_summary_to_string summary))
      request;
    Ok request
;;

let autonomous_yield_request_for_wake ~wake ~base_path ~keeper_name =
  match wake with
  (* A nonempty [Woken] is the event queue input already selected for this
     turn. It may yield for chat delivery. An explicit owner-lane manual
     compaction is the sole successor allowed to preempt at a persisted
     post-tool boundary; the selected source remains pending and resumes after
     compaction. Other queued successors still wait for the source terminal. *)
  | Keeper_registry.Woken (_ :: _) ->
    fun () ->
      (match chat_yield_request ~base_path ~keeper_name with
       | Error _ as error -> error
       | Ok (Some _) as request -> request
       | Ok None ->
         manual_compaction_yield_request
           ~wake
           ~base_path
           ~keeper_name)
  | Keeper_registry.Proactive_tick | Keeper_registry.Woken [] ->
    fun () -> autonomous_yield_request ~base_path ~keeper_name
;;


let run_keeper_cycle
      ~(before_dispatch_authority : unit -> (unit, string) result)
      ?deferred_runtime_lane
      ?on_deferred_runtime_consumed
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(publication_recovery_provider :
          Keeper_publication_recovery_availability.provider)
      ~(observation : Keeper_world_observation.world_observation)
      ~(generation : int)
      ~(wake : Keeper_registry.wake_reason)
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
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
      ; source_disposition = Follow_failure_route
      ; deferred_runtime_lane = None
      }
  | Ok { entry; publication_recovery } ->
  let meta = entry.meta in
  let channel = turn_decision.channel in
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
    let degraded_retry_info =
      Option.map
        (fun (hint : Keeper_turn_driver.deferred_runtime_lane) ->
           let fallback_reason =
             match
               Keeper_error_classify.recoverable_runtime_failure_reason
                 hint.failure
             with
             | Some reason -> reason
             | None -> Keeper_error_classify.Deferred_runtime_lane
           in
           { Keeper_error_classify.next_runtime = hint.next_runtime_id
           ; fallback_reason
           })
        deferred_runtime_lane
    in
    { cycle_completed = false
    ; manifest_seq = 0
    ; current_turn_blocker_info = None
    ; last_execution = None
    ; degraded_retry_info
    ; deferred_runtime_lane = None
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
    : (turn_success, Agent_sdk.Error.sdk_error) result
      * Keeper_unified_turn_execution.turn_state
    =
      let _ = phase_opt in
      let effective_runtime_id =
        match deferred_runtime_lane with
        | Some hint -> hint.Keeper_turn_driver.next_runtime_id
        | None -> Keeper_meta_contract.runtime_id_of_meta meta
      in
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
       | Some meta_after_skip -> Ok (Turn_skipped meta_after_skip), turn_state
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
            Option.iter
              (fun _ ->
                 Option.iter
                   (fun consume -> consume ())
                   on_deferred_runtime_consumed)
              deferred_runtime_lane;
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
                  keeper holds and why it woke. Task absence, a dangling id,
                  and an unavailable backlog remain distinct typed prompt
                  inputs; observation failure must not crash the turn or imply
                  that the keeper holds no task. *)
               let current_task =
                 Keeper_world_observation_inputs.read_current_task ~config ~meta
               in
               let active_goal_summaries =
                 Keeper_unified_prompt.active_goal_summaries ~config ~meta
               in
               let { Keeper_unified_prompt.system_prompt; world_state; user_message } =
                 Keeper_unified_prompt.build_prompt
                   ~meta
                   ~base_path:config.base_path
                   ~profile_defaults
                   ~turn_decision
                   ~current_task
                   ~active_goal_summaries
                   ~observation
                   ()
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
                   ~generation:meta.runtime.nonce ()
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
                 (* The observation frame rides [dynamic_context]: rebuilt fresh
                    every turn and composed into the per-turn system prompt, so
                    it never enters the persisted OAS conversation. Persisting
                    it as a user message re-fed the model its own observations
                    (943/945 identical frames in one live checkpoint, #25193)
                    and starved compaction. Persisted user content is utterances
                    only (wake marker + HITL resolutions). *)
                 { system_prompt; dynamic_context = world_state }
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
                           ; deferred_runtime_lane
                           ; on_deferred_runtime_consumed
                           }
                           ~autonomous_yield_requested:
                             (autonomous_yield_request_for_wake
                                ~wake
                                ~base_path:config.base_path
                                ~keeper_name:meta.name)
                           ~initial_execution
                           ~turn_state
                           ~before_dispatch_authority
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
                  Ok (Turn_input_required meta), turn_state
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
                  let is_provider_wire_error = EC.is_provider_wire_error err in
                  let is_auto_recoverable = EC.is_auto_recoverable_turn_error err in
                  let counts_toward_crash =
                    Keeper_unified_turn_failure.account_failure_counting
                      ~keeper_name:meta.name ~is_auto_recoverable err
                  in
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
                    (String.length system_prompt
                     + String.length world_state
                     + String.length user_message)
                    latency_ms
                    (if is_provider_wire_error && counts_toward_crash
                    then " (provider wire error, counts toward crash threshold)"
                    else if is_provider_wire_error
                    then " (provider wire error, crash counting skipped)"
                    else if is_server_parse_rejection && counts_toward_crash
                     then " (server parse rejection, counts toward crash threshold)"
                     else if is_server_parse_rejection
                     then " (server parse rejection, auto-recoverable: crash counting skipped)"
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
                  (* Route the failure (total over sdk_error), retain the exact
                     final execution identity, and record typed failure plus
                     telemetry here. Exhausted failures remain visible without
                     dispatching a second LLM call. *)
                  let transcript_corruption = transcript_corruption err in
                  let failure_route =
                    Keeper_runtime_failure_route.route_of_error
                      ~boundary:
                        (execution_boundary_of_turn_failure
                           ~transcript_corruption
                           err)
                      err
                  in
                  let source_disposition, turn_state =
                    match transcript_corruption with
                    | Some detail ->
                      Pause_after_transcript_corruption { detail }, turn_state
                    | None ->
                      (* Capacity failures (context overflow, request-body
                         caps, serving-input rejection) follow the ordinary
                         typed failure route. The automatic overflow-compaction
                         recovery that used to branch here was removed
                         (#26546) because it never produced a committed
                         compaction on record. #26545 bounds conversation
                         history only; whole-request provider fit is tracked
                         separately in #26551. *)
                      Follow_failure_route, turn_state
                  in
                  exact_failure_execution :=
                    Some
                      ( final_execution.runtime_id
                      , failure_route
                      , source_disposition );
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
                    ~counts_toward_crash
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
                      ~meta
                      ~turn_ctx_cell
                      ~observation
                      ~channel
                      ~latency_ms
                      ~degraded_retry_applied
                      ~degraded_retry_runtime
                      ~fallback_reason
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
                     Ok
                       (turn_success_of_stop_reason
                          ~meta:updated_meta
                          result.Keeper_agent_run.stop_reason),
                     turn_state)))))
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
  let failure_of_error ?deferred_runtime_lane error =
    turn_failure_of_error
      ~runtime_id:(Keeper_meta_contract.runtime_id_of_meta meta)
      ~fallback_boundary:Keeper_runtime_failure_route.Masc_execution
      ~exact_failure_execution:!exact_failure_execution
      ~deferred_runtime_lane
      error
  in
  match phase_gate_outcome with
  | Keeper_unified_turn_phase_gate.Phase_gate_cancelled meta ->
    Ok (Turn_cancelled meta)
  | Keeper_unified_turn_phase_gate.Phase_gate_skipped meta ->
    Ok (Turn_skipped meta)
  | Keeper_unified_turn_phase_gate.Phase_gate_terminal_error err ->
    Error (failure_of_error err)
  | Keeper_unified_turn_phase_gate.Phase_gate_proceed phase_opt ->
    let result, turn_state = main_path turn_state phase_opt in
    (match result with
     | Ok success -> Ok success
     | Error error ->
       Error
         (failure_of_error
            ?deferred_runtime_lane:turn_state.deferred_runtime_lane
            error))
;;
