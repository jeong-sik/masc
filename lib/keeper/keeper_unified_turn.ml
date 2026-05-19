(** Keeper_unified_turn — Single entry point for keeper cycles via OAS Agent.run().

    Replaces the 3-path dispatcher (social/proactive/autonomy) with a unified
    observe -> prompt -> Agent.run(tools, guardrails, hooks) loop.
    The model decides what to do; code only enforces safety and observes results.

    @since Unified Keeper Loop *)

open Keeper_types
open Keeper_exec_context
module Social = Keeper_social_model
module KCP = Keeper_cascade_profile
include Keeper_turn_helpers
include Keeper_turn_liveness
include Keeper_turn_cascade_budget
include Keeper_unified_turn_types

(* RFC-0132 PR-2: removed dead [runtime_lane_label] (0 callers). *)

include Keeper_unified_turn_phase_plan

let run_keeper_cycle
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(observation : Keeper_world_observation.world_observation)
      ~(generation : int)
      ?(channel : Keeper_world_observation.keeper_cycle_channel = Scheduled_autonomous)
      ?(semaphore_wait_ms = 0)
      ?turn_slot_control
      ?shared_context
      ?selected_item
      ()
  : (keeper_meta, Agent_sdk.Error.sdk_error) result
  =
  (* Spec navigation (OCaml -> TLA+) — plan §19 Cycle 28 anchor for
     B2 (Task Acquisition).  Authoritative spec mirror is
     specs/keeper-state-machine/KeeperTaskAcquisition.tla (Cycle 8 /
     Tier B2, PR #11412).

     The spec preamble cites this function by symbol: see
     KeeperTaskAcquisition.tla preamble [run_keeper_cycle] reference
     (iter 64 N-2.a removed the line number — function names are
     stable identifiers, line refs drift on every edit).  This block
     is the reverse-direction citation so code search for
     "KeeperTaskAcquisition" lands here.

     Action mapping (TLA+ -> OCaml):
       SubmitTask        external producers (operator, supervisor,
                         autoresearch, board) populate
                         [observation.pending_*] before this function
                         is called.
       AssignTask        the channel decision below —
                         [observation.pending_mentions <> []] OR
                         [pending_board_events <> []] OR
                         [pending_scope_messages <> []] picks
                         channel = "turn", which is the OCaml form of
                         spec's AssignTask.  Cited by symbol; iter 64
                         N-2.a — locate via grep for the disjunction.
       EmptyQueueSleep   the [else] branch picks
                         "scheduled_autonomous", which exits the
                         claim-and-finish path for this cycle.
       TurnComplete      the [run_turn] body finishes and returns a
                         [keeper_meta] result; control falls through
                         to the next observation cycle.
       TaskRejected      bug action — claimed task is dropped without
                         a finish.  Spec invariant NoTaskOrphan
                         catches this; in code, the invariant is
                         that every "turn" channel claim eventually
                         reaches one of [Ok updated_meta] /
                         [Error sdk_error].  Silent-drop regressions
                         (early return without recording the turn
                         outcome) would violate the spec. *)
  (* Cycle 45: KeeperTaskAcquisition.tla TurnComplete bracket — the
     ref is set to true on the [Ok updated_meta] return at the end of
     this function; an [Error _] branch leaves it false and skips the
     wrap, mirroring the spec's "completed-on-success" semantics. *)
  let cycle_completed = ref false in
  (* 0. Phase gate + state-aware cascade routing.
     The gate owns turn executability; select_cascade remains a total helper
     so dashboards/tests can inspect the same routing contract for blocked
     phases like Overflowed. *)
  let registry_base_path = config.base_path in
  let previous_social_state = Social.previous_state_of_meta meta in
  (* Decide turn_id at function entry so phase-gate / cascade-routing /
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
  let append_manifest ?status ?decision ?cascade_name ~site event =
    Keeper_runtime_manifest.make_for_context runtime_manifest_context ~event
      ?cascade_name ?status ?decision ()
    |> Keeper_runtime_manifest.append_best_effort ~site config
  in
  let append_phase_gate_decision turn_plan =
    append_manifest ~site:"phase_gate_decided"
      ~status:(turn_plan_manifest_status turn_plan)
      ~decision:(turn_plan_manifest_decision turn_plan)
      Keeper_runtime_manifest.Phase_gate_decided
  in
  append_manifest ~site:"turn_started"
    ~decision:
      (`Assoc
        [
          ( "channel",
            `String (Keeper_world_observation.channel_to_string channel) );
          ("usage_total_turns", `Int meta.runtime.usage.total_turns);
        ])
    Keeper_runtime_manifest.Turn_started;
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

     State-aware cascade routing (TLA+ KeeperCoreTriad.SelectCascade)
     resumes inside [main_path]; at that point [phase_opt] is whatever
     the registry returned for an executable phase. *)
  let main_path phase_opt =
      (* RFC-0136 PR-2: cascade resolution stage extracted to
         [Keeper_unified_turn_cascade_resolution].  The stage owns the
         [selected_item] override of [meta.cascade_ref], the
         [Keeper_cascade_routing.select_cascade] call, and the
         [fail_open_local_only_when_unavailable] hardening.  Returns
         the updated meta + the resolved cascade name. *)
      let { Keeper_unified_turn_cascade_resolution.resolved_meta = meta
          ; resolved_cascade = effective_cascade_name
          }
        =
        Keeper_unified_turn_cascade_resolution.resolve_cascade
          ~meta
          ~phase_opt
          ~selected_item
          ~append_cascade_routed_manifest:(fun ~cascade_name ~decision ->
            append_manifest ~site:"cascade_routed"
              ~cascade_name
              ~decision
              Keeper_runtime_manifest.Cascade_routed)
      in
      (* Concrete runtime health/capacity is owned by OAS/provider adapters.
         Keeper routing no longer rewrites cascades from provider cooldown or
         process-queue probes. *)
      (match None with
       | Some meta_after_skip -> Ok meta_after_skip
       | None ->
         (* RFC-0136 PR-3: pre-dispatch validation extracted to
            [Keeper_unified_turn_pre_dispatch].  profile_defaults stays
            in scope so the retry-loop block below can also call the
            extracted builder with the same defaults. *)
         let profile_defaults =
           Keeper_types_profile.load_keeper_profile_defaults meta.name
         in
         let effective_cascade_runtime_name = KCP.Runtime_name effective_cascade_name in
         (match
            Keeper_unified_turn_pre_dispatch.build_cascade_execution
              ~meta
              ~profile_defaults
              ~cascade_name:effective_cascade_runtime_name
          with
          | Error err ->
            let terminal_reason_code =
              Printf.sprintf
                "pre_dispatch_%s"
                (Keeper_agent_error.terminal_reason_code_of_sdk_error err)
            in
            let error_message = Agent_sdk.Error.to_string err in
            record_pre_dispatch_terminal_observation
              ~config
              ~meta
              ~generation
              ~cascade_name:effective_cascade_runtime_name
              ~outcome:`Error
              ~terminal_reason_code
              ~activity_kind:"keeper.turn_blocked"
              ~trajectory_outcome:(Trajectory.Failed terminal_reason_code)
              ~error_kind:
                (Keeper_execution_receipt.error_kind_of_string (sdk_error_kind err))
              ~error_message
              ~keeper_turn_id
              ();
            Keeper_turn_fsm.emit_transition
              ~keeper_name:meta.name
              ~turn_id:keeper_turn_id
              ~prev:Keeper_turn_fsm.Cascade_routing
              (Keeper_turn_fsm.Failed
                 (Keeper_turn_fsm.Failure_provider_error
                    { kind = sdk_error_kind err; detail = error_message }));
            Error err
          | Ok initial_execution ->
            let turn_id = keeper_turn_id in
            (match
               Keeper_turn_livelock.guard_and_record_turn_start
                 ~keeper:meta.name
                 ~turn_id
                 ~max_attempts:(turn_livelock_max_attempts ())
                 ~stuck_after_sec:(turn_livelock_stuck_after_sec ())
                 ()
             with
             | Keeper_turn_livelock.Blocked reason ->
               Keeper_unified_turn_livelock_block.handle
                 ~config
                 ~meta
                 ~generation
                 ~keeper_turn_id
                 ~turn_id
                 ~initial_execution
                 ~reason
             | Keeper_turn_livelock.Started _ ->
               Keeper_turn_fsm.emit_transition
                 ~keeper_name:meta.name
                 ~turn_id:keeper_turn_id
                 ~prev:Keeper_turn_fsm.Cascade_routing
                 Keeper_turn_fsm.Awaiting_provider;
               (* Yield before CPU-bound prompt construction so the Eio scheduler
         can service HTTP handlers between keeper turn setups. *)
               Eio.Fiber.yield ();
               (* 2. Build unified prompt — diversity entropy recorded in decision_audit
         (keeper_keepalive.ml), not injected into prompt (#6814). *)
               let system_prompt, user_message =
                 Keeper_unified_prompt.build_prompt
                   ~meta
                   ~base_path:config.base_path
                   ~observation
                   ()
               in
               Eio.Fiber.yield ();
               let base_dir = session_base_dir config in
               (* Ensure session dir tree for filesystem fallback (issue #3019) *)
               Keeper_types.mkdir_p
                 (Filename.concat
                    base_dir
                    (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
               let masc_root = Coord.masc_root_dir config in
               let trajectory_acc =
                 Trajectory.create_accumulator
                   ~masc_root
                   ~keeper_name:meta.name
                   ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                   ~generation:meta.runtime.generation
               in
               let max_cost_usd = Keeper_config.keeper_tool_cost_max_usd () in
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
         [filter_agent meta.name], so no cross-keeper contamination. *)
               let post_commit_failure_reason = ref None in
               let paused_meta_override = ref None in
               let current_turn_blocker_info = ref None in
               let turn_event_bus_state =
                 Keeper_unified_turn_event_bus.create ~keeper_name:meta.name ()
               in
               (* PR-J: [?site] labels the call-site so PromQL can attribute
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
                       Prometheus.inc_counter
                         Keeper_metrics.metric_keeper_write_meta_failures
                         ~labels:[ "keeper", entry.meta.name; "phase", Keeper_oas_execution_error_phase.(to_label Turn_start) ]
                         ();
                       Log.Keeper.warn
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
               let last_execution = ref initial_execution in
               let last_timeout_budget : oas_timeout_budget_resolution option ref =
                 ref None
               in
               let degraded_retry_info = ref None in
               let cascade_rotation_attempts = ref [] in
               let record_cascade_rotation_attempt
                     ?slot_release_at_phase
                     ?productive_phase_elapsed_ms
                     ?retry_phase_elapsed_ms
                     ~(from_cascade : Keeper_execution_receipt.cascade_name)
                     ~(retry : EC.degraded_retry)
                     ~(outcome : Keeper_execution_receipt.cascade_rotation_outcome)
                     (err : Agent_sdk.Error.sdk_error)
                 =
                 let attempt : Keeper_execution_receipt.cascade_rotation_attempt =
                   { from_cascade
                   ; to_cascade =
                       Keeper_execution_receipt.cascade_name_of_string retry.next_cascade
                   ; reason = retry.fallback_reason
                   ; outcome
                   ; slot_release_at_phase
                   ; productive_phase_elapsed_ms
                   ; retry_phase_elapsed_ms
                   ; error_kind =
                       Some
                         (Keeper_execution_receipt.error_kind_of_string
                            (sdk_error_kind err))
                   ; error_message = Some (Agent_sdk.Error.to_string err)
                   ; recorded_at = now_iso ()
                   }
                 in
                 cascade_rotation_attempts := attempt :: !cascade_rotation_attempts
               in
               let run_result, latency_ms =
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
                        "%s: unsubscribe_event_bus in turn cleanup raised: %s"
                        meta.name
                        (Printexc.to_string e);
                      Prometheus.inc_counter
                        Keeper_metrics.metric_keeper_turn_cleanup_failures
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
                       "%s: mark_turn_finished in turn cleanup raised: %s"
                       meta.name
                       (Printexc.to_string e);
                     Prometheus.inc_counter
                       Keeper_metrics.metric_keeper_turn_cleanup_failures
                       ~labels:[ "keeper", meta.name; "site", Keeper_turn_cleanup_failure_site.(to_label Mark_turn_finished) ]
                       ()
                 in
                 match
                   Keeper_exec_context.timed (fun () ->
                     match Eio_context.get_clock () with
                     | Error msg -> Error (Agent_sdk.Error.Internal msg)
                     | Ok clock ->
                       let timeout_sec = Keeper_runtime_resolved.turn_timeout_sec () in
                       start_background_turn_event_bus_drain ~clock;
                       let turn_started_at = Eio.Time.now clock in
                       let turn_deadline = turn_started_at +. timeout_sec in
                       let remaining_turn_budget_s () =
                         Float.max 0.0 (turn_deadline -. Eio.Time.now clock)
                       in
                       let retry_phase_started_at = ref None in
                       let elapsed_ms seconds =
                         int_of_float (Float.max 0.0 seconds *. 1000.0)
                       in
                       let current_turn_phase_elapsed_ms () =
                         let now = Eio.Time.now clock in
                         match !retry_phase_started_at with
                         | None -> elapsed_ms (now -. turn_started_at), Some 0
                         | Some retry_started_at ->
                           ( elapsed_ms (retry_started_at -. turn_started_at)
                           , Some (elapsed_ms (now -. retry_started_at)) )
                       in
                       let keeper_profile =
                         Keeper_types_profile.load_keeper_profile_defaults meta.name
                       in
                       let max_idle_turns, max_turns =
                         match channel with
                         | Keeper_world_observation.Reactive ->
                           ( Keeper_runtime_resolved.reactive_max_idle_turns ()
                           , Keeper_types_profile.effective_max_turns_per_call
                               keeper_profile )
                         | Keeper_world_observation.Scheduled_autonomous ->
                           ( Keeper_runtime_resolved.autonomous_max_idle_turns ()
                           , Keeper_types_profile
                             .effective_max_turns_per_call_scheduled_autonomous
                               keeper_profile )
                       in
                       let initial_tool_requirement =
                         if
                           Keeper_agent_run.should_require_tools_for_initial_turn
                             ~max_turns
                             ~turn_affordances
                         then Keeper_agent_tool_surface.Required
                         else Keeper_agent_tool_surface.Optional
                       in
                       let do_run
                             ~(execution : cascade_execution)
                             ~run_meta
                             ~run_generation
                             ~is_retry
                             ~oas_timeout_s
                             ~attempt_watchdog_s
                         =
                         last_execution := execution;
                         Otel_genai.with_keeper_turn_span
                           ~keeper_name:run_meta.name
                           ~agent_name:run_meta.agent_name
                           ~cascade_name:execution.cascade_name
                           ~trace_id:
                             (Keeper_id.Trace_id.to_string run_meta.runtime.trace_id)
                           ~generation:run_generation
                           ~max_context:execution.max_context
                           ~max_turns
                           ~max_idle_turns
                           ~channel:(Keeper_world_observation.channel_to_string channel)
                           ~is_retry
                           ~current_task_id:
                             (Option.map
                                Keeper_id.Task_id.to_string
                                run_meta.current_task_id)
                           (fun () ->
                              Keeper_registry.mark_turn_provider_attempt_started
                                ~base_path:config.base_path
                                meta.name;
                              Keeper_turn_fsm.emit_transition
                                ~keeper_name:meta.name
                                ~turn_id:keeper_turn_id
                                ~prev:Keeper_turn_fsm.Awaiting_provider
                                Keeper_turn_fsm.Streaming;
                              try
                                Eio.Time.with_timeout_exn
                                  clock
                                  attempt_watchdog_s
                                  (fun () ->
                                     Keeper_agent_run.run_turn
                                       ~config
                                       ~meta:run_meta
                                       ~base_dir
                                       ~max_context:execution.max_context
                                       ~build_turn_prompt
                                       ~user_message
                                       ~cascade_name:execution.cascade_name
                                       ~world_observation:observation
                                       ~turn_affordances
                                       ?provider_filter:
                                         (Env_config_keeper.KeeperCascade
                                          .provider_allowlist
                                            ())
                                       ~generation:run_generation
                                       ~max_turns
                                       ~max_idle_turns
                                       ~history_user_source:"world_state_prompt"
                                       ~history_assistant_source:"internal_assistant"
                                       ~degraded_retry_applied:
                                         (Option.is_some !degraded_retry_info)
                                       ?degraded_retry_cascade:
                                         (Option.map
                                            (fun (retry : EC.degraded_retry) ->
                                               retry.next_cascade)
                                            !degraded_retry_info)
                                       ?fallback_reason:
                                         (Option.map
                                            (fun (retry : EC.degraded_retry) ->
                                               retry.fallback_reason)
                                            !degraded_retry_info)
                                       ~cascade_rotation_attempts:
                                         (List.rev !cascade_rotation_attempts)
                                       ~temperature:execution.temperature
                                       ~max_tokens:execution.max_tokens
                                       ~oas_timeout_s
                                       ~oas_timeout_is_explicit:false
                                       ?max_cost_usd
                                       ~trajectory_acc
                                       ~is_retry
                                       ?shared_context
                                       ?event_bus:(Keeper_event_bus.get ())
                                       ())
                              with
                              | Eio.Cancel.Cancelled _ as e ->
                                (* Cycle 1b-iv: external cancellation that escapes the
                     in-band receipt builder in [Keeper_agent_run.run_turn].
                     The 14 inner Cancel handlers all re-raise; without an
                     outer catch the receipt for this turn is silently
                     dropped (FSM emits Streaming then nothing — the turn
                     just disappears from the operator's timeline).

                     Emit a minimal cancelled receipt + matching FSM
                     Cancelled transition before re-raising.  When
                     [fiber_stop] is confirmed set in the registry the
                     cancellation came from the supervisor cooperative-stop
                     path: emit SupervisorRequestsStop (Streaming →
                     Streaming) to record the signal-raised window, then
                     HonorStopSignal (Streaming → Cancelled supervisor_stop).
                     For other Eio cancellations (switch teardown, timeout)
                     [fiber_stop] is false and we skip straight to
                     HonorStopSignal with the same conservative cancel
                     reason. *)
                                record_streaming_cancelled_observation
                                  ~config
                                  ~run_meta
                                  ~run_generation
                                  ~cascade_name:execution.cascade_name
                                  ~keeper_turn_id
                                  ();
                                raise e
                              | Eio.Time.Timeout ->
                                Error
                                  (Agent_sdk.Error.Api
                                     (Timeout
                                        { message =
                                            Printf.sprintf
                                              "Turn wall-clock budget exhausted during \
                                               cascade attempt (budget=%.1fs, \
                                               watchdog=%.1fs)"
                                              oas_timeout_s
                                              attempt_watchdog_s
                                        })))
                       in
                       let fail_open_rotation_cascades =
                         active_fail_open_rotation_cascades ()
                       in
                       let rec retry_loop
                                 ~run_meta
                                 ~(execution : cascade_execution)
                                 ~run_generation
                                 ~attempt
                                 ~is_retry
                                 ~allow_degraded_wall_clock_retry_budget
                                 ~attempted_cascades
                         =
                         let execution_cascade_name =
                           KCP.runtime_name_to_string execution.cascade_name
                         in
                         let mark_terminal_error err =
                           if EC.is_cascade_exhausted_error err
                           then (
                             Keeper_registry.mark_turn_cascade_exhausted
                               ~base_path:config.base_path
                               meta.name;
                             Prometheus.inc_counter
                               Keeper_metrics.metric_keeper_fsm_edge_transitions
                               ~labels:[ "edge", "kcl_to_ktc_exhaustion" ]
                               ();
                             (* Cycle 52 narrative: cascade exhaustion is a silent
                   failure on dashboards reading only Turn_failed.  The
                   fsm_edge counter records the transition, but operators
                   forensically investigating "why is this keeper stuck?"
                   benefit from a structured WARN line distinguishing
                   'all cascades exhausted' from 'single transient error'.
                   Companion to PR #11708 (gate rejection narrative) and
                   PR #11717 (unmapped regression alert). *)
                             Log.Keeper.warn
                               "%s: all cascades exhausted (terminal) — last_err=%s \
                                attempt=%d attempted_cascades=[%s]"
                               meta.name
                               (Agent_sdk.Error.to_string err)
                               attempt
                               (String.concat ", " attempted_cascades);
                             Prometheus.inc_counter
                               Keeper_metrics.metric_keeper_oas_execution_errors
                               ~labels:
                                 [ "keeper", meta.name; "phase", Keeper_oas_execution_error_phase.(to_label Cascade_exhausted) ]
                               ())
                           else (
                             Keeper_registry.set_turn_phase
                               ~base_path:config.base_path
                               meta.name
                               Keeper_registry.(Packed Turn_finalizing);
                             (* Cycle 52 narrative companion: non-exhaustion terminal
                   errors (transient).  Logged so dashboard readers can
                   distinguish exhaustion from transient failure without
                   re-parsing Turn_finalizing reason fields. *)
                             Prometheus.inc_counter
                               Keeper_metrics.metric_keeper_oas_execution_errors
                               ~labels:
                                 [ "keeper", meta.name
                                 ; "phase", Keeper_oas_execution_error_phase.(to_label Terminal_non_exhaustion)
                                 ]
                               ();
                             Log.Keeper.warn
                               "%s: turn terminal (non-exhaustion error) — err=%s \
                                attempt=%d"
                               meta.name
                               (Agent_sdk.Error.to_string err)
                               attempt)
                         in
                         let attempt_timeout_budget = ref None in
                         let max_turns =
                           match channel with
                           | Keeper_world_observation.Reactive ->
                             Keeper_types_profile.effective_max_turns_per_call
                               keeper_profile
                           | Keeper_world_observation.Scheduled_autonomous ->
                             Keeper_types_profile
                             .effective_max_turns_per_call_scheduled_autonomous
                               keeper_profile
                         in
                         let attempt_result =
                           (* RFC-0129 (2026-05-18): reserve_degraded_retry_budget
                              flag removed. The first cascade attempt now
                              receives the full usable budget; OAS 0.195.0+
                              body_timeout_s + stream_idle_timeout_s bounds
                              hangs without halving healthy slow streams.
                              See keeper_turn_cascade_budget.ml header. *)
                           let allow_wall_clock_retry_budget =
                             allow_wall_clock_retry_budget_for_attempt
                               ~is_retry
                               ~degraded_rotation_first_attempt:
                                 allow_degraded_wall_clock_retry_budget
                               ~attempt
                               ~attempted_cascades
                           in
                           match
                             resolve_bounded_oas_timeout_budget_with_turn_budget
                               ~allow_wall_clock_retry_budget
                               ~is_retry
                               ~max_turns
                               ~estimated_input_tokens:prompt_timeout_estimate_tokens
                               ~remaining_turn_budget_s:(remaining_turn_budget_s ())
                           with
                           | None ->
                             Error
                               (Keeper_turn_driver.sdk_error_of_masc_internal_error
                                  (Keeper_turn_driver.Oas_timeout_budget
                                     { budget_sec = 0.0
                                     ; keeper_turn_timeout_sec = timeout_sec
                                     ; estimated_input_tokens =
                                         prompt_timeout_estimate_tokens
                                     ; source =
                                         (if is_retry
                                          then "pre_retry_budget_unavailable"
                                          else "pre_attempt_budget_unavailable")
                                     ; remaining_turn_budget_sec =
                                         Some (remaining_turn_budget_s ())
                                     ; min_required_sec = min_oas_timeout_budget_sec
                                     ; phase =
                                         (if is_retry
                                          then "pre_retry_budget_gate"
                                          else "pre_attempt_budget_gate")
                                     }))
                           | Some timeout_budget ->
                             attempt_timeout_budget := Some timeout_budget;
                             last_timeout_budget := Some timeout_budget;
                             (* Cascade_trying marking moved into the disclosure
                     hook in [Keeper_run_tools] (BeforeTurnParams) so
                     that the spec-mandated atomic group
                     [SelectToolPolicy(idle->selecting) ->
                     CascadeTrying(selecting->trying)] is materialised
                     at the only call site that asserts
                     [decision_stage = Decision_tool_policy_selected].

                     The previous direct [Cascade_idle -> Cascade_trying]
                     jump from this site bypassed [Cascade_selecting]
                     and tripped
                     [Keeper_registry.validate_cascade_transition]
                     after PR #14153 introduced the runtime invariant
                     (assertion at keeper_registry.ml:721). Spec
                     reference: [KeeperCascadeLifecycle.tla]
                     [KeeperTurnCycle.tla]. *)
                             let attempt_watchdog_s =
                               attempt_watchdog_timeout_sec
                                 ~remaining_turn_budget_s:(remaining_turn_budget_s ())
                                 timeout_budget
                             in
                             do_run
                               ~execution
                               ~run_meta
                               ~run_generation
                               ~is_retry
                               ~oas_timeout_s:timeout_budget.effective_timeout_sec
                               ~attempt_watchdog_s
                         in
                         match attempt_result with
                         | Ok result ->
                           let selected_model =
                             match result.cascade_observation with
                             | Some observation -> observation.selected_model
                             | None -> None
                           in
                           Keeper_registry.set_turn_selected_model
                             ~base_path:config.base_path
                             meta.name
                             selected_model;
                           Keeper_registry.mark_turn_cascade_done
                             ~base_path:config.base_path
                             meta.name;
                           Ok result
                         | Error err ->
                           let err =
                             reclassify_oas_timeout_for_attempt
                               ~timeout_budget:!attempt_timeout_budget
                               err
                           in
                           let _ = drain_turn_event_bus ~site:"reconcile_pre_check" () in
                           let err =
                             match event_bus_integrity_error_snapshot () with
                             | Some integrity_err -> integrity_err
                             | None -> err
                           in
                           let committed_tools = committed_mutating_tools_snapshot () in
                           if
                             committed_tools <> []
                             && Keeper_tool_registry.all_tools_reconcile_safe
                                  committed_tools
                             && (EC.is_auto_recoverable_turn_error err
                                 || EC.is_required_tool_contract_violation err)
                           then (
                             (* All committed tools are board-like (duplicate-tolerant)
                     AND the failure is transient or the server rejected the
                     request body before processing (parse error).  Parse
                     errors mean the LLM never saw the request, so no risk
                     of duplicate processing.  The keeper's next cycle will
                     build a fresh prompt that may avoid the parse issue. *)
                             let err_preview =
                               short_preview (Agent_sdk.Error.to_string err)
                             in
                             let reason =
                               if EC.is_server_rejected_parse_error err
                               then "server parse rejection"
                               else if EC.is_required_tool_contract_violation err
                               then "required tool contract violation"
                               else "transient error"
                             in
                             Log.Keeper.warn
                               "%s: %s after committed reconcile-safe tool(s) [%s] — \
                                auto-recovering (error: %s)"
                               meta.name
                               reason
                               (String.concat ", " committed_tools)
                               err_preview;
                             Prometheus.inc_counter
                               Keeper_metrics.metric_keeper_turn_error_after_tools
                               ~labels:[ "keeper", meta.name; "reason", reason ]
                               ();
                             mark_terminal_error err;
                             Error err)
                           else if committed_tools <> []
                           then (
                             let reclassified, failure_reason =
                               match
                                 EC.classify_post_commit_failure
                                   ~tool_names:committed_tools
                                   err
                               with
                               | Some classified -> classified
                               | None ->
                                 ( EC.reclassify_error_after_side_effect
                                     ~tool_names:committed_tools
                                     err
                                 , Keeper_registry.Ambiguous_partial_commit
                                     { kind = Keeper_registry.Post_commit_failure
                                     ; detail =
                                         EC.summarize_post_commit_failure
                                           ~tool_names:committed_tools
                                           ~kind:Keeper_registry.Post_commit_failure
                                           err
                                     } )
                             in
                             post_commit_failure_reason := Some failure_reason;
                             let err_preview =
                               short_preview (Agent_sdk.Error.to_string err)
                             in
                             if EC.is_transient_network_error err
                             then (
                               Prometheus.inc_counter
                                 Keeper_metrics.metric_keeper_post_turn_wirein_failures
                                 ~labels:
                                   [ "keeper", meta.name
                                   ; "site", Keeper_post_turn_wirein_failure_site.(to_label Post_commit_transient)
                                   ]
                                 ();
                               Log.Keeper.error
                                 "%s: transient provider error after committed mutating \
                                  tool call(s) [%s] — treating as integrity failure, \
                                  skipping retry to prevent duplicate (error: %s)"
                                 meta.name
                                 (String.concat ", " committed_tools)
                                 err_preview)
                             else
                               Log.Keeper.error
                                 "%s: error after committed mutating tool call(s) [%s] — \
                                  turn outcome is ambiguous and requires reconcile \
                                  (error: %s)"
                                 meta.name
                                 (String.concat ", " committed_tools)
                                 err_preview;
                             Prometheus.inc_counter
                               Keeper_metrics.metric_keeper_turn_error_after_tools
                               ~labels:[ "keeper", meta.name ]
                               ();
                             mark_terminal_error reclassified;
                             Error reclassified)
                           else if
                             (* Fast-fail after one cascade rotation for a contract
                     violation: if the LLM called no tools or only used
                     passive/read-only tools on the first cascade and the
                     same pattern repeats on a rotated cascade, further
                     rotation is unlikely to change the model's tool-use
                     choice on the same prompt.  Each rotation eats ~600s of
                     turn budget; in production we observed 4–5 rotations all
                     hitting the same violation before the OAS retry guard
                     finally aborted the cycle (see fleet logs:
                     "passive status/read tools" cascade=default →
                     keeper_unified → kimi_cli_keeper → … →
                     oas_timeout_budget at 1064s/1200s).  Cap at 1 rotation
                     so the keeper releases its turn budget promptly.

                     The cap fires when attempted_cascades has at least 2
                     entries, meaning at least one rotation has already been
                     tried (the list is seeded with the initial cascade name,
                     so length=1 = no rotations yet; length≥2 = one or more
                     rotations have been attempted).

                     Exception: if the current cascade declares a
                     fallback_cascade that has not been attempted yet,
                     allow one more rotation to try it — the fallback
                     has a different model composition and may not
                     exhibit the same passive-tool behavior. *)
                             let fallback_not_yet_tried =
                               match KCP.fallback_cascade_for execution_cascade_name with
                               | Some fb ->
                                 (not (List.exists (String.equal fb) attempted_cascades))
                                 && not (String.equal fb execution_cascade_name)
                               | None -> false
                             in
                             EC.should_cap_rotation_for_contract_violation
                               ~attempted_cascades
                               ~fallback_not_yet_tried
                               err
                           then (
                             Log.Keeper.warn
                               "%s: required_tool_contract_violation after rotation (%s, \
                                %d cascade(s) attempted) — skipping further rotation; \
                                rotating again is unlikely to change the model's \
                                tool-use choice. Error: %s"
                               meta.name
                               execution_cascade_name
                               (List.length attempted_cascades)
                               (short_preview (Agent_sdk.Error.to_string err));
                             Prometheus.inc_counter
                               "masc_keeper_contract_violation_rotation_capped_total"
                               ~labels:[ "keeper", meta.name ]
                               ();
                             mark_terminal_error err;
                             Error err)
                           else (
                             (* Budget gate: check whether there is enough wall-clock
                     remaining to schedule a degraded cascade retry.  The
                     gate always uses per-attempt semantics (fresh floor) for
                     the candidate because, by definition, every degraded
                     retry is itself a retry — even when the failing attempt
                     was the first attempt (is_retry=false here). *)
                             match
                               next_fail_open_cascade_for_turn_with_budget
                                 ?rotation_cascades:fail_open_rotation_cascades
                                 ~base_cascade:(cascade_name_of_meta meta)
                                 ~effective_cascade:execution_cascade_name
                                 ~tool_requirement:initial_tool_requirement
                                 ~attempted_cascades
                                 ~estimated_input_tokens:prompt_timeout_estimate_tokens
                                 ~max_turns
                                 ~time_spent_in_turn_s:
                                   (timeout_sec -. remaining_turn_budget_s ())
                                 ~remaining_turn_budget_s:(remaining_turn_budget_s ())
                                 err
                             with
                             | Degraded_retry_allowed degraded_retry ->
                               (match
                                  Keeper_unified_turn_pre_dispatch
                                  .build_cascade_execution
                                    ~meta
                                    ~profile_defaults
                                    ~cascade_name:
                                      (KCP.Runtime_name degraded_retry.next_cascade)
                                with
                                | Error fail_open_err ->
                                  let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
                                    current_turn_phase_elapsed_ms ()
                                  in
                                  record_cascade_rotation_attempt
                                    ~slot_release_at_phase:
                                      Keeper_execution_receipt.Retry_setup_failed
                                    ~productive_phase_elapsed_ms
                                    ?retry_phase_elapsed_ms
                                    ~from_cascade:execution.cascade_name
                                    ~retry:degraded_retry
                                    ~outcome:
                                      Keeper_execution_receipt.Rotation_setup_failed
                                    fail_open_err;
                                  Log.Keeper.warn
                                    "%s: recoverable cascade failure in %s suggested \
                                     degraded retry to %s (reason=%s), but retry setup \
                                     failed: %s"
                                    meta.name
                                    execution_cascade_name
                                    degraded_retry.next_cascade
                                    (EC.degraded_retry_reason_to_string
                                       degraded_retry.fallback_reason)
                                    (short_preview
                                       (Agent_sdk.Error.to_string fail_open_err));
                                  mark_terminal_error fail_open_err;
                                  Error fail_open_err
                                | Ok next_execution ->
                                  let next_execution_cascade_name =
                                    KCP.runtime_name_to_string next_execution.cascade_name
                                  in
                                  if Option.is_none !retry_phase_started_at
                                  then retry_phase_started_at := Some (Eio.Time.now clock);
                                  let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
                                    current_turn_phase_elapsed_ms ()
                                  in
                                  let slot_release_at_phase =
                                    match turn_slot_control with
                                    | Some slot_control ->
                                      slot_control.Keeper_turn_slot.release_for_retry ();
                                      Some Keeper_execution_receipt.Retry_scheduled
                                    | None -> None
                                  in
                                  record_cascade_rotation_attempt
                                    ?slot_release_at_phase
                                    ~productive_phase_elapsed_ms
                                    ?retry_phase_elapsed_ms
                                    ~from_cascade:execution.cascade_name
                                    ~retry:degraded_retry
                                    ~outcome:
                                      Keeper_execution_receipt.Rotation_retry_scheduled
                                    err;
                                  degraded_retry_info := Some degraded_retry;
                                  Log.Keeper.warn
                                    "%s: recoverable cascade failure in %s; rotation \
                                     retry on cascade=%s reason=%s max_context=%d \
                                     context_budget=%d primary_budget=%d \
                                     requested_override=%s: %s"
                                    meta.name
                                    execution_cascade_name
                                    next_execution_cascade_name
                                    (EC.degraded_retry_reason_to_string
                                       degraded_retry.fallback_reason)
                                    next_execution.max_context
                                    next_execution.max_context_resolution.effective_budget
                                    next_execution.max_context_resolution.primary_budget
                                    (match
                                       next_execution.max_context_resolution
                                         .requested_override
                                     with
                                     | Some requested -> string_of_int requested
                                     | None -> "none")
                                    (short_preview (Agent_sdk.Error.to_string err));
                                  Eio.Fiber.yield ();
                                  let run_retry_after_reacquire () =
                                    retry_loop
                                      ~run_meta
                                      ~execution:next_execution
                                      ~run_generation
                                      ~attempt:1
                                      ~is_retry:true
                                      ~allow_degraded_wall_clock_retry_budget:true
                                      ~attempted_cascades:
                                        (next_execution_cascade_name :: attempted_cascades)
                                  in
                                  (match turn_slot_control with
                                   | None -> run_retry_after_reacquire ()
                                   | Some slot_control ->
                                     (match
                                        slot_control
                                          .Keeper_turn_slot.reacquire_after_retry
                                          ()
                                      with
                                      | Ok retry_semaphore_wait_ms ->
                                        Log.Keeper.info
                                          "%s: reacquired keeper turn slot for degraded \
                                           retry on cascade=%s wait_ms=%d"
                                          meta.name
                                          next_execution_cascade_name
                                          retry_semaphore_wait_ms;
                                        run_retry_after_reacquire ()
                                      | Error (`Semaphore_wait_timeout timeout) ->
                                        let slot_err =
                                          sdk_error_of_retry_slot_reacquire_timeout
                                            ~keeper_name:meta.name
                                            timeout
                                        in
                                        Log.Keeper.warn
                                          "%s: degraded retry to %s skipped because turn \
                                           slot reacquire timed out: %s"
                                          meta.name
                                          next_execution_cascade_name
                                          (short_preview
                                             (Agent_sdk.Error.to_string slot_err));
                                        mark_terminal_error slot_err;
                                        Error slot_err)))
                             | Degraded_retry_budget_exhausted degraded_retry ->
                               (* #13120 review (P1, threads 2 & 4): record the
                         rejection in [cascade_rotation_attempts] so
                         downstream receipts show "rotation considered,
                         budget exhausted".  Do NOT flip
                         [degraded_retry_info] — that ref drives
                         [degraded_retry_applied] / [degraded_retry_cascade],
                         which [keeper_execution_receipt.operator_disposition]
                         interprets as a successful fail-open rotation
                         (`fail_open_next_cascade`).  Setting it here
                         misclassified rejected retries as applied,
                         skewing dashboards / metrics and suppressing
                         pause/broadcast on provider-error paths.  The
                         evidence trail is captured by
                         [cascade_rotation_attempts] (with outcome
                         label) regardless. *)
                               let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
                                 current_turn_phase_elapsed_ms ()
                               in
                               record_cascade_rotation_attempt
                                 ~slot_release_at_phase:
                                   Keeper_execution_receipt.Retry_budget_exhausted
                                 ~productive_phase_elapsed_ms
                                 ?retry_phase_elapsed_ms
                                 ~from_cascade:execution.cascade_name
                                 ~retry:degraded_retry
                                 ~outcome:
                                   Keeper_execution_receipt.Rotation_budget_exhausted
                                 err;
                               Log.Keeper.warn
                                 "%s: recoverable cascade failure in %s suggested \
                                  degraded retry to %s (reason=%s), but remaining turn \
                                  budget %.1fs is below the OAS retry guard/minimum; \
                                  ending this cycle: %s"
                                 meta.name
                                 execution_cascade_name
                                 degraded_retry.next_cascade
                                 (EC.degraded_retry_reason_to_string
                                    degraded_retry.fallback_reason)
                                 (remaining_turn_budget_s ())
                                 (short_preview (Agent_sdk.Error.to_string err));
                               mark_terminal_error err;
                               Error err
                             | Degraded_retry_slot_phase_exhausted degraded_retry ->
                               (* #13120 review (P1, thread 3): same observability
                         contract as the budget-exhausted branch above —
                         the rejection is recorded in
                         [cascade_rotation_attempts] (with a distinct
                         "slot_phase_exhausted" outcome label), but
                         [degraded_retry_info] is NOT flipped because
                         no rotation was actually applied. *)
                               let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
                                 current_turn_phase_elapsed_ms ()
                               in
                               record_cascade_rotation_attempt
                                 ~slot_release_at_phase:
                                   Keeper_execution_receipt.Productive_phase_exhausted
                                 ~productive_phase_elapsed_ms
                                 ?retry_phase_elapsed_ms
                                 ~from_cascade:execution.cascade_name
                                 ~retry:degraded_retry
                                 ~outcome:
                                   Keeper_execution_receipt.Rotation_slot_phase_exhausted
                                 err;
                               Log.Keeper.warn
                                 "%s: recoverable cascade failure in %s suggested \
                                  degraded retry to %s (reason=%s), but productive slot \
                                  phase budget %.1fs is exhausted after %.1fs; ending \
                                  this cycle to release the outer turn slot: %s"
                                 meta.name
                                 execution_cascade_name
                                 degraded_retry.next_cascade
                                 (EC.degraded_retry_reason_to_string
                                    degraded_retry.fallback_reason)
                                 degraded_retry_slot_phase_budget_sec
                                 (timeout_sec -. remaining_turn_budget_s ())
                                 (short_preview (Agent_sdk.Error.to_string err));
                               mark_terminal_error err;
                               Error err
                             | No_degraded_retry
                               when EC.is_transient_network_error err
                                    && attempt <= EC.max_transient_retries () ->
                               let delay = EC.transient_backoff_sec attempt in
                               Log.Keeper.warn
                                 "%s: transient network error cascade=%s max_context=%d \
                                  context_budget=%d primary_budget=%d \
                                  requested_override=%s retry=%d/%d backoff=%.0fs: %s"
                                 meta.name
                                 execution_cascade_name
                                 execution.max_context
                                 execution.max_context_resolution.effective_budget
                                 execution.max_context_resolution.primary_budget
                                 (match
                                    execution.max_context_resolution.requested_override
                                  with
                                  | Some requested -> string_of_int requested
                                  | None -> "none")
                                 attempt
                                 (EC.max_transient_retries ())
                                 delay
                                 (short_preview (Agent_sdk.Error.to_string err));
                               Prometheus.inc_counter
                                 Keeper_metrics.metric_keeper_oas_execution_errors
                                 ~labels:
                                   [ "keeper", meta.name
                                   ; "phase", Keeper_oas_execution_error_phase.(to_label Recoverable_cascade_transient)
                                   ]
                                 ();
                               Eio.Time.sleep clock delay;
                               retry_loop
                                 ~run_meta
                                 ~execution
                                 ~run_generation
                                 ~attempt:(attempt + 1)
                                 ~is_retry:true
                                 ~allow_degraded_wall_clock_retry_budget:false
                                 ~attempted_cascades
                             | No_degraded_retry when EC.is_context_overflow err ->
                               let current_turn_event_bus =
                                 drain_turn_event_bus ~site:"context_overflow_capture" ()
                               in
                               let overflow_event =
                                 context_overflow_event_of_error
                                   ~fallback_tokens:execution.max_context
                                   ~turn_event_bus:current_turn_event_bus
                                   err
                               in
                               (* OAS owns transcript mutation, emergency compaction,
                                  and context-overflow retry for the agent run. If
                                  overflow is still returned here, MASC records the
                                  typed blocker and lets the normal terminal
                                  receipt/finalizing path carry the failure; it must
                                  not compact checkpoints or re-dispatch the agent
                                  turn from the keeper layer. *)
                               current_turn_blocker_info
                               := Some
                                    { klass = Sdk_token_budget_exceeded
                                    ; detail =
                                        Keeper_state_machine.event_to_string
                                          overflow_event
                                        ^ ": "
                                        ^ Agent_sdk.Error.to_string err
                                    };
                               Prometheus.inc_counter
                                 Keeper_metrics.metric_keeper_oas_execution_errors
                                 ~labels:
                                   [ "keeper", meta.name
                                   ; "phase",
                                     Keeper_oas_execution_error_phase.(
                                       to_label Context_overflow_after_oas_retry)
                                   ]
                                 ();
                               Log.Keeper.warn
                                 "%s: OAS returned context overflow after its owned retry \
                                  path; MASC will not compact/retry at keeper layer: %s"
                                 meta.name
                                 (short_preview (Agent_sdk.Error.to_string err));
                               mark_terminal_error err;
                               Error err
                             | No_degraded_retry ->
                               mark_terminal_error err;
                               Error err)
                       in
                       (* Wall-clock timeout guards against indefinite TCP-level hangs
             from upstream LLM providers. Without this, a single stalled
             connection blocks the keeper fiber forever. *)
                       (try
                          Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
                            retry_loop
                              ~run_meta:meta
                              ~execution:initial_execution
                              ~run_generation:generation
                              ~attempt:1
                              ~is_retry:false
                              ~allow_degraded_wall_clock_retry_budget:false
                              ~attempted_cascades:
                                [ KCP.runtime_name_to_string
                                    initial_execution.cascade_name
                                ])
                        with
                        | Eio.Time.Timeout ->
                          let msg =
                            Printf.sprintf
                              "Turn wall-clock timeout after %.0fs \
                               (MASC_KEEPER_TURN_TIMEOUT_SEC)"
                              timeout_sec
                          in
                          Log.Keeper.error "%s: %s" meta.name msg;
                          Prometheus.inc_counter
                            Keeper_metrics.metric_keeper_turn_timeout_committed
                            ~labels:[ "keeper", meta.name ]
                            ();
                          let _ = drain_turn_event_bus ~site:"error_path_drain" () in
                          (match event_bus_integrity_error_snapshot () with
                           | Some integrity_err ->
                             Log.Keeper.error
                               "%s: event-bus order violation during timeout path; \
                                treating turn as failed before retry/reconcile decisions"
                               meta.name;
                             Keeper_registry.set_turn_phase
                               ~base_path:config.base_path
                               meta.name
                               Keeper_registry.(Packed Turn_finalizing);
                             Error integrity_err
                           | None ->
                             let committed_tools = committed_mutating_tools_snapshot () in
                             if
                               committed_tools <> []
                               && Keeper_tool_registry.all_tools_reconcile_safe
                                    committed_tools
                             then (
                               (* Timeouts are inherently transient — the provider was
                 reachable (tools executed) but took too long.  Board-only
                 committed tools are duplicate-tolerant, so we auto-recover
                 instead of recording an integrity failure.  Unlike the
                 retry_loop path, no is_transient check is needed: a
                 wall-clock timeout after successful tool execution is
                 always transient by nature. *)
                               Log.Keeper.warn
                                 "%s: turn wall-clock timeout after committed \
                                  reconcile-safe tool(s) [%s] — auto-recovering \
                                  (timeout: %s)"
                                 meta.name
                                 (String.concat ", " committed_tools)
                                 msg;
                               Prometheus.inc_counter
                                 Keeper_metrics.metric_keeper_turn_timeout_committed
                                 ~labels:[ "keeper", meta.name ]
                                 ();
                               Keeper_registry.set_turn_phase
                                 ~base_path:config.base_path
                                 meta.name
                                 Keeper_registry.(Packed Turn_finalizing);
                               Error (Agent_sdk.Error.Api (Timeout { message = msg })))
                             else if committed_tools <> []
                             then (
                               let timeout_err =
                                 Agent_sdk.Error.Api (Timeout { message = msg })
                               in
                               let reclassified, failure_reason =
                                 match
                                   EC.classify_post_commit_failure
                                     ~tool_names:committed_tools
                                     ~kind:Keeper_registry.Post_commit_timeout
                                     timeout_err
                                 with
                                 | Some classified -> classified
                                 | None ->
                                   ( EC.reclassify_error_after_side_effect
                                       ~tool_names:committed_tools
                                       timeout_err
                                   , Keeper_registry.Ambiguous_partial_commit
                                       { kind = Keeper_registry.Post_commit_timeout
                                       ; detail =
                                           EC.summarize_post_commit_failure
                                             ~tool_names:committed_tools
                                             ~kind:Keeper_registry.Post_commit_timeout
                                             timeout_err
                                       } )
                               in
                               post_commit_failure_reason := Some failure_reason;
                               Log.Keeper.error
                                 "%s: turn wall-clock timeout after committed mutating \
                                  tool call(s) [%s] — treating as integrity failure; \
                                  evidence recorded for next-turn observation"
                                 meta.name
                                 (String.concat ", " committed_tools);
                               Prometheus.inc_counter
                                 Keeper_metrics.metric_keeper_turn_timeout_committed
                                 ~labels:[ "keeper", meta.name ]
                                 ();
                               Keeper_registry.set_turn_phase
                                 ~base_path:config.base_path
                                 meta.name
                                 Keeper_registry.(Packed Turn_finalizing);
                               Error reclassified)
                             else (
                               Keeper_registry.set_turn_phase
                                 ~base_path:config.base_path
                                 meta.name
                                 Keeper_registry.(Packed Turn_finalizing);
                               Error
                                 (Keeper_turn_driver.sdk_error_of_masc_internal_error
                                    (Keeper_turn_driver.Turn_timeout
                                       { elapsed_sec = timeout_sec }))))))
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
               append_manifest ~site:"event_bus_correlated"
                 ~status:event_bus_manifest_status
                 ~decision:(turn_event_bus_manifest_decision turn_event_bus)
                 Keeper_runtime_manifest.Event_bus_correlated;
               let run_result =
                 match event_bus_integrity_error_snapshot () with
                 | Some integrity_err -> Error integrity_err
                 | None -> run_result
               in
               let degraded_retry_info = !degraded_retry_info in
               let degraded_retry_applied = Option.is_some degraded_retry_info in
               let degraded_retry_cascade =
                 Option.map
                   (fun (retry : EC.degraded_retry) -> retry.next_cascade)
                   degraded_retry_info
               in
               let fallback_reason =
                 Option.map
                   (fun (retry : EC.degraded_retry) -> retry.fallback_reason)
                   degraded_retry_info
               in
               (* RFC-0041 Phase B3: record per-item health after turn completion. *)
               (match selected_item with
                | Some (_group, item) ->
                  let success =
                    match run_result with
                    | Ok _ -> true
                    | Error _ -> false
                  in
                  Keeper_health_probe.record_item_result
                    ~keeper_name:meta.name
                    ~item_id:item.Cascade_ref.id
                    ~success
                | None -> ());
               (match run_result with
                | Error err ->
                  let final_execution = !last_execution in
                  finalize_trajectory_acc
                    ~config
                    ~keeper_name:meta.name
                    trajectory_acc
                    (Trajectory.Failed (Agent_sdk.Error.to_string err));
                  let e_str = Agent_sdk.Error.to_string err in
                  let is_transient = EC.is_transient_network_error err in
                  (match Keeper_turn_driver.classify_masc_internal_error err with
                   | Some (Keeper_turn_driver.Oas_timeout_budget _) ->
                     Prometheus.inc_counter
                       Keeper_metrics.metric_keeper_oas_timeout_classifications
                       ~labels:[ "classification", "structural_budget" ]
                       ()
                   | Some (Keeper_turn_driver.Turn_timeout _) ->
                     Prometheus.inc_counter
                       Keeper_metrics.metric_keeper_oas_timeout_classifications
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
                        Prometheus.inc_counter
                          Keeper_metrics.metric_keeper_oas_timeout_classifications
                          ~labels:[ "classification", classification ]
                          ()
                      | _ -> ()));
                  let is_server_parse_rejection = EC.is_server_rejected_parse_error err in
                  let is_auto_recoverable = EC.is_auto_recoverable_turn_error err in
                  let is_ambiguous_partial = EC.is_ambiguous_side_effect_error err in
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_turns
                    ~labels:[ "keeper_name", meta.name; "outcome", "failure" ]
                    ();
                  Keeper_turn_fsm.emit_transition
                    ~keeper_name:meta.name
                    ~turn_id:keeper_turn_id
                    ~prev:Keeper_turn_fsm.Streaming
                    (Keeper_turn_fsm.Failed
                       (Keeper_turn_fsm.Failure_provider_error
                          { kind = sdk_error_kind err; detail = short_preview e_str }));
                  Log.Keeper.error
                    "%s: keeper cycle FAILED cascade=%s max_context=%d context_budget=%d \
                     primary_budget=%d requested_override=%s latency=%dms%s error=%s"
                    meta.name
                    (KCP.runtime_name_to_string final_execution.cascade_name)
                    final_execution.max_context
                    final_execution.max_context_resolution.effective_budget
                    final_execution.max_context_resolution.primary_budget
                    (match final_execution.max_context_resolution.requested_override with
                     | Some requested -> string_of_int requested
                     | None -> "none")
                    latency_ms
                    (if is_ambiguous_partial
                     then " (ambiguous partial commit)"
                     else if is_server_parse_rejection
                     then " (server parse rejection, auto-recoverable)"
                     else if is_transient
                     then " (transient, cooldown preserved)"
                     else "")
                    (short_preview e_str);
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_oas_execution_errors
                    ~labels:[ "keeper", meta.name; "phase", Keeper_oas_execution_error_phase.(to_label Cycle_failed) ]
                    ();
                  let social_state, social_transition_reason =
                    Social.derive_failure_state
                      ~meta
                      ~observation
                      ~previous_state:previous_social_state
                      ~is_auto_recoverable
                      ~sdk_error:(Some err)
                      ~reason:e_str
                  in
                  let failure_meta_base =
                    match !paused_meta_override with
                    | Some paused_meta -> paused_meta
                    | None -> meta
                  in
                  let updated_meta =
                    Keeper_unified_metrics.update_metrics_from_failure
                      failure_meta_base
                      ~latency_ms
                      ~observation
                      ~reason:e_str
                      ~is_transient
                      ~social_state
                      ~social_transition_reason:
                        (Social.transition_reason_to_string social_transition_reason)
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
                      let committed_tools = committed_mutating_tools_snapshot () in
                      let failure_reason =
                        Option.value
                          ~default:
                            (Keeper_registry.Ambiguous_partial_commit
                               { kind = Keeper_registry.Post_commit_failure
                               ; detail = e_str
                               })
                          !post_commit_failure_reason
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
                        Prometheus.inc_counter
                          Keeper_metrics.metric_keeper_turn_error_after_tools
                          ~labels:[ "keeper", meta.name; "reason", "ambiguous_partial" ]
                          ();
                        Log.Keeper.warn
                          "%s: ambiguous partial commit (tools=[%s], reason=%s); paused \
                           keeper and opened continue gate id=%s"
                          meta.name
                          (String.concat ", " committed_tools)
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
                        Log.Keeper.error "%s" (Agent_sdk.Error.to_string combined_err);
                        Prometheus.inc_counter
                          Keeper_metrics.metric_keeper_cascade_sync_failures
                          ~labels:
                            [ "keeper", meta.name; "site", Keeper_cascade_sync_failure_site.(to_label Ambiguous_partial_pause) ]
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
                      Keeper_registry.set_failure_reason
                        ~base_path:config.base_path
                        meta.name
                        (Some failure_reason)
                    | None -> ());
                  (match
                     Keeper_passive_loop_detector.progress_class_of_disposition
                       terminal_reason.disposition
                   with
                   | Some progress_class ->
                     Keeper_passive_loop_detector.record_turn
                       ~keeper_name:updated_meta.name
                       ~progress_class
                   | None -> ());
                  Keeper_unified_metrics.append_decision_record
                    ~config
                    ~meta:updated_meta
                    ~observation
                    ~latency_ms
                    ~semaphore_wait_ms
                    ~outcome:(if is_ambiguous_partial then "partial" else "error")
                    ~degraded_retry_applied
                    ?degraded_retry_cascade
                    ?fallback_reason:
                      (Option.map EC.degraded_retry_reason_to_string fallback_reason)
                    ~social_state
                    ~error:e_str
                    ~terminal_reason
                    ();
                  (* #9769 root fix: heartbeat-field-merge prevents the
             turn-failure retry from clobbering heartbeat-owned fields
             (joined_room_ids, last_seen_seq_by_room), which was the
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
                     Prometheus.inc_counter
                       Keeper_metrics.metric_keeper_write_meta_failures
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
                         "write_meta lost CAS race after retries (turn failure path): %s"
                         msg
                     else
                       Log.Keeper.error
                         "write_meta failed after unified turn failure: %s"
                         msg);
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_write_meta_cycle_failures
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
                        !post_commit_failure_reason
                    in
                    Keeper_registry.set_failure_reason
                      ~base_path:config.base_path
                      meta.name
                      (Some failure_reason);
                    let committed_tools = committed_mutating_tools_snapshot () in
                    Log.Keeper.info
                      "%s: reconcile-required failure latched as %s after committed \
                       tools [%s]"
                      meta.name
                      (Keeper_registry.failure_reason_to_string failure_reason)
                      (String.concat ", " committed_tools));
                  Keeper_unified_turn_failure.record_failure_and_maybe_escalate
                    ~config
                    ~meta
                    ~updated_meta
                    ~is_auto_recoverable
                    ~err
                    ~error_text:e_str;
                  Error err
                | Ok result ->
                  let final_execution = !last_execution in
                  finalize_trajectory_acc
                    ~config
                    ~keeper_name:meta.name
                    trajectory_acc
                    Trajectory.Completed;
                  let updated_meta =
                    Keeper_unified_turn_success.handle
                      ~config
                      ~base_dir
                      ~meta
                      ~observation
                      ~previous_social_state
                      ~final_execution
                      ~latency_ms
                      ~semaphore_wait_ms
                      ~degraded_retry_applied
                      ~degraded_retry_cascade
                      ~fallback_reason
                      ~last_timeout_budget:!last_timeout_budget
                      ~current_turn_blocker_info:!current_turn_blocker_info
                      ~keeper_turn_id
                      result
                  in
                  (* Cycle 45: KeeperTaskAcquisition.tla TurnComplete post-action. *)
                  cycle_completed := true;
                  post_turn_complete_task ~cycle_completed;
                  Ok updated_meta))))
  in
  match
    Keeper_unified_turn_phase_gate.decide_and_record
      ~config
      ~meta
      ~generation
      ~keeper_turn_id
      ~append_phase_gate_decision
      ~registry_base_path
  with
  | Keeper_unified_turn_phase_gate.Phase_gate_terminal_ok meta -> Ok meta
  | Keeper_unified_turn_phase_gate.Phase_gate_terminal_error err -> Error err
  | Keeper_unified_turn_phase_gate.Phase_gate_proceed phase_opt ->
    main_path phase_opt
;;

let run_unified_turn = run_keeper_cycle
