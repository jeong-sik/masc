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
include Keeper_turn_liveness
include Keeper_turn_runtime_budget
include Keeper_unified_turn_types

(* RFC-0132 PR-2: removed dead [runtime_lane_label] (0 callers). *)

include Keeper_unified_turn_phase_plan

let run_keeper_cycle
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(observation : Keeper_world_observation.world_observation)
      ~(generation : int)
      ?(channel : Keeper_world_observation.keeper_cycle_channel = Scheduled_autonomous)
      ?(turn_decision : Keeper_world_observation.keeper_cycle_decision option)
      ?shared_context
      ?event_bus
      ()
  : (keeper_meta, Agent_sdk.Error.sdk_error) result
  =
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
  (* Decide turn_id at function entry so phase-gate / runtime-routing /
     livelock skip paths can include it in the receipt and observability
     stream.  Previously this was [let turn_id = ...] only after several
     pre-dispatch checks (see turn_livelock guard below), leaving silent
     skip paths without a turn correlator. *)
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
    ; post_commit_failure_reason = None
    ; paused_meta_override = None
    ; current_turn_blocker_info = None
    ; last_execution = None
    ; last_provider_timeout_budget = None
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
         let profile_defaults =
           Keeper_types_profile.load_keeper_profile_defaults meta.name
         in
         let effective_runtime_runtime_name = effective_runtime_id in
         (match
            Keeper_unified_turn_pre_dispatch.build_runtime_execution
              ~meta
              ~profile_defaults
              ~runtime_id:effective_runtime_runtime_name
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
          | Ok initial_execution ->
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
              ~max_tokens:initial_execution.max_tokens
              ~max_context:initial_execution.max_context
              ~effective_budget:initial_execution.max_context_resolution.effective_budget
              ~temperature:initial_execution.temperature
              ~generation;
            let turn_id = keeper_turn_id in
            (match
               Keeper_turn_livelock.guard_and_record_turn_start
                 ~base_path:registry_base_path
                 ~keeper:meta.name
                 ~turn_id
                 ~max_attempts:(turn_livelock_max_attempts ())
                 ~stuck_after_sec:(turn_livelock_stuck_after_sec ())
                 ()
             with
             | Keeper_turn_livelock.Blocked reason ->
               ( Keeper_unified_turn_livelock_block.handle
                   ~config
                   ~meta
                   ~generation
                   ~keeper_turn_id
                   ~turn_id
                   ~initial_execution
                   ~reason
               , turn_state )
             | Keeper_turn_livelock.Started _ ->
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
               (* RFC-0315: surface the working-state ledger's unresolved
                  loops. The sidecar has persisted (and resume-merged) them
                  since KeeperWorkingStateLifecycle landed, but no prompt ever
                  read them back — persisted-but-never-shown. *)
               let active_open_loops =
                 let session_dir =
                   Filename.concat
                     (session_base_dir config)
                     (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                 in
                 match
                   Keeper_agent_run_sidecar.read_persisted_working_state
                     ~keeper_name:meta.name
                     ~latest_path:
                       (Keeper_agent_run_sidecar.latest_working_state_path
                          ~session_dir)
                 with
                 | None -> []
                 | Some state -> state.Keeper_working_state.active_loops
               in
               let system_prompt, user_message =
                 Keeper_unified_prompt.build_prompt
                   ~meta
                   ~base_path:config.base_path
                   ~profile_defaults
                   ?turn_decision
                   ?current_task
                   ~active_goal_summaries
                   ~active_open_loops
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
               let prompt_timeout_metrics =
                 Keeper_agent_run.build_prompt_metrics
                   ~system_prompt
                   ~dynamic_context:""
                   ~user_message
               in
               let prompt_timeout_estimate_tokens =
                 max 1 prompt_timeout_metrics.estimated_total_tokens
               in
               let turn_affordances =
                 Keeper_unified_metrics.observed_affordances_of_observation
                   ~meta
                   observation
               in
               (* 5. Run via OAS Agent.run() with transient-error retry *)
               (* Track whether side-effecting tool calls have been executed.
         If a board_post/comment/shell/file edit succeeded and then a
         transient error occurs, retrying would replay those tool calls and
         produce duplicates. In that case, we propagate the error instead of
         retrying.

         Uses the OAS Event_bus (ToolCalled + ToolCompleted) rather than
         MASC-side observers. The per-turn subscription is scoped by
         [filter_agent meta.name], so no cross-keeper contamination.
         The same events now drive Streaming⇄Awaiting_tool_result FSM
         transitions unconditionally (see
         [Keeper_unified_turn_event_bus.record_fsm_tool_transitions]). *)
               let turn_state =
                 { turn_state with last_execution = Some initial_execution }
               in
               let turn_event_bus_state =
                 Keeper_unified_turn_event_bus.create
                   ?event_bus
                 (* RFC-0197 P1-4a: mirror the in-flight tool count into the
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
               let committed_mutating_tools_snapshot () =
                 Keeper_unified_turn_event_bus.committed_mutating_tools
                   turn_event_bus_state
               in
               let event_bus_integrity_error_snapshot () =
                 Keeper_unified_turn_event_bus.integrity_error turn_event_bus_state
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
               Keeper_registry.mark_turn_started ~base_path:config.base_path meta.name;
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
                       let { Keeper_unified_turn_retry_setup.timeout_sec
                           ; turn_started_at
                           ; turn_deadline
                           ; remaining_turn_budget_s
                           ; elapsed_ms
                           ; current_turn_phase_elapsed_ms
                           ; max_idle_turns
                           }
                         =
                         Keeper_unified_turn_retry_setup.build
                           ~now:(fun () -> Eio.Time.now clock)
                           ~keeper_name:meta.name
                           ~channel
                           ~turn_affordances
                       in
                       let run_result, turn_state =
                         Keeper_unified_turn_execution.run
                           { attempt = 1
                           ; base_dir
                           ; build_turn_prompt
                           ; channel
                           ; cleanup
                           ; committed_mutating_tools_snapshot
                           ; config
                           ; drain_turn_event_bus
                           ; event_bus
                           ; event_bus_integrity_error_snapshot
                           ; generation
                           ; keeper_turn_id
                           ; meta
                           ; turn_ctx_cell
                           ; observation
                           ; profile_defaults
                           ; prompt_timeout_estimate_tokens
                           ; shared_context
                           ; trajectory_acc
                           ; turn_affordances
                           ; turn_id = keeper_turn_id
                           }
                           ~initial_execution
                           ~turn_state
                           ~timeout_sec
                           ~remaining_turn_budget_s
                           ~current_turn_phase_elapsed_ms
                           ~max_idle_turns
                           ~user_message
                           ~registry_base_path
                           ~degraded_retry_slot_phase_budget_sec
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
                 match turn_event_bus.correlation_id with
                 | Some _ -> "observed"
                 | None ->
                   if turn_event_bus.context_compact_started_count > 0
                      || turn_event_bus.context_compacted_count > 0
                      || turn_event_bus.overflow_imminent <> None
                   then "observed"
                   else "empty"
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
               let run_result =
                 match event_bus_integrity_error_snapshot () with
                 | Some integrity_err -> Error integrity_err
                 | None -> run_result
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
                  (match Keeper_turn_driver.classify_masc_internal_error err with
                   | Some (Keeper_turn_driver.Provider_timeout _) ->
                     Otel_metric_store.inc_counter
                       Keeper_metrics.(to_string OasTimeoutClassifications)
                       ~labels:[ "classification", "structural_budget" ]
                       ()
                   | Some (Keeper_turn_driver.Turn_timeout _) ->
                     Otel_metric_store.inc_counter
                       Keeper_metrics.(to_string OasTimeoutClassifications)
                       ~labels:[ "classification", "turn_wall_clock" ]
                       ()
                   | _ ->
                     (match err with
                      | Agent_sdk.Error.Api (Timeout { message }) ->
                        let classification =
                          if is_transient
                          then "transient_network"
                          else if EC.is_structural_oas_timeout_message message
                          then "structural_budget"
                          else "other_timeout"
                        in
                        Otel_metric_store.inc_counter
                          Keeper_metrics.(to_string OasTimeoutClassifications)
                          ~labels:[ "classification", classification ]
                          ()
                      | _ -> ()));
                  let is_server_parse_rejection = EC.is_server_rejected_parse_error err in
                  let is_auto_recoverable = EC.is_auto_recoverable_turn_error err in
                  let ambiguous_commit_tools =
                    EC.ambiguous_side_effect_commit_tools
                      ~tool_names:(committed_mutating_tools_snapshot ())
                      err
                  in
                  let is_ambiguous_partial = ambiguous_commit_tools <> [] in
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
                  let failure_context_ratio =
                    if final_execution.max_context <= 0
                    then 0.0
                    else
                      float_of_int prompt_timeout_estimate_tokens
                      /. float_of_int final_execution.max_context
                  in
                  log_keeper_cycle_failed
                    ~keeper_name:meta.name
                    "%s: keeper cycle FAILED runtime=%s max_context=%d context_budget=%d \
                     primary_budget=%d requested_override=%s estimated_input_tokens=%d \
                     context_ratio=%.4f latency=%dms%s error=%s"
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
                    prompt_timeout_estimate_tokens
                    failure_context_ratio
                    latency_ms
                    (if is_ambiguous_partial
                     then " (ambiguous partial commit)"
                     else if is_server_parse_rejection
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
                  let failure_meta_base =
                    match turn_state.paused_meta_override with
                    | Some paused_meta -> paused_meta
                    | None -> meta
                  in
                  let updated_meta =
                    Keeper_unified_metrics.update_metrics_from_failure
                      failure_meta_base
                      ~latency_ms
                      ~observation
                      ~reason:e_str
                      ~sdk_error:err
                      ()
                  in
                  let err, updated_meta =
                    if is_ambiguous_partial
                    then (
                      (* Ambiguous partial commit must not auto-resume silently.
                 The keeper is paused and an explicit continue gate is
                 raised for the operator. Approving the gate auto-resumes
                 the keeper; rejecting it leaves the keeper paused. *)
                      let committed_tools = ambiguous_commit_tools in
                      let turn_event_summary = turn_event_bus in
                      let failure_reason =
                        Option.value
                          ~default:
                            (Keeper_registry.Ambiguous_partial_commit
                               { kind = Keeper_registry.Post_commit_failure
                               ; detail = e_str
                               })
                          turn_state.post_commit_failure_reason
                      in
                      Keeper_registry.set_failure_reason
                        ~base_path:config.base_path
                        meta.name
                        (Some failure_reason);
                      match
                        sync_keeper_paused_state ~config ~meta:updated_meta ~paused:true
                      with
                      | Ok paused_meta ->
                        let approval_id =
                          enqueue_partial_commit_continue_gate
                            ~config
                            ~meta:paused_meta
                            ~failure_reason
                            ~committed_tools
                            ~error_detail:e_str
                        in
                        Otel_metric_store.inc_counter
                          Keeper_metrics.(to_string TurnErrorAfterTools)
                          ~labels:[ "keeper", meta.name; "reason", "ambiguous_partial" ]
                          ();
                        Log.Keeper.warn
                          ~keeper_name:meta.name
                          "%s: ambiguous partial commit \
                           (committed_mutating_tools=[%s], turn_events=%d, \
                           payload_kinds=[%s], reason=%s); paused keeper and opened \
                           continue gate id=%s"
                          meta.name
                          (String.concat ", " committed_tools)
                          turn_event_summary.event_count
                          (String.concat ", " turn_event_summary.payload_kinds)
                          (Keeper_registry.failure_reason_to_string failure_reason)
                          approval_id;
                        err, paused_meta
                      | Error sync_err ->
                        let combined_err =
                          Agent_sdk.Error.Internal
                            (Printf.sprintf
                               "%s: ambiguous partial commit pause sync failed: %s \
                                (original_error=%s)"
                               meta.name
                               sync_err
                               (short_preview e_str))
                        in
                        Log.Keeper.error
                          ~keeper_name:meta.name
                          "%s"
                          (Agent_sdk.Error.to_string combined_err);
                        Otel_metric_store.inc_counter
                          Keeper_metrics.(to_string RuntimeSyncFailures)
                          ~labels:
                            [ "keeper", meta.name; "site", "ambiguous_partial_pause" ]
                          ();
                        combined_err, updated_meta)
                    else err, updated_meta
                  in
                  let e_str = Agent_sdk.Error.to_string err in
                  let terminal_reason =
                    Keeper_turn_terminal.of_failure
                      ~post_commit_ambiguous:is_ambiguous_partial
                      ~raw_error:e_str
                      err
                  in
                  if not is_ambiguous_partial
                  then (
                    match
                      registry_failure_reason_of_terminal_reason
                        terminal_reason
                        ~raw_error:e_str
                    with
                    | Some failure_reason ->
                      (* masc_keeper_contract_violations_total (RFC exhaustive
                         match, not [_ -> ()]): a new failure_reason variant
                         must explicitly opt in or out of this counter rather
                         than silently landing in a catch-all. *)
                      (match failure_reason with
                       | Keeper_registry.Completion_contract_violation _ ->
                         Otel_metric_store.inc_counter
                           Keeper_metrics.(to_string ContractViolations)
                           ~labels:[ "keeper", meta.name ]
                           ()
                       | Keeper_registry.Heartbeat_consecutive_failures _
                       | Keeper_registry.Turn_consecutive_failures _
                       | Keeper_registry.Stale_turn_timeout _
                       | Keeper_registry.Stale_termination_storm _
                       | Keeper_registry.Stale_fleet_batch _
                       | Keeper_registry.Provider_timeout_loop _
                       | Keeper_registry.Provider_runtime_error _
                       | Keeper_registry.Ambiguous_partial_commit _
                       | Keeper_registry.Fiber_unresolved _
                       | Keeper_registry.Exception _
                       | Keeper_registry.Turn_overflow_pause
                       | Keeper_registry.Turn_livelock_pause -> ());
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
                    ~outcome:(if is_ambiguous_partial then "partial" else "error")
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
                  if is_ambiguous_partial
                  then (
                    let failure_reason =
                      Option.value
                        ~default:
                          (Keeper_registry.Ambiguous_partial_commit
                             { kind = Keeper_registry.Post_commit_failure
                             ; detail = e_str
                             })
                        turn_state.post_commit_failure_reason
                    in
                    Keeper_registry.set_failure_reason
                      ~base_path:config.base_path
                      meta.name
                      (Some failure_reason);
                    let committed_tools = ambiguous_commit_tools in
                    let turn_event_summary = turn_event_bus in
                    Log.Keeper.info
                      ~keeper_name:meta.name
                      "%s: reconcile-required failure latched as %s after \
                       committed_mutating_tools [%s] (turn_events=%d, payload_kinds=[%s])"
                      meta.name
                      (Keeper_registry.failure_reason_to_string failure_reason)
                      (String.concat ", " committed_tools)
                      turn_event_summary.event_count
                      (String.concat ", " turn_event_summary.payload_kinds));
                  (* RFC-0313 W2: route the failure (total over sdk_error) and
                     record alongside the legacy machinery. The route is
                     observe-only until the W3 flip: pacing shadow takes the
                     typed retry_after hint, the route counter feeds Grafana,
                     and Escalate_judgment enqueues a judgment stimulus
                     ([enqueue_if_missing] identity-dedups repeats; no
                     dedicated turn_reason, so scheduling cooldowns are
                     unchanged). Placed before the escalate call, which may
                     raise [Keeper_fiber_crash] and must not skip the
                     observations. *)
                  let failure_route = Keeper_runtime_failure_route.route_of_error err in
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
                  Keeper_pacing_shadow.observe_failure
                    ~keeper_name:meta.name
                    ~runtime_id:final_execution.runtime_id
                    ~retry_after:
                      (Keeper_runtime_failure_route.retry_after_of_route failure_route);
                  (match failure_route with
                   | Keeper_runtime_failure_route.Escalate_judgment { judgment; detail } ->
                     let fj : Keeper_event_queue.failure_judgment =
                       { fj_runtime_id = final_execution.runtime_id
                       ; fj_judgment = judgment
                       ; fj_detail = detail
                       }
                     in
                     Keeper_registry_event_queue.enqueue
                       ~base_path:config.base_path
                       meta.name
                       { post_id = Keeper_event_queue.failure_judgment_post_id fj
                       ; urgency = Keeper_event_queue.Normal
                       ; arrived_at = Time_compat.now ()
                       ; payload = Keeper_event_queue.Failure_judgment fj
                       }
                   | Keeper_runtime_failure_route.Retry_after_pacing _
                   | Keeper_runtime_failure_route.Rotate_now _ -> ());
                  Keeper_unified_turn_failure.record_failure_and_maybe_escalate
                    ~config
                    ~meta
                    ~updated_meta
                    ~is_auto_recoverable
                    ~pacing_enforced:(Keeper_pacing_shadow.pacing_enforced ())
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
                  (* RFC-0313 W1 shadow: a success clears this runtime's
                     shadow revisit. *)
                  Keeper_pacing_shadow.observe_success
                    ~keeper_name:meta.name
                    ~runtime_id:final_execution.runtime_id;
                  (* SSOT: success-path terminal FSM transitions
                     (Streaming -> Completing -> Done) are emitted once inside
                     [Keeper_unified_turn_success.handle]. Do not duplicate them
                     here; this is the sole caller of that function. *)
                  let updated_meta =
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
                      ~last_provider_timeout_budget:turn_state.last_provider_timeout_budget
                      ~current_turn_blocker_info:turn_state.current_turn_blocker_info
                      ~keeper_turn_id
                      result
                  in
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
  match phase_gate_outcome with
  | Keeper_unified_turn_phase_gate.Phase_gate_terminal_ok meta -> Ok meta
  | Keeper_unified_turn_phase_gate.Phase_gate_terminal_error err -> Error err
  | Keeper_unified_turn_phase_gate.Phase_gate_proceed phase_opt ->
    let result, _turn_state = main_path turn_state phase_opt in
    result
;;
