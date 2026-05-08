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

let registry_failure_reason_of_terminal_reason
    (terminal_reason : Keeper_turn_terminal.t)
    ~(raw_error : string) : Keeper_registry.failure_reason option =
  let detail = short_preview raw_error in
  let code = Keeper_turn_terminal.code terminal_reason in
  match code with
  | "required_tool_use_no_tool_call"
  | "required_tool_use_unsatisfied" ->
      Some (Keeper_registry.Tool_required_unsatisfied { code; detail })
  | "provider_error" ->
      Some (Keeper_registry.Provider_runtime_error { code; detail })
  | _ when String.starts_with ~prefix:"api_error_" code ->
      Some (Keeper_registry.Provider_runtime_error { code; detail })
  | _ -> None

let should_auto_pause_required_tool_contract_violation
    ~(paused : bool)
    ~(consecutive_failures : int)
    (err : Agent_sdk.Error.sdk_error) : bool =
  EC.is_required_tool_contract_violation err
  && consecutive_failures >= Keeper_behavioral_regime.turn_fail_streak_threshold
  && not paused

let record_streaming_cancelled_observation
    ~(config : Coord.config)
    ~(run_meta : keeper_meta)
    ~(run_generation : int)
    ~(cascade_name : Keeper_execution_receipt.cascade_name)
    ~(keeper_turn_id : int)
    () : unit =
  let fiber_stop_set =
    match Keeper_registry.get ~base_path:config.base_path run_meta.name with
    | Some entry -> Atomic.get entry.fiber_stop
    | None -> false
  in
  if fiber_stop_set then
    (* FSM: SupervisorRequestsStop — stop signal confirmed while streaming;
       turn about to cancel cooperatively. *)
    Keeper_turn_fsm.emit_transition
      ~keeper_name:run_meta.name ~turn_id:keeper_turn_id
      ~prev:Keeper_turn_fsm.Streaming
      Keeper_turn_fsm.Streaming;
  let terminal_reason_code =
    if fiber_stop_set then "supervisor_stop" else "external_cancel"
  in
  record_pre_dispatch_terminal_observation
    ~config
    ~meta:run_meta
    ~generation:run_generation
    ~cascade_name
    ~outcome:"cancelled"
    ~terminal_reason_code
    ~activity_kind:"keeper.turn_cancelled"
    ~trajectory_outcome:(Trajectory.Gated terminal_reason_code)
    ~keeper_turn_id
    ();
  (* FSM: HonorStopSignal — cooperative cancel. *)
  Keeper_turn_fsm.emit_transition
    ~keeper_name:run_meta.name ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Streaming
    (Keeper_turn_fsm.Cancelled Keeper_turn_fsm.Cancelled_supervisor_stop)

let sdk_error_of_retry_slot_reacquire_timeout
    ~(keeper_name : string)
    (timeout : Keeper_turn_slot.semaphore_wait_timeout) =
  let phase =
    Keeper_turn_slot.semaphore_wait_phase_to_string timeout.timeout_phase
  in
  let holder_summary =
    Keeper_turn_slot.format_slot_holders timeout.timeout_holders
  in
  Agent_sdk.Error.Api
    (Agent_sdk.Retry.Timeout
       {
         message =
           Printf.sprintf
             "keeper turn slot reacquire timed out after degraded retry \
              (keeper=%s phase=%s wait=%.0fs holders=%s)"
             keeper_name
             phase
             timeout.timeout_wait_sec
             holder_summary;
       })

let run_keeper_cycle ~(config : Coord.config) ~(meta : keeper_meta)
    ~(observation : Keeper_world_observation.world_observation)
    ~(generation : int)
    ?(channel : Keeper_world_observation.keeper_cycle_channel = Scheduled_autonomous)
    ?(semaphore_wait_ms = 0)
    ?turn_slot_control
    ?shared_context
    ?selected_item
    () : (keeper_meta, Agent_sdk.Error.sdk_error) result =
  (* Spec navigation (OCaml -> TLA+) — plan §19 Cycle 28 anchor for
     B2 (Task Acquisition).  Authoritative spec mirror is
     specs/keeper-state-machine/KeeperTaskAcquisition.tla (Cycle 8 /
     Tier B2, PR #11412).

     Spec line 3 already cites this function: "[run_keeper_cycle]
     (line 1042+)".  This block is the reverse-direction citation
     so code search for "KeeperTaskAcquisition" lands here.

     Action mapping (TLA+ -> OCaml):
       SubmitTask        external producers (operator, supervisor,
                         autoresearch, board) populate
                         [observation.pending_*] before this function
                         is called.
       AssignTask        below (~line 2559) the channel decision —
                         [observation.pending_mentions <> []] OR
                         [pending_board_events <> []] OR
                         [pending_scope_messages <> []] picks
                         channel = "turn", which is the OCaml form of
                         spec's AssignTask.
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
  let keeper_turn_id = meta.runtime.usage.total_turns in
  Keeper_turn_fsm.emit_transition
    ~keeper_name:meta.name ~turn_id:keeper_turn_id
    ~prev:Keeper_turn_fsm.Idle
    Keeper_turn_fsm.Phase_gating;
  (* SupervisorRequestsStop / HonorStopSignal — check stop signal at turn entry.
     If the supervisor set [fiber_stop] between the [should_run_turn] gate in the
     heartbeat loop and this point, honor it cooperatively before any I/O is issued.
     Satisfies the FSM contract: active state observed → SupervisorRequestsStop
     (Phase_gating → Phase_gating, stop signal acknowledged) then HonorStopSignal
     (Phase_gating → Cancelled supervisor_stop). *)
  let supervisor_stop_at_entry =
    match Keeper_registry.get ~base_path:registry_base_path meta.name with
    | Some entry -> Atomic.get entry.fiber_stop
    | None -> false
  in
  if supervisor_stop_at_entry then begin
    Log.Keeper.info ~keeper_name:meta.name ~turn_id:keeper_turn_id
      "%s: supervisor stop signal observed at turn entry — honoring (phase_gating)"
      meta.name;
    (* FSM: SupervisorRequestsStop — stop signal raised while in active state *)
    Keeper_turn_fsm.emit_transition
      ~keeper_name:meta.name ~turn_id:keeper_turn_id
      ~prev:Keeper_turn_fsm.Phase_gating
      Keeper_turn_fsm.Phase_gating;
    record_pre_dispatch_terminal_observation
      ~config
      ~meta
      ~generation
      ~cascade_name:
        (Keeper_execution_receipt.cascade_name_of_string meta.cascade_name)
      ~outcome:"cancelled"
      ~terminal_reason_code:"supervisor_stop"
      ~activity_kind:"keeper.turn_cancelled"
      ~trajectory_outcome:(Trajectory.Gated "supervisor_stop")
      ~keeper_turn_id
      ();
    (* FSM: HonorStopSignal — cooperative cancel at phase_gating *)
    Keeper_turn_fsm.emit_transition
      ~keeper_name:meta.name ~turn_id:keeper_turn_id
      ~prev:Keeper_turn_fsm.Phase_gating
      (Keeper_turn_fsm.Cancelled Keeper_turn_fsm.Cancelled_supervisor_stop);
    Ok meta
  end else
  match Keeper_registry.get_phase ~base_path:registry_base_path meta.name with
  | Some phase when not (Keeper_state_machine.can_execute_turn phase) ->
      let phase_string = Keeper_state_machine.phase_to_string phase in
      Log.Keeper.info
        ~keeper_name:meta.name ~turn_id:keeper_turn_id
        "%s: keeper cycle skipped in non-executable phase=%s"
        meta.name phase_string;
      let terminal_reason_code =
        Printf.sprintf "non_executable_phase:%s" phase_string
      in
      record_pre_dispatch_terminal_observation
        ~config
        ~meta
        ~generation
        ~cascade_name:
          (Keeper_execution_receipt.cascade_name_of_string meta.cascade_name)
        ~outcome:"skipped"
        ~terminal_reason_code
        ~activity_kind:"keeper.turn_skipped"
        ~trajectory_outcome:(Trajectory.Gated terminal_reason_code)
        ~keeper_turn_id
        ();
      Keeper_turn_fsm.emit_transition
        ~keeper_name:meta.name ~turn_id:keeper_turn_id
        ~prev:Keeper_turn_fsm.Phase_gating
        Keeper_turn_fsm.Done;
      Ok meta
  | phase_opt ->
      (* State-aware cascade routing (TLA+ KeeperCoreTriad.SelectCascade).
         At this point [phase] is executable; blocked phases returned above. *)
      Keeper_turn_fsm.emit_transition
        ~keeper_name:meta.name ~turn_id:keeper_turn_id
        ~prev:Keeper_turn_fsm.Phase_gating
        Keeper_turn_fsm.Cascade_routing;
      (* RFC-0041 Phase B4: when a specific item was selected by the
         proactive router, override meta.cascade_name so downstream
         cascade resolution uses the item's group. *)
      let meta =
        match selected_item with
        | Some target ->
            { meta with
              cascade_name = target.Keeper_cascade_selector.group }
        | None -> meta
      in
      let effective_cascade_name =
        let phase = match phase_opt with
          | Some p -> p
          | None ->
              Log.Keeper.warn
                ~keeper_name:meta.name ~turn_id:keeper_turn_id
                "%s: registry phase lookup returned None, defaulting to Failing"
                meta.name;
              Keeper_state_machine.Failing
        in
        let routing = Keeper_cascade_routing.select_cascade
          ~base_cascade:meta.cascade_name ~phase
        in
        Prometheus.inc_counter Keeper_metrics.metric_keeper_fsm_edge_transitions
          ~labels:[("edge", "ksm_to_kcl_routing")] ();
        let routed_meta = { meta with cascade_name = routing.effective_cascade } in
        let routed_labels =
          Keeper_model_labels.configured_model_labels_of_meta routed_meta
        in
        let resolved_cascade =
          fail_open_local_only_when_unavailable
            ~base_cascade:meta.cascade_name
            ~effective_cascade:routing.effective_cascade
            routed_labels
        in
        Log.Keeper.debug "%s: cascade routing: %s -> %s (reason: %s)"
          meta.name meta.cascade_name routing.effective_cascade routing.reason;
        if not (String.equal resolved_cascade routing.effective_cascade) then
          Log.Keeper.warn
            "%s: local_only unavailable for labels [%s]; falling back to base cascade %s"
            meta.name (String.concat ", " routed_labels) resolved_cascade;
        resolved_cascade
      in
      let effective_cascade_name =
        match
          Keeper_world_observation.provider_cooldown_remaining_sec_for_cascade
            ~cascade_name:(KCP.runtime_name_of_string effective_cascade_name)
        with
        | Some remaining_sec ->
            Prometheus.set_gauge
              Keeper_metrics.metric_keeper_provider_cooldown_remaining_sec
              ~labels:[
                ("keeper", meta.name);
                ("cascade", effective_cascade_name);
              ]
              (float_of_int remaining_sec);
            (match
               EC.fallback_cascade_for_unavailable_profile
                 ~base_cascade:meta.cascade_name
                 ~effective_cascade:effective_cascade_name
             with
             | Some fallback_cascade
               when not (String.equal fallback_cascade effective_cascade_name) ->
                 Log.Keeper.warn
                   "%s: cascade %s provider cooldown pending (%ds); fail-opening to %s"
                   meta.name effective_cascade_name remaining_sec fallback_cascade;
                 Prometheus.inc_counter
                   Keeper_metrics.metric_keeper_provider_cooldown_skip
                   ~labels:[
                     ("keeper", meta.name);
                     ("from_cascade", effective_cascade_name);
                     ("to_cascade", fallback_cascade);
                   ]
                   ();
                 fallback_cascade
             | _ -> effective_cascade_name)
        | None ->
            Prometheus.set_gauge
              Keeper_metrics.metric_keeper_provider_cooldown_remaining_sec
              ~labels:[
                ("keeper", meta.name);
                ("cascade", effective_cascade_name);
              ]
              0.0;
            effective_cascade_name
      in
      (* PR-B: ollama saturation pre-skip.  If the resolved cascade
         is ollama-only and the [/api/ps] cache reports zero
         available slots, skip this cycle BEFORE [Agent.run] dispatch
         so the queued request cannot exceed the keeper turn budget
         and trip a FAILED cycle.  Probe failures fall through to the
         normal dispatch path (fail-open) so a flaky probe never
         starves the keeper. *)
      let saturation_skip_meta =
        let meta_for_check =
          { meta with cascade_name = effective_cascade_name }
        in
        let labels =
          Keeper_coordination.effective_model_labels_for_turn meta_for_check
        in
        match resolve_ollama_only_base_url labels with
        | None ->
            saturation_skip_count_reset ~keeper_name:meta.name;
            None
        | Some base_url ->
            if not (is_ollama_saturated base_url) then begin
              saturation_skip_count_reset ~keeper_name:meta.name;
              None
            end
            else
              let next_count =
                saturation_skip_count_inc ~keeper_name:meta.name
              in
              let cap = max_consecutive_saturation_skips () in
              if next_count > cap then begin
                Log.Keeper.warn
                  ~keeper_name:meta.name ~turn_id:keeper_turn_id
                  "%s: saturation skip cap reached (count=%d cap=%d) \
                   \xe2\x80\x94 force-dispatching despite saturated probe"
                  meta.name next_count cap;
                saturation_skip_count_reset ~keeper_name:meta.name;
                None
              end else
              let info = Cascade_ollama_probe.cached_capacity base_url in
              let queue_len =
                match info with
                | Some i -> i.process_queue_length
                | None -> 0
              in
              let available =
                match info with
                | Some i -> i.process_available
                | None -> 0
              in
              Log.Keeper.info
                ~keeper_name:meta.name ~turn_id:keeper_turn_id
                "%s: ollama saturated for keeper=%s cascade=%s queue=%d \
                 available=%d skip_count=%d/%d \xe2\x80\x94 skipping turn"
                meta.name meta.name effective_cascade_name queue_len
                available next_count cap;
              record_pre_dispatch_terminal_observation
                ~config
                ~meta
                ~generation
                ~cascade_name:
                  (Keeper_execution_receipt.cascade_name_of_string
                     effective_cascade_name)
                ~outcome:"skipped"
                ~terminal_reason_code:"ollama_saturated"
                ~activity_kind:"keeper.turn_skipped"
                ~trajectory_outcome:(Trajectory.Gated "ollama_saturated")
                ~keeper_turn_id
                ();
              Keeper_turn_fsm.emit_transition
                ~keeper_name:meta.name ~turn_id:keeper_turn_id
                ~prev:Keeper_turn_fsm.Cascade_routing
                (Keeper_turn_fsm.Failed
                   (Keeper_turn_fsm.Failure_cascade_unavailable
                      { base = effective_cascade_name;
                        resolved = Some "ollama_saturated" }));
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_ollama_saturation_skip
                ~labels:[ ("keeper", meta.name);
                          ("cascade", effective_cascade_name) ]
                ();
              (match Eio_context.get_clock_opt () with
               | Some clock ->
                   (try Eio.Time.sleep clock (saturation_skip_sleep_duration ());
                    with
                    | Eio.Cancel.Cancelled _ as e -> raise e
                    | exn ->
                        Log.Keeper.debug
                          "%s: saturation skip sleep failed: %s"
                          meta.name (Printexc.to_string exn))
               | None -> ());
              Some meta
      in
      (match saturation_skip_meta with
       | Some meta_after_skip -> Ok meta_after_skip
       | None ->
      let build_cascade_execution ~(cascade_name : KCP.runtime_name) :
          (cascade_execution, Agent_sdk.Error.sdk_error) result =
        let cascade_name_string = KCP.runtime_name_to_string cascade_name in
        let meta_for_cascade = { meta with cascade_name = cascade_name_string } in
        let model_labels =
          Keeper_coordination.effective_model_labels_for_turn meta_for_cascade
        in
        match ensure_api_keys_for_labels model_labels with
        | Error e -> Error (Agent_sdk.Error.Internal e)
        | Ok () -> (
            match ensure_local_discovery_ready model_labels with
            | Error e -> Error (Agent_sdk.Error.Internal e)
            | Ok () ->
                let max_context_resolution =
                  Keeper_exec_context.resolve_max_context_resolution
                    ~requested_override:meta.max_context_override model_labels
                in
                let max_context =
                  resolved_max_context_for_turn ~meta model_labels
                in
                let temperature =
                  Cascade_inference.resolve_temperature
                    ~cascade_name
                    ~fallback:Keeper_config.keeper_unified_temperature
                in
                let max_tokens =
                  let raw =
                    Cascade_inference.resolve_max_tokens
                      ~cascade_name
                      ~fallback:Keeper_config.keeper_unified_max_tokens
                  in
                  (* Capability gate: clamp to provider ceiling (TLA+ S3) *)
                  Cascade_inference.clamp_max_tokens_to_ceiling
                    ~provider_ceiling:(Some max_context) raw
                in
                Ok
                  {
                    cascade_name;
                    max_context_resolution;
                    max_context;
                    temperature;
                    max_tokens;
                  })
      in
      let effective_cascade_runtime_name =
        KCP.Runtime_name effective_cascade_name
      in
      match
        build_cascade_execution ~cascade_name:effective_cascade_runtime_name
      with
      | Error err ->
          let terminal_reason_code =
            Printf.sprintf "pre_dispatch_%s"
              (Keeper_agent_error.terminal_reason_code_of_sdk_error err)
          in
          let error_message = Agent_sdk.Error.to_string err in
          record_pre_dispatch_terminal_observation
            ~config
            ~meta
            ~generation
            ~cascade_name:effective_cascade_runtime_name
            ~outcome:"error"
            ~terminal_reason_code
            ~activity_kind:"keeper.turn_blocked"
            ~trajectory_outcome:(Trajectory.Failed terminal_reason_code)
            ~error_kind:
              (Keeper_execution_receipt.error_kind_of_string
                 (sdk_error_kind err))
            ~error_message
            ~keeper_turn_id
            ();
          Keeper_turn_fsm.emit_transition
            ~keeper_name:meta.name ~turn_id:keeper_turn_id
            ~prev:Keeper_turn_fsm.Cascade_routing
            (Keeper_turn_fsm.Failed
               (Keeper_turn_fsm.Failure_provider_error
                  { kind = sdk_error_kind err;
                    detail = error_message }));
          Error err
      | Ok initial_execution ->
      let turn_id = meta.runtime.usage.total_turns in
      (match
         Keeper_turn_livelock.guard_and_record_turn_start
           ~keeper:meta.name
           ~turn_id
           ~max_attempts:(turn_livelock_max_attempts ())
           ~stuck_after_sec:(turn_livelock_stuck_after_sec ())
           ()
       with
       | Keeper_turn_livelock.Blocked reason ->
           let reason_string =
             Keeper_turn_livelock.gate_reason_to_string reason
           in
           let terminal_reason_code =
             Printf.sprintf "turn_livelock:%s" reason_string
           in
           let error_message =
             Printf.sprintf "keeper turn livelock blocked: %s"
               reason_string
           in
           Log.Keeper.error
             ~keeper_name:meta.name ~turn_id:keeper_turn_id
             "%s: keeper turn livelock guard blocked dispatch turn=%d: %s"
             meta.name turn_id
             reason_string;
           Prometheus.inc_counter
             Keeper_metrics.metric_keeper_turn_livelock_blocks
             ~labels:[("keeper", meta.name)]
             ();
           record_pre_dispatch_terminal_observation
             ~config
             ~meta
             ~generation
             ~cascade_name:initial_execution.cascade_name
             (* β6: "blocked" was not in outcome_kind quad-state
                (ok/skipped/error/cancelled), causing operator_disposition
                to classify livelock-blocked turns as "unknown".  Map to
                "error" — livelock IS a turn failure; the specific reason
                is captured in terminal_reason_code. *)
             ~outcome:"error"
             ~terminal_reason_code
             ~activity_kind:"keeper.turn_blocked"
             ~trajectory_outcome:(Trajectory.Gated terminal_reason_code)
             ~error_kind:
               (Keeper_execution_receipt.error_kind_of_string
                  "turn_livelock_blocked")
             ~error_message
             ~keeper_turn_id
             ();
           Keeper_turn_fsm.emit_transition
             ~keeper_name:meta.name ~turn_id:keeper_turn_id
             ~prev:Keeper_turn_fsm.Cascade_routing
             (Keeper_turn_fsm.Failed
                (Keeper_turn_fsm.Failure_turn_livelock_blocked
                   { reason = reason_string }));
           Error (Agent_sdk.Error.Internal error_message)
       | Keeper_turn_livelock.Started _ ->
      Keeper_turn_fsm.emit_transition
        ~keeper_name:meta.name ~turn_id:keeper_turn_id
        ~prev:Keeper_turn_fsm.Cascade_routing
        Keeper_turn_fsm.Awaiting_provider;
      (* Yield before CPU-bound prompt construction so the Eio scheduler
         can service HTTP handlers between keeper turn setups. *)
      Eio.Fiber.yield ();
      (* 2. Build unified prompt — diversity entropy recorded in decision_audit
         (keeper_keepalive.ml), not injected into prompt (#6814). *)
      let system_prompt, user_message =
        Keeper_unified_prompt.build_prompt ~meta ~base_path:config.base_path
          ~observation ()
      in
      Eio.Fiber.yield ();
      let base_dir = session_base_dir config in
      (* Ensure session dir tree for filesystem fallback (issue #3019) *)
      Keeper_types.mkdir_p (Filename.concat base_dir (Keeper_id.Trace_id.to_string meta.runtime.trace_id));
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
          : Keeper_agent_run.turn_prompt =
        (* Unified path already places soft context (continuity, worktree)
           in the user_message via Keeper_unified_prompt.build_prompt.
           No dynamic_context needed here. *)
        { system_prompt; dynamic_context = "" }
      in
      let prompt_timeout_metrics =
        Keeper_agent_run.build_prompt_metrics ~system_prompt
          ~dynamic_context:"" ~user_message
      in
      let prompt_timeout_estimate_tokens =
        max 1 prompt_timeout_metrics.estimated_total_tokens
      in
      let turn_affordances =
        Keeper_unified_metrics.observed_affordances_of_observation ~meta observation
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
      let mutating_tools_committed = ref [] in
      let post_commit_failure_reason = ref None in
      let paused_meta_override = ref None in
      let current_turn_overflow_blocker = ref None in
      let event_bus_drain_cancel = ref None in
      let turn_event_bus_mu = Eio.Mutex.create () in
      let mark_paused_after_overflow ~run_meta ~reason =
        let paused_meta =
          pause_keeper_for_overflow
            ~config
            ~meta:run_meta
            ~reason
        in
        paused_meta_override := Some paused_meta
      in
      (* Side-effect tracking is driven by the OAS Event_bus (ToolCalled +
         ToolCompleted) rather than MASC-side observers. Pairing is by
         tool_name order within the per-turn subscription, which is safe
         because the turn is single-fibered and filter_agent restricts to
         this keeper. *)
      let event_bus_sub =
        match Keeper_event_bus.get () with
        | Some bus ->
          Some (Agent_sdk_metrics_bridge.subscribe
                  ~purpose:"keeper_turn"
                  ~filter:(Agent_sdk.Event_bus.filter_agent meta.name) bus)
        | None -> None
      in
      let turn_event_bus = ref empty_turn_event_bus_summary in
      (* Per-tool-name queue of pending inputs from ToolCalled events.
         ToolCompleted pops the oldest input for that tool_name. *)
      let pending_tool_inputs : (string, Yojson.Safe.t Queue.t) Hashtbl.t =
        Hashtbl.create 8
      in
      let with_turn_event_bus_lock f =
        Eio.Mutex.use_rw ~protect:true turn_event_bus_mu f
      in
      let push_pending_input tool_name input =
        let q =
          match Hashtbl.find_opt pending_tool_inputs tool_name with
          | Some q -> q
          | None ->
              let q = Queue.create () in
              Hashtbl.add pending_tool_inputs tool_name q;
              q
        in
        Queue.add input q
      in
      let pop_pending_input tool_name =
        match Hashtbl.find_opt pending_tool_inputs tool_name with
        | Some q when not (Queue.is_empty q) -> Some (Queue.pop q)
        | _ -> None
      in
      let process_tool_events_for_side_effects
          (events : Agent_sdk.Event_bus.event list) : unit =
        List.iter
          (fun (evt : Agent_sdk.Event_bus.event) ->
            match evt.payload with
            | Agent_sdk.Event_bus.ToolCalled { tool_name; input; _ } ->
                push_pending_input tool_name input
            | Agent_sdk.Event_bus.ToolCompleted
                { tool_name; output = Ok _; _ } ->
                let input_opt = pop_pending_input tool_name in
                let input =
                  match input_opt with
                  | Some i -> i
                  | None ->
                      (* P2 silent-failure fix: pop_pending_input returns
                         None either when there's no queue for this tool
                         name, or when the queue is empty.  Either case
                         means a ToolCompleted arrived without a matching
                         ToolCalled — likely a race or an OAS event-bus
                         ordering bug.  Falling back to `Null` lets
                         downstream `has_mutating_side_effect_with_input`
                         continue, but it can undercount mutations.
                         Logging surfaces the mismatch so it can be
                         diagnosed instead of silently skewing audit data. *)
                      Log.Keeper.debug
                        "keeper:%s tool=%s ToolCompleted without matching ToolCalled — using Null input"
                        meta.name tool_name;
                      `Null
                in
                if
                  Keeper_exec_tools.has_mutating_side_effect_with_input
                    ~tool_name ~input
                then
                  mutating_tools_committed :=
                    tool_name :: !mutating_tools_committed
            | Agent_sdk.Event_bus.ToolCompleted
                { tool_name; output = Error _; _ } ->
                (* Failed tool: drop the matching pending input. *)
                let _ = pop_pending_input tool_name in
                ignore tool_name
            | _ -> ())
          events
      in
      (* PR-J: [?site] labels the call-site so PromQL can attribute
         drain pressure to background polling vs unsubscribe vs the
         retry path. [outcome=drained] when at least one event was
         pulled, [outcome=empty] otherwise (the latter is the no-op
         tick that establishes the lock-acquire baseline). *)
      let drain_turn_event_bus ?(site = "unspecified") () =
        with_turn_event_bus_lock (fun () ->
          let events =
            match event_bus_sub, Keeper_event_bus.get () with
            | Some sub, Some _bus -> Agent_sdk_metrics_bridge.drain sub
            | _ -> []
          in
          let outcome = if events = [] then "empty" else "drained" in
          Prometheus.inc_counter Keeper_metrics.metric_keeper_event_bus_drain
            ~labels:[("site", site); ("outcome", outcome)] ();
          process_tool_events_for_side_effects events;
          let summary = summarize_turn_event_bus events in
          turn_event_bus :=
            merge_turn_event_bus_summary !turn_event_bus summary;
          !turn_event_bus)
      in
      let committed_mutating_tools_snapshot () =
        with_turn_event_bus_lock (fun () ->
          EC.committed_mutating_tools !mutating_tools_committed)
      in
      let start_background_turn_event_bus_drain ~clock =
        match event_bus_sub, Eio_context.get_switch_opt () with
        | Some _, Some sw ->
            Eio.Fiber.fork ~sw (fun () ->
              Eio.Cancel.sub (fun cc ->
                event_bus_drain_cancel := Some cc;
                let rec loop () =
                  try
                    ignore (drain_turn_event_bus ~site:"background_poll" ());
                  with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                    Log.Keeper.warn
                      "%s: keeper_turn event-bus drain failed: %s"
                      meta.name (Printexc.to_string exn);
                    Prometheus.inc_counter
                      Keeper_metrics.metric_keeper_event_bus_drain
                      ~labels:[("site", "background_poll"); ("outcome", "exception")]
                      ();
                  (* 2026-04-20: 0.25s → 0.05s.  OAS publishes a burst
                     of events per tool cycle (ToolCalled / ToolResult /
                     ToolCompleted + assistant / usage).  With 0.25s
                     polling, a tool-heavy turn could accumulate >256
                     events for this subscriber before the next drain,
                     saturating the default Eio.Stream buffer and
                     blocking [oas_bus_instrument.publish].  Fleet logs
                     2026-04-20 recorded subscriber_purpose=keeper_turn
                     depth peaks 219–469 (the 469 sample confirmed
                     publishers blocked: 469 − 256 buffer ≈ 213 stuck
                     sends).  50 ms keeps drain latency under the
                     typical inter-event spacing so depth stays below
                     the warn threshold outside tool bursts.  Override
                     via [MASC_KEEPER_TURN_DRAIN_INTERVAL_SEC]. *)
                  Eio.Time.sleep clock (turn_event_bus_drain_interval_sec ());
                  loop ()
                in
                loop ()))
        | _ -> ()
      in
      let unsubscribe_event_bus () =
        (match !event_bus_drain_cancel with
         | Some cc ->
           event_bus_drain_cancel := None;
           (try Eio.Cancel.cancel cc (Failure "event_bus_unsubscribed") with
            | Eio.Cancel.Cancelled _ -> ()
            | Invalid_argument msg ->
                Log.Keeper.debug
                  "%s: event bus drain cancel ignored after context finish: %s"
                  meta.name msg)
         | None -> ());
        ignore (drain_turn_event_bus ~site:"unsubscribe_final" ());
        match event_bus_sub, Keeper_event_bus.get () with
        | Some sub, Some bus -> Agent_sdk_metrics_bridge.unsubscribe bus sub
        | _ -> ()
      in
      (* Mark turn boundary for the composite observer (issue #7122).
         [mark_turn_started] installs [current_turn_observation = Some _]
         so the composite observer can surface live in-turn states like
         [`Executing`]. The matching [mark_turn_finished] in the finally
         block clears the field, preventing stale state on idle keepers. *)
      Keeper_registry.mark_turn_started
        ~base_path:config.base_path meta.name;
      let meta =
        match Keeper_registry.get ~base_path:config.base_path meta.name with
        | Some entry ->
          let () =
            match write_meta_with_merge
              ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
              config entry.meta
            with
            | Ok () -> ()
            | Error err ->
                Prometheus.inc_counter
                  Keeper_metrics.metric_keeper_write_meta_failures
                  ~labels:
                    [("keeper", entry.meta.name); ("phase", "turn_start")]
                  ();
                Log.Keeper.warn
                  "%s: turn-start write_meta_with_merge failed: %s"
                  entry.meta.name err
          in
          entry.meta
        | None -> meta
      in
      Keeper_registry.mark_turn_measurement
        ~base_path:config.base_path meta.name;
      (match Keeper_registry.get ~base_path:config.base_path meta.name with
       | Some { current_turn_observation = Some { measurement = Some _; _ }; _ } ->
           Keeper_registry.set_turn_decision_stage
             ~base_path:config.base_path meta.name
             Keeper_registry.Decision_guard_ok
       | _ -> ());
      let last_execution = ref initial_execution in
      let last_timeout_budget : oas_timeout_budget_resolution option ref = ref None in
      let degraded_retry_info = ref None in
      let cascade_rotation_attempts = ref [] in
      let record_cascade_rotation_attempt
          ?slot_release_at_phase
          ?productive_phase_elapsed_ms
          ?retry_phase_elapsed_ms
          ~(from_cascade : Keeper_execution_receipt.cascade_name)
          ~(retry : EC.degraded_retry)
          ~(outcome : string)
          (err : Agent_sdk.Error.sdk_error) =
        let attempt : Keeper_execution_receipt.cascade_rotation_attempt =
          {
            from_cascade;
            to_cascade =
              Keeper_execution_receipt.cascade_name_of_string retry.next_cascade;
            reason = retry.fallback_reason;
            outcome;
            slot_release_at_phase;
            productive_phase_elapsed_ms;
            retry_phase_elapsed_ms;
            error_kind =
              Some
                (Keeper_execution_receipt.error_kind_of_string
                   (sdk_error_kind err));
            error_message = Some (Agent_sdk.Error.to_string err);
            recorded_at = now_iso ();
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
               meta.name (Printexc.to_string e);
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_turn_cleanup_failures
               ~labels:[("keeper", meta.name); ("site", "unsubscribe_event_bus")]
               ());
          (try
             Keeper_registry.mark_turn_finished
               ~base_path:config.base_path meta.name
           with
           | Eio.Cancel.Cancelled _ -> ()
           | e ->
             Log.Keeper.warn
               "%s: mark_turn_finished in turn cleanup raised: %s"
               meta.name (Printexc.to_string e);
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_turn_cleanup_failures
               ~labels:[("keeper", meta.name); ("site", "mark_turn_finished")]
               ());
        in
        match
        Keeper_exec_context.timed (fun () ->
          match Eio_context.get_clock () with
          | Error msg -> Error (Agent_sdk.Error.Internal msg)
          | Ok clock ->
          let timeout_sec =
            Keeper_runtime_resolved.turn_timeout_sec ()
          in
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
            | None -> (elapsed_ms (now -. turn_started_at), Some 0)
            | Some retry_started_at ->
                ( elapsed_ms (retry_started_at -. turn_started_at),
                  Some (elapsed_ms (now -. retry_started_at)) )
          in
          let keeper_profile =
            Keeper_types_profile.load_keeper_profile_defaults meta.name
          in
          let max_idle_turns, max_turns =
            match channel with
            | Keeper_world_observation.Reactive ->
                ( Keeper_runtime_resolved.reactive_max_idle_turns (),
                  Keeper_types_profile.effective_max_turns_per_call
                    keeper_profile )
            | Keeper_world_observation.Scheduled_autonomous ->
                ( Keeper_runtime_resolved.autonomous_max_idle_turns (),
                  Keeper_types_profile
                  .effective_max_turns_per_call_scheduled_autonomous
                    keeper_profile )
          in
          let initial_tool_requirement =
            if
              Keeper_agent_run.should_require_tools_for_initial_turn
                ~max_turns ~turn_affordances
            then Keeper_agent_tool_surface.Required
            else Keeper_agent_tool_surface.Optional
          in
          let do_run ~(execution : cascade_execution) ~run_meta ~run_generation ~is_retry
              ~oas_timeout_s ~attempt_watchdog_s =
            last_execution := execution;
            Otel_genai.with_keeper_turn_span
              ~keeper_name:run_meta.name
              ~agent_name:run_meta.agent_name
              ~cascade_name:execution.cascade_name
              ~trace_id:(Keeper_id.Trace_id.to_string run_meta.runtime.trace_id)
              ~generation:run_generation
              ~max_context:execution.max_context
              ~max_turns
              ~max_idle_turns
              ~channel:(Keeper_world_observation.channel_to_string channel)
              ~is_retry
              ~current_task_id:
                (Option.map Keeper_id.Task_id.to_string
                   run_meta.current_task_id)
              (fun () ->
                Keeper_turn_fsm.emit_transition
                  ~keeper_name:meta.name ~turn_id:keeper_turn_id
                  ~prev:Keeper_turn_fsm.Awaiting_provider
                  Keeper_turn_fsm.Streaming;
                try
                  Eio.Time.with_timeout_exn clock attempt_watchdog_s (fun () ->
                      Keeper_agent_run.run_turn ~config ~meta:run_meta ~base_dir
                        ~max_context:execution.max_context ~build_turn_prompt
                        ~user_message ~cascade_name:execution.cascade_name
                        ~world_observation:observation
                        ~turn_affordances
                        ?provider_filter:
                          (Env_config_keeper.KeeperCascade.provider_allowlist ())
                        ~generation:run_generation
                        ~max_turns
                        ~max_idle_turns
                        ~history_user_source:"world_state_prompt"
                        ~history_assistant_source:"internal_assistant"
                        ~degraded_retry_applied:(Option.is_some !degraded_retry_info)
                        ?degraded_retry_cascade:
                          (Option.map
                             (fun (retry : EC.degraded_retry) -> retry.next_cascade)
                             !degraded_retry_info)
                        ?fallback_reason:
                          (Option.map
                             (fun (retry : EC.degraded_retry) -> retry.fallback_reason)
                             !degraded_retry_info)
                        ~cascade_rotation_attempts:
                          (List.rev !cascade_rotation_attempts)
                        ~temperature:execution.temperature
                        ~max_tokens:execution.max_tokens
                        ~oas_timeout_s
                        ?max_cost_usd
                        ~trajectory_acc
                        ~is_retry
                        ?shared_context
                        ?event_bus:(Keeper_event_bus.get ())
                        ())
                with Eio.Cancel.Cancelled _ as e ->
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
                          {
                            message =
                              Printf.sprintf
                                "Turn wall-clock budget exhausted during cascade attempt \
                                 (budget=%.1fs, watchdog=%.1fs)"
                                oas_timeout_s attempt_watchdog_s;
                          })))
          in
          let fail_open_rotation_cascades =
            active_fail_open_rotation_cascades ()
          in
          let rec retry_loop ~run_meta ~(execution : cascade_execution)
              ~run_generation
              ~attempt ~is_retry
              ~allow_degraded_wall_clock_retry_budget
              ~overflow_retry_used
              ~attempted_cascades =
            let execution_cascade_name =
              KCP.runtime_name_to_string execution.cascade_name
            in
            let mark_terminal_error err =
              if EC.is_cascade_exhausted_error err then begin
                Keeper_registry.set_turn_cascade_state
                  ~base_path:config.base_path meta.name
                  Keeper_registry.Cascade_exhausted;
                Prometheus.inc_counter
                  Keeper_metrics.metric_keeper_fsm_edge_transitions
                  ~labels:[("edge", "kcl_to_ktc_exhaustion")] ();
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
                  meta.name (Agent_sdk.Error.to_string err) attempt
                  (String.concat ", " attempted_cascades);
                Prometheus.inc_counter
                  Keeper_metrics.metric_keeper_oas_execution_errors
                  ~labels:[("keeper", meta.name); ("phase", "cascade_exhausted")]
                  ()
              end
              else begin
                Keeper_registry.set_turn_phase
                  ~base_path:config.base_path meta.name
                  Keeper_registry.Turn_finalizing;
                (* Cycle 52 narrative companion: non-exhaustion terminal
                   errors (transient).  Logged so dashboard readers can
                   distinguish exhaustion from transient failure without
                   re-parsing Turn_finalizing reason fields. *)
                Prometheus.inc_counter
                  Keeper_metrics.metric_keeper_oas_execution_errors
                  ~labels:[("keeper", meta.name); ("phase", "terminal_non_exhaustion")]
                  ();
                Log.Keeper.warn
                  "%s: turn terminal (non-exhaustion error) — err=%s \
                   attempt=%d"
                  meta.name (Agent_sdk.Error.to_string err) attempt
              end
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
              let reserve_degraded_retry_budget =
                match
                  Keeper_cascade_profile.fallback_cascade_for
                    execution_cascade_name
                with
                | Some fallback_cascade ->
                    not (String.equal fallback_cascade execution_cascade_name)
                | None -> false
              in
              let allow_wall_clock_retry_budget =
                allow_wall_clock_retry_budget_for_attempt
                  ~is_retry
                  ~degraded_rotation_first_attempt:allow_degraded_wall_clock_retry_budget
                  ~attempt
                  ~attempted_cascades
              in
              match
                resolve_bounded_oas_timeout_budget_with_turn_budget
                  ~allow_wall_clock_retry_budget
                  ~is_retry
                  ~reserve_degraded_retry_budget
                  ~max_turns
                  ~estimated_input_tokens:prompt_timeout_estimate_tokens
                  ~remaining_turn_budget_s:(remaining_turn_budget_s ())
              with
              | None ->
                  Error
                    (Oas_worker_named.sdk_error_of_masc_internal_error
                       (Oas_worker_named.Oas_timeout_budget
                          {
                            budget_sec = 0.0;
                            keeper_turn_timeout_sec = timeout_sec;
                            estimated_input_tokens =
                              prompt_timeout_estimate_tokens;
                            source =
                              (if is_retry then "pre_retry_budget_unavailable"
                               else "pre_attempt_budget_unavailable");
                            remaining_turn_budget_sec =
                              Some (remaining_turn_budget_s ());
                            min_required_sec = min_oas_timeout_budget_sec;
                            phase =
                              (if is_retry then "pre_retry_budget_gate"
                               else "pre_attempt_budget_gate");
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
                  do_run ~execution ~run_meta ~run_generation ~is_retry
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
                  ~base_path:config.base_path meta.name
                  selected_model;
                Keeper_registry.set_turn_cascade_state
                  ~base_path:config.base_path meta.name
                  Keeper_registry.Cascade_done;
                Ok result
            | Error err ->
                let err =
                  reclassify_oas_timeout_for_attempt
                    ~timeout_budget:!attempt_timeout_budget err
                in
                let _ = drain_turn_event_bus ~site:"reconcile_pre_check" () in
                let committed_tools = committed_mutating_tools_snapshot () in
                if committed_tools <> []
                   && Keeper_tool_registry.all_tools_reconcile_safe
                        committed_tools
                   && (EC.is_auto_recoverable_turn_error err
                       || EC.is_required_tool_contract_violation err)
                then begin
                  (* All committed tools are board-like (duplicate-tolerant)
                     AND the failure is transient or the server rejected the
                     request body before processing (parse error).  Parse
                     errors mean the LLM never saw the request, so no risk
                     of duplicate processing.  The keeper's next cycle will
                     build a fresh prompt that may avoid the parse issue. *)
                  let err_preview = short_preview (Agent_sdk.Error.to_string err) in
                  let reason =
                    if EC.is_server_rejected_parse_error err then "server parse rejection"
                    else if EC.is_required_tool_contract_violation err then
                      "required tool contract violation"
                    else "transient error"
                  in
                  Log.Keeper.warn
                    "%s: %s after committed reconcile-safe tool(s) [%s] — auto-recovering (error: %s)"
                    meta.name reason
                    (String.concat ", " committed_tools)
                    err_preview;
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_turn_error_after_tools
                    ~labels:[("keeper", meta.name); ("reason", reason)]
                    ();
                  mark_terminal_error err;
                  Error err
                end else if committed_tools <> [] then begin
                  let reclassified, failure_reason =
                    match
                      EC.classify_post_commit_failure
                        ~tool_names:committed_tools
                        err
                    with
                    | Some classified -> classified
                    | None ->
                        ( EC.reclassify_error_after_side_effect
                            ~tool_names:committed_tools err,
                          Keeper_registry.Ambiguous_partial_commit {
                            kind = Keeper_registry.Post_commit_failure;
                            detail =
                              EC.summarize_post_commit_failure
                                ~tool_names:committed_tools
                                ~kind:Keeper_registry.Post_commit_failure
                                err;
                          } )
                  in
                  post_commit_failure_reason := Some failure_reason;
                  let err_preview = short_preview (Agent_sdk.Error.to_string err) in
                  if EC.is_transient_network_error err then begin
                    Prometheus.inc_counter
                      Keeper_metrics.metric_keeper_post_turn_wirein_failures
                      ~labels:[("keeper", meta.name); ("site", "post_commit_transient")]
                      ();
                    Log.Keeper.error
                      "%s: transient provider error after committed mutating tool call(s) [%s] — treating as integrity failure, skipping retry to prevent duplicate (error: %s)"
                      meta.name
                      (String.concat ", " committed_tools)
                      err_preview
                  end else
                    Log.Keeper.error
                      "%s: error after committed mutating tool call(s) [%s] — turn outcome is ambiguous and requires reconcile (error: %s)"
                      meta.name
                      (String.concat ", " committed_tools)
                      err_preview;
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_turn_error_after_tools
                    ~labels:[("keeper", meta.name)]
                    ();
                  mark_terminal_error reclassified;
                  Error reclassified
                end else if
                  (* Fast-fail after one cascade rotation for a contract
                     violation: if the LLM called no tools or only used
                     passive/read-only tools on the first cascade and the
                     same pattern repeats on a rotated cascade, further
                     rotation is unlikely to change the model's tool-use
                     choice on the same prompt.  Each rotation eats ~600s of
                     turn budget; in production we observed 4–5 rotations all
                     hitting the same violation before the OAS retry guard
                     finally aborted the cycle (see fleet logs:
                     "passive status/read tools" cascade=big_three →
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
                    match
                      KCP.fallback_cascade_for execution_cascade_name
                    with
                    | Some fb ->
                        not (List.exists (String.equal fb) attempted_cascades)
                        && not (String.equal fb execution_cascade_name)
                    | None -> false
                  in
                  EC.should_cap_rotation_for_contract_violation
                    ~attempted_cascades
                    ~fallback_not_yet_tried
                    err
                then begin
                  Log.Keeper.warn
                    "%s: required_tool_contract_violation after rotation \
                     (%s, %d cascade(s) attempted) — skipping further \
                     rotation; rotating again is unlikely to change the \
                     model's tool-use choice. Error: %s"
                    meta.name execution_cascade_name
                    (List.length attempted_cascades)
                    (short_preview (Agent_sdk.Error.to_string err));
                  Prometheus.inc_counter
                    "masc_keeper_contract_violation_rotation_capped_total"
                    ~labels:[ ("keeper", meta.name) ]
                    ();
                  mark_terminal_error err;
                  Error err
                end else
                  (* Budget gate: check whether there is enough wall-clock
                     remaining to schedule a degraded cascade retry.  The
                     gate always uses per-attempt semantics (fresh floor) for
                     the candidate because, by definition, every degraded
                     retry is itself a retry — even when the failing attempt
                     was the first attempt (is_retry=false here). *)
                  match
                    next_fail_open_cascade_for_turn_with_budget
                      ?rotation_cascades:fail_open_rotation_cascades
                      ~base_cascade:meta.cascade_name
                      ~effective_cascade:execution_cascade_name
                      ~tool_requirement:initial_tool_requirement
                      ~attempted_cascades
                      ~estimated_input_tokens:
                        prompt_timeout_estimate_tokens
                      ~max_turns
                      ~time_spent_in_turn_s:
                        (timeout_sec -. remaining_turn_budget_s ())
                      ~remaining_turn_budget_s:(remaining_turn_budget_s ())
                      err
                  with
                  | Degraded_retry_allowed degraded_retry -> (
                      match
                        build_cascade_execution
                          ~cascade_name:
                            (KCP.Runtime_name degraded_retry.next_cascade)
                      with
                      | Error fail_open_err ->
                          let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
                            current_turn_phase_elapsed_ms ()
                          in
                          record_cascade_rotation_attempt
                            ~slot_release_at_phase:"retry_setup_failed"
                            ~productive_phase_elapsed_ms
                            ?retry_phase_elapsed_ms
                            ~from_cascade:execution.cascade_name
                            ~retry:degraded_retry
                            ~outcome:"setup_failed"
                            fail_open_err;
                          Log.Keeper.warn
                            "%s: recoverable cascade failure in %s suggested degraded retry to %s (reason=%s), but retry setup failed: %s"
                            meta.name execution_cascade_name
                            degraded_retry.next_cascade
                            degraded_retry.fallback_reason
                            (short_preview (Agent_sdk.Error.to_string fail_open_err));
                          mark_terminal_error fail_open_err;
                          Error fail_open_err
                      | Ok next_execution ->
                          let next_execution_cascade_name =
                            KCP.runtime_name_to_string
                              next_execution.cascade_name
                          in
                          if Option.is_none !retry_phase_started_at then
                            retry_phase_started_at := Some (Eio.Time.now clock);
                          let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
                            current_turn_phase_elapsed_ms ()
                          in
                          let slot_release_at_phase =
                            match turn_slot_control with
                            | Some slot_control ->
                                slot_control.Keeper_turn_slot.release_for_retry ();
                                Some "retry_scheduled"
                            | None -> None
                          in
                          record_cascade_rotation_attempt
                            ?slot_release_at_phase
                            ~productive_phase_elapsed_ms
                            ?retry_phase_elapsed_ms
                            ~from_cascade:execution.cascade_name
                            ~retry:degraded_retry
                            ~outcome:"retry_scheduled"
                            err;
                          degraded_retry_info := Some degraded_retry;
                          Log.Keeper.warn
                            "%s: recoverable cascade failure in %s; rotation retry on cascade=%s reason=%s max_context=%d context_budget=%d primary_budget=%d requested_override=%s: %s"
                            meta.name execution_cascade_name
                            next_execution_cascade_name
                            degraded_retry.fallback_reason
                            next_execution.max_context
                            next_execution.max_context_resolution.effective_budget
                            next_execution.max_context_resolution.primary_budget
                            (match
                               next_execution.max_context_resolution.requested_override
                             with
                            | Some requested -> string_of_int requested
                            | None -> "none")
                            (short_preview (Agent_sdk.Error.to_string err));
                          Eio.Fiber.yield ();
                          let run_retry_after_reacquire () =
                            retry_loop ~run_meta ~execution:next_execution
                              ~run_generation
                              ~attempt:1
                              ~is_retry:true
                              ~allow_degraded_wall_clock_retry_budget:true
                              ~overflow_retry_used
                              ~attempted_cascades:
                                (next_execution_cascade_name :: attempted_cascades)
                          in
                          match turn_slot_control with
                          | None -> run_retry_after_reacquire ()
                          | Some slot_control -> (
                              match
                                slot_control.Keeper_turn_slot.reacquire_after_retry ()
                              with
                              | Ok retry_semaphore_wait_ms ->
                                  Log.Keeper.info
                                    "%s: reacquired keeper turn slot for degraded retry on cascade=%s wait_ms=%d"
                                    meta.name
                                    next_execution_cascade_name
                                    retry_semaphore_wait_ms;
                                  run_retry_after_reacquire ()
                              | Error (`Semaphore_wait_timeout timeout) ->
                                  let slot_err =
                                    sdk_error_of_retry_slot_reacquire_timeout
                                      ~keeper_name:meta.name timeout
                                  in
                                  Log.Keeper.warn
                                    "%s: degraded retry to %s skipped because turn slot reacquire timed out: %s"
                                    meta.name
                                    next_execution_cascade_name
                                    (short_preview
                                       (Agent_sdk.Error.to_string slot_err));
                                  mark_terminal_error slot_err;
                                  Error slot_err))
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
                        ~slot_release_at_phase:"retry_budget_exhausted"
                        ~productive_phase_elapsed_ms
                        ?retry_phase_elapsed_ms
                        ~from_cascade:execution.cascade_name
                        ~retry:degraded_retry
                        ~outcome:"budget_exhausted"
                        err;
                      Log.Keeper.warn
                        "%s: recoverable cascade failure in %s suggested degraded retry to %s (reason=%s), but remaining turn budget %.1fs is below the OAS retry guard/minimum; ending this cycle: %s"
                        meta.name execution_cascade_name
                        degraded_retry.next_cascade
                        degraded_retry.fallback_reason
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
                        ~slot_release_at_phase:"productive_phase_exhausted"
                        ~productive_phase_elapsed_ms
                        ?retry_phase_elapsed_ms
                        ~from_cascade:execution.cascade_name
                        ~retry:degraded_retry
                        ~outcome:"slot_phase_exhausted"
                        err;
                      Log.Keeper.warn
                        "%s: recoverable cascade failure in %s suggested degraded retry to %s (reason=%s), but productive slot phase budget %.1fs is exhausted after %.1fs; ending this cycle to release the outer turn slot: %s"
                        meta.name execution_cascade_name
                        degraded_retry.next_cascade
                        degraded_retry.fallback_reason
                        degraded_retry_slot_phase_budget_sec
                        (timeout_sec -. remaining_turn_budget_s ())
                        (short_preview (Agent_sdk.Error.to_string err));
                      mark_terminal_error err;
                      Error err
                  | No_degraded_retry when EC.is_transient_network_error err
                              && attempt <= EC.max_transient_retries () ->
                      let delay = EC.transient_backoff_sec attempt in
                      Log.Keeper.warn
                        "%s: transient network error cascade=%s max_context=%d context_budget=%d primary_budget=%d requested_override=%s retry=%d/%d backoff=%.0fs: %s"
                        meta.name execution_cascade_name
                        execution.max_context
                        execution.max_context_resolution.effective_budget
                        execution.max_context_resolution.primary_budget
                        (match execution.max_context_resolution.requested_override with
                         | Some requested -> string_of_int requested
                         | None -> "none")
                        attempt (EC.max_transient_retries ()) delay
                        (short_preview (Agent_sdk.Error.to_string err));
                      Prometheus.inc_counter
                        Keeper_metrics.metric_keeper_oas_execution_errors
                        ~labels:[("keeper", meta.name); ("phase", "recoverable_cascade_transient")]
                        ();
                      Eio.Time.sleep clock delay;
                      retry_loop ~run_meta ~execution ~run_generation
                        ~attempt:(attempt + 1)
                        ~is_retry:true
                        ~allow_degraded_wall_clock_retry_budget:false
                        ~overflow_retry_used
                        ~attempted_cascades
                  | No_degraded_retry when EC.is_context_overflow err ->
                  let current_turn_event_bus =
                    drain_turn_event_bus ~site:"context_overflow_capture" () in
                  dispatch_keeper_phase_event
                    ~config
                    ~keeper_name:meta.name
                    (context_overflow_event_of_error
                       ~fallback_tokens:execution.max_context
                       ~turn_event_bus:current_turn_event_bus
                       err);
                  if not overflow_retry_used then
                    match
                      recover_context_overflow_retry
                        ~meta:run_meta
                        ~base_dir
                        ~max_cascade_context:execution.max_context
                        ~error:err
                    with
                    | Some retry_plan ->
                        Keeper_registry.set_turn_phase
                          ~base_path:config.base_path meta.name
                          Keeper_registry.Turn_compacting;
                        current_turn_overflow_blocker :=
                          Some (Agent_sdk.Error.to_string err);
                        dispatch_keeper_phase_event
                          ~config
                          ~keeper_name:meta.name
                          Keeper_state_machine.Compaction_started;
                        Prometheus.inc_counter
                          Keeper_metrics.metric_keeper_fsm_edge_transitions
                          ~labels:[("edge", "kmc_to_ksm_compact_completed")] ();
                        dispatch_keeper_phase_event
                          ~config
                          ~keeper_name:meta.name
                          (Keeper_state_machine.Compaction_completed
                             {
                               before_tokens =
                                 retry_plan.compaction.before_tokens;
                               after_tokens =
                                 retry_plan.compaction.after_tokens;
                             });
                        Keeper_registry.prepare_turn_retry_after_compaction
                          ~base_path:config.base_path meta.name;
                        let retry_meta =
                          if retry_plan.retry_generation = run_meta.runtime.generation
                          then run_meta
                          else
                            map_runtime
                              (fun rt ->
                                {
                                  rt with
                                  generation = retry_plan.retry_generation;
                                })
                              run_meta
                        in
                        let retry_execution =
                          { execution with max_context = retry_plan.retry_max_context }
                        in
                        Eio.Fiber.yield ();
                        retry_loop
                          ~run_meta:retry_meta
                          ~execution:retry_execution
                          ~run_generation:retry_plan.retry_generation
                          ~attempt:1
                          ~is_retry:true
                          ~allow_degraded_wall_clock_retry_budget:false
                          ~overflow_retry_used:true
                          ~attempted_cascades
                    | None ->
                        mark_paused_after_overflow
                          ~run_meta
                          ~reason:"auto_compact_recovery_unavailable";
                        Keeper_registry.set_turn_phase
                          ~base_path:config.base_path meta.name
                          Keeper_registry.Turn_finalizing;
                        Error err
                  else begin
                    mark_paused_after_overflow
                      ~run_meta
                      ~reason:"overflow_persisted_after_auto_compact_retry";
                      Keeper_registry.set_turn_phase
                        ~base_path:config.base_path meta.name
                        Keeper_registry.Turn_finalizing;
                    Error err
                  end
                | No_degraded_retry ->
                    mark_terminal_error err;
                    Error err
          in
          (* Wall-clock timeout guards against indefinite TCP-level hangs
             from upstream LLM providers. Without this, a single stalled
             connection blocks the keeper fiber forever. *)
          (try
            Eio.Time.with_timeout_exn clock timeout_sec
              (fun () ->
                retry_loop ~run_meta:meta ~execution:initial_execution
                  ~run_generation:generation ~attempt:1
                  ~is_retry:false
                  ~allow_degraded_wall_clock_retry_budget:false
                  ~overflow_retry_used:false
                  ~attempted_cascades:
                    [ KCP.runtime_name_to_string initial_execution.cascade_name ])
          with Eio.Time.Timeout ->
            let msg =
              Printf.sprintf
                "Turn wall-clock timeout after %.0fs (MASC_KEEPER_TURN_TIMEOUT_SEC)"
                timeout_sec
            in
            Log.Keeper.error "%s: %s" meta.name msg;
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_turn_timeout_committed
              ~labels:[("keeper", meta.name)]
              ();
            let _ = drain_turn_event_bus ~site:"error_path_drain" () in
            let committed_tools = committed_mutating_tools_snapshot () in
            if committed_tools <> []
               && Keeper_tool_registry.all_tools_reconcile_safe
                    committed_tools
            then begin
              (* Timeouts are inherently transient — the provider was
                 reachable (tools executed) but took too long.  Board-only
                 committed tools are duplicate-tolerant, so we auto-recover
                 instead of recording an integrity failure.  Unlike the
                 retry_loop path, no is_transient check is needed: a
                 wall-clock timeout after successful tool execution is
                 always transient by nature. *)
              Log.Keeper.warn
                "%s: turn wall-clock timeout after committed reconcile-safe tool(s) [%s] — auto-recovering (timeout: %s)"
                meta.name
                (String.concat ", " committed_tools)
                msg;
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_turn_timeout_committed
                ~labels:[("keeper", meta.name)]
                ();
              Keeper_registry.set_turn_phase
                ~base_path:config.base_path meta.name
                Keeper_registry.Turn_finalizing;
              Error (Agent_sdk.Error.Api (Timeout { message = msg }))
            end else if committed_tools <> [] then begin
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
                        timeout_err,
                      Keeper_registry.Ambiguous_partial_commit {
                        kind = Keeper_registry.Post_commit_timeout;
                        detail =
                          EC.summarize_post_commit_failure
                            ~tool_names:committed_tools
                            ~kind:Keeper_registry.Post_commit_timeout
                            timeout_err;
                      } )
              in
              post_commit_failure_reason := Some failure_reason;
              Log.Keeper.error
                "%s: turn wall-clock timeout after committed mutating tool call(s) [%s] — treating as integrity failure; evidence recorded for next-turn observation"
                meta.name
                (String.concat ", " committed_tools);
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_turn_timeout_committed
                ~labels:[("keeper", meta.name)]
                ();
              Keeper_registry.set_turn_phase
                ~base_path:config.base_path meta.name
                Keeper_registry.Turn_finalizing;
              Error reclassified
            end else begin
              Keeper_registry.set_turn_phase
                ~base_path:config.base_path meta.name
                Keeper_registry.Turn_finalizing;
              Error
                (Oas_worker_named.sdk_error_of_masc_internal_error
                   (Oas_worker_named.Turn_timeout
                      { elapsed_sec = timeout_sec }))
            end))
        with
        | result -> cleanup (); result
        | exception e ->
            let backtrace = Printexc.get_raw_backtrace () in
            cleanup ();
            Printexc.raise_with_backtrace e backtrace
      in
      let turn_event_bus = drain_turn_event_bus ~site:"turn_finalize_capture" () in
      (match turn_event_bus.correlation_id with
       | Some correlation_id ->
           Keeper_registry.set_last_correlation_id
             ~base_path:config.base_path meta.name
             correlation_id
       | None -> ());
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
       | Some target ->
           let success =
             match run_result with
             | Ok _ -> true
             | Error _ -> false
           in
           Keeper_health_probe.record_item_result
             ~keeper_name:meta.name
             ~item_id:target.Keeper_cascade_selector.item.Cascade_ref.id
             ~success
       | None -> ());
      match run_result with
      | Error err ->
          let final_execution = !last_execution in
          finalize_trajectory_acc ~config ~keeper_name:meta.name trajectory_acc
            (Trajectory.Failed (Agent_sdk.Error.to_string err));
          let e_str = Agent_sdk.Error.to_string err in
          let is_transient = EC.is_transient_network_error err in
          (match Oas_worker_named.classify_masc_internal_error err with
           | Some (Oas_worker_named.Oas_timeout_budget _) ->
               Prometheus.inc_counter
                 Keeper_metrics.metric_keeper_oas_timeout_classifications
                 ~labels:[("classification", "structural_budget")] ()
           | Some (Oas_worker_named.Turn_timeout _) ->
               Prometheus.inc_counter
                 Keeper_metrics.metric_keeper_oas_timeout_classifications
                 ~labels:[("classification", "turn_wall_clock")] ()
           | _ -> (
               match err with
               | Agent_sdk.Error.Api (Timeout { message }) ->
               let classification =
                 if is_transient then "transient_network"
                 else if EC.is_structural_oas_timeout_message message then
                   "structural_budget"
                 else "other_timeout"
               in
               Prometheus.inc_counter
                 Keeper_metrics.metric_keeper_oas_timeout_classifications
                 ~labels:[("classification", classification)] ()
               | _ -> ()));
          let is_server_parse_rejection = EC.is_server_rejected_parse_error err in
          let is_auto_recoverable = EC.is_auto_recoverable_turn_error err in
          let is_ambiguous_partial = EC.is_ambiguous_side_effect_error err in
          Prometheus.inc_counter Keeper_metrics.metric_keeper_turns
            ~labels:[("keeper_name", meta.name); ("outcome", "failure")] ();
          Keeper_turn_fsm.emit_transition
            ~keeper_name:meta.name ~turn_id:keeper_turn_id
            ~prev:Keeper_turn_fsm.Streaming
            (Keeper_turn_fsm.Failed
               (Keeper_turn_fsm.Failure_provider_error
                  { kind = sdk_error_kind err;
                    detail = short_preview e_str }));
          Log.Keeper.error
            "%s: keeper cycle FAILED cascade=%s max_context=%d context_budget=%d primary_budget=%d requested_override=%s latency=%dms%s error=%s"
            meta.name
            (KCP.runtime_name_to_string final_execution.cascade_name)
            final_execution.max_context
            final_execution.max_context_resolution.effective_budget
            final_execution.max_context_resolution.primary_budget
            (match final_execution.max_context_resolution.requested_override with
             | Some requested -> string_of_int requested
             | None -> "none")
            latency_ms
            (if is_ambiguous_partial then
               " (ambiguous partial commit)"
             else if is_server_parse_rejection then
               " (server parse rejection, auto-recoverable)"
             else if is_transient then
               " (transient, cooldown preserved)"
             else "")
            (short_preview e_str);
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_oas_execution_errors
            ~labels:[("keeper", meta.name); ("phase", "cycle_failed")]
            ();
          let social_state, social_transition_reason =
            Social.derive_failure_state ~meta ~observation
              ~previous_state:previous_social_state
              ~is_auto_recoverable ~sdk_error:(Some err) ~reason:e_str
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
            if is_ambiguous_partial then begin
              (* Ambiguous partial commit must not auto-resume silently.
                 The keeper is paused and an explicit continue gate is
                 raised for the operator. Approving the gate auto-resumes
                 the keeper; rejecting it leaves the keeper paused. *)
              let committed_tools = committed_mutating_tools_snapshot () in
              let failure_reason =
                Option.value
                  ~default:
                    (Keeper_registry.Ambiguous_partial_commit {
                      kind = Keeper_registry.Post_commit_failure;
                      detail = e_str;
                    })
                  !post_commit_failure_reason
              in
              Keeper_registry.set_failure_reason ~base_path:config.base_path
                meta.name
                (Some failure_reason);
              match
                sync_keeper_paused_state
                  ~config
                  ~meta:updated_meta
                  ~paused:true
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
                    ~labels:[("keeper", meta.name); ("reason", "ambiguous_partial")]
                    ();
                  Log.Keeper.warn
                    "%s: ambiguous partial commit (tools=[%s], reason=%s); \
                     paused keeper and opened continue gate id=%s"
                    meta.name
                    (String.concat ", " committed_tools)
                    (Keeper_registry.failure_reason_to_string failure_reason)
                    approval_id;
                  (err, paused_meta)
              | Error sync_err ->
                  let combined_err =
                    Agent_sdk.Error.Internal
                      (Printf.sprintf
                         "%s: ambiguous partial commit pause sync failed: %s \
                          (original_error=%s)"
                         meta.name sync_err (short_preview e_str))
                  in
                  Log.Keeper.error "%s" (Agent_sdk.Error.to_string combined_err);
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_cascade_sync_failures
                    ~labels:[("keeper", meta.name); ("site", "ambiguous_partial_pause")]
                    ();
                  (combined_err, updated_meta)
            end else
              (err, updated_meta)
          in
          let e_str = Agent_sdk.Error.to_string err in
          let terminal_reason =
            Keeper_turn_terminal.of_failure
              ~post_commit_ambiguous:is_ambiguous_partial
              ~raw_error:e_str err
          in
          if not is_ambiguous_partial then begin
            match
              registry_failure_reason_of_terminal_reason terminal_reason
                ~raw_error:e_str
            with
            | Some failure_reason ->
                Keeper_registry.set_failure_reason
                  ~base_path:config.base_path meta.name
                  (Some failure_reason)
            | None -> ()
          end;
          (match
             Keeper_passive_loop_detector.progress_class_of_terminal_reason_code
               (Keeper_turn_terminal.code terminal_reason)
           with
           | Some progress_class ->
               Keeper_passive_loop_detector.record_turn
                 ~keeper_name:updated_meta.name ~progress_class
           | None -> ());
          Keeper_unified_metrics.append_decision_record ~config ~meta:updated_meta ~observation
            ~latency_ms ~semaphore_wait_ms
            ~outcome:(if is_ambiguous_partial then "partial" else "error")
            ~degraded_retry_applied
            ?degraded_retry_cascade
            ?fallback_reason
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
               config updated_meta
           with
           | Ok () -> ()
           | Error msg ->
               Prometheus.inc_counter
                 Keeper_metrics.metric_keeper_write_meta_failures
                 ~labels:
                   [ ("keeper", updated_meta.name);
                     ("phase",
                      if is_version_conflict_error msg
                      then "turn_failure_cas_race"
                      else "turn_failure")
                   ]
                 ();
               if is_version_conflict_error msg then
                 Log.Keeper.warn
                   "write_meta lost CAS race after retries (turn failure path): %s" msg
               else
                 Log.Keeper.error
                   "write_meta failed after unified turn failure: %s" msg);
                 Prometheus.inc_counter
                   Keeper_metrics.metric_keeper_write_meta_cycle_failures
                   ~labels:[("keeper", meta.name); ("site", "turn_failure")]
                   ();
          if is_ambiguous_partial then begin
            let failure_reason =
              Option.value
                ~default:
                  (Keeper_registry.Ambiguous_partial_commit {
                    kind = Keeper_registry.Post_commit_failure;
                    detail = e_str;
                  })
                !post_commit_failure_reason
            in
            Keeper_registry.set_failure_reason ~base_path:config.base_path
              meta.name
              (Some failure_reason);
            let committed_tools = committed_mutating_tools_snapshot () in
            Log.Keeper.info
              "%s: reconcile-required failure latched as %s after committed tools [%s]"
              meta.name
              (Keeper_registry.failure_reason_to_string failure_reason)
              (String.concat ", " committed_tools)
          end;
          let base_path = config.base_path in
          (* Transient errors (429 rate limit, 503 overloaded, network
             timeout) do not count toward the consecutive failure threshold.
             They are already retried at the turn level with backoff; killing
             the keeper fiber for a transient API blip is an overreaction
             that causes unnecessary restarts and context loss.
             Only persistent errors (auth failure, config error, context
             overflow after compaction) increment the crash counter.

             EXCEPTION: cascade exhaustion errors always increment the
             counter regardless of auto-recoverable classification.
             Auto-recoverable cascade subtypes (Candidates_filtered_after_cycles,
             Max_turns_exceeded) were skipping the counter, preventing
             auto-pause from ever triggering. The keeper would loop
             indefinitely on a broken cascade without operator notification.
             Retry eligibility != failure tracking. *)
          let counts_toward_crash =
            not is_auto_recoverable || EC.is_cascade_exhausted_error err
          in
          if counts_toward_crash then
            Keeper_registry.increment_turn_failures ~base_path meta.name
          else
            Log.Keeper.info
              "%s: auto-recoverable turn failure (not counted toward crash threshold): %s"
              meta.name (short_preview e_str);
          let count = Keeper_registry.get_turn_failures ~base_path meta.name in
          let threshold =
            Runtime_params.get Governance_registry.keeper_max_turn_failures
          in
          record_turn_failure_stress
            ~meta
            ~is_auto_recoverable
            ~consecutive:count
            ~threshold
            ~err;
          (* Stamp [last_failure_reason] on FIRST cascade_exhausted-class
             failure (not just at threshold).  Without this, the stale
             watchdog kills with [idle 328s] and operators see no signal
             until the 3rd failure trips auto-pause below — by which time
             the keeper has been silently burning cycles for ~90s on a
             cascade with zero callable models.

             Production evidence (2026-04-27 system_log): 18 events of
             "no callable models" today on cascade=keeper_unified, but
             [last_failure_reason] stayed None for the affected keepers
             so the watchdog kill message read [idle 328s] with no
             attribution.  Operators had no way to distinguish
             "stuck=cascade_exhausted" from "stuck=genuinely idle".

             Reset path is unchanged: any successful turn clears the
             field via [reset_turn_failures] + [set_failure_reason None]
             at line 966-967.  Auto-pause site below (line 2275) still
             stamps the same value at threshold — idempotent overwrite. *)
          if EC.is_cascade_exhausted_error err && count > 0 then
            Keeper_registry.set_failure_reason ~base_path:config.base_path
              meta.name
              (Some (Keeper_registry.Turn_consecutive_failures count));
          (* task-074 (#fleet-stall 2026-04-26): break the supervisor restart
             loop on cascade_exhausted. Without this guard, [count >= threshold]
             below raises [Keeper_fiber_crash], the supervisor restarts the
             fiber, the same cascade still has no working provider, and the
             keeper bursts then stalls again. Auto-pausing instead gives the
             operator a chance to fix the cascade before another restart cycle
             burns more turns. The pause uses the same [sync_keeper_paused_state]
             entry point as operator-driven pause, so [operator_paused] stays
             the SSOT — no new state surface, dashboard already renders this. *)
          let cascade_auto_paused =
            EC.is_cascade_exhausted_error err
            && count >= Keeper_behavioral_regime.turn_fail_streak_threshold
            && not updated_meta.paused
          in
          let tool_contract_auto_paused =
            should_auto_pause_required_tool_contract_violation
              ~paused:updated_meta.paused
              ~consecutive_failures:count err
          in
          let auto_pause_succeeded =
            if cascade_auto_paused || tool_contract_auto_paused then begin
              let released_task_id =
                if tool_contract_auto_paused then
                  Option.map Keeper_id.Task_id.to_string
                    updated_meta.current_task_id
                else None
              in
              let pause_meta =
                if tool_contract_auto_paused then
                  { updated_meta with current_task_id = None }
                else
                  updated_meta
              in
              match
                sync_keeper_paused_state ~config ~meta:pause_meta ~paused:true
              with
              | Ok _ ->
                  if cascade_auto_paused then begin
                    Keeper_registry.set_failure_reason ~base_path:config.base_path
                      meta.name
                      (Some (Keeper_registry.Turn_consecutive_failures count));
                    Log.Keeper.warn
                      "%s: auto-paused after %d cascade_exhausted failures \
                       (pause_threshold=%d, crash_threshold=%d); operator must \
                       resume after cascade fix"
                      meta.name count
                      Keeper_behavioral_regime.turn_fail_streak_threshold
                      threshold
                  end else
                    Log.Keeper.warn
                      "%s: auto-paused after %d required-tool contract \
                       failures (pause_threshold=%d, crash_threshold=%d, \
                       released_task=%s); operator must inspect provider tool \
                       contract before resuming"
                      meta.name count
                      Keeper_behavioral_regime.turn_fail_streak_threshold
                      threshold
                      (Option.value ~default:"none" released_task_id);
                  true
              | Error sync_err ->
                  let auto_pause_kind =
                    if cascade_auto_paused then "cascade" else "tool_contract"
                  in
                  Log.Keeper.error
                    "%s: %s auto-pause sync failed: %s \
                     (persistent failure remains on the crash path)"
                    meta.name auto_pause_kind sync_err;
                  Prometheus.inc_counter
                    Keeper_metrics.metric_keeper_cascade_sync_failures
                    ~labels:
                      [ ("keeper", meta.name);
                        ( "site",
                          if cascade_auto_paused then "auto_pause"
                          else "tool_contract_auto_pause" ) ]
                    ();
                  false
            end else
              false
          in
          if count >= threshold && not auto_pause_succeeded then begin
            Prometheus.inc_counter
              Keeper_metrics.metric_keeper_oas_execution_errors
              ~labels:[("keeper", meta.name); ("phase", "persistent_escalation")]
              ();
            Log.Keeper.error
              "%s: %d consecutive persistent turn failures (threshold=%d), escalating to supervisor crash path"
              meta.name count threshold;
            Keeper_registry.set_failure_reason ~base_path:config.base_path
              meta.name
              (Some (Keeper_registry.Turn_consecutive_failures count));
            raise Keeper_registry.Keeper_fiber_crash
          end;
          Error err
      | Ok result ->
          let final_execution = !last_execution in
          finalize_trajectory_acc ~config ~keeper_name:meta.name trajectory_acc
            Trajectory.Completed;
          let explicit_accountability_claim =
            Social.extract_accountability_claim result
          in
          let result, social_state, social_transition_reason =
            Social.apply_to_result ~meta ~observation
              ~previous_state:previous_social_state result
          in
          let used_model_id =
            Keeper_agent_run.surface_model_used result
          in
          let resolved_model_id =
            Keeper_agent_run.surface_resolved_model_id result
          in
          let usage_trust_for_cost =
            Keeper_unified_metrics.classify_usage_trust
              ~usage_reported:result.usage_reported
              ~usage:result.usage
              ~model_used:used_model_id
              ~resolved_model_id
              ~context_max:0
          in
          let turn_cost =
            Keeper_unified_metrics.estimate_trusted_usage_cost_usd
              ~usage_trusted:
                (Keeper_unified_metrics.usage_trust_is_trusted
                   usage_trust_for_cost)
              ~model:used_model_id
              result.usage
          in
          let resilience_handles =
            post_turn_resilience_handles ~config ~meta
          in
          let lifecycle =
            apply_post_turn_lifecycle_with_resilience_handles ~base_dir
              ~resilience_audit_store:
                resilience_handles.resilience_audit_store
              ~resilience_strategy_executor:
                resilience_handles.resilience_strategy_executor
              ~on_compaction_started:(fun () ->
                dispatch_keeper_phase_event
                  ~config
                  ~keeper_name:meta.name
                  Keeper_state_machine.Compaction_started)
              ~on_handoff_started:(fun () ->
                dispatch_keeper_phase_event
                  ~config
                  ~keeper_name:meta.name
                  Keeper_state_machine.Handoff_started)
              ~meta
              ~model:result.model_used
              ~primary_model_max_tokens:final_execution.max_context
              ~current_turn_overflow_blocker:!current_turn_overflow_blocker
              ~checkpoint:result.checkpoint
            |> resilience_handles.sync_lifecycle_meta
          in
          dispatch_post_turn_lifecycle_events
            ~config
            ~keeper_name:meta.name
            lifecycle;
          (* 6. Observe result and update metrics.
             Always update proactive_rt regardless of turn type.
             Previously, scope-only reactive turns (pending_scope but no
             mentions/board) skipped the timestamp update, freezing the
             proactive cooldown timer so the second autonomous turn never
             fired.  See Bug #3 in the root-cause analysis. *)
          let updated_meta =
            Keeper_unified_metrics.update_metrics_from_result lifecycle.updated_meta ~latency_ms
              ~observation
              ~social_state
              ~social_transition_reason:
                (Social.transition_reason_to_string social_transition_reason)
              ~context_max:lifecycle.context_max
              ~update_proactive_rt:true
              result
          in
          (* #9926: observe consecutive stay_silent turns to detect the
             masc-improver-style loop that burned 13.3h of LLM time on
             unclaimable backlog. Pure in-memory counter; fires a latched
             warn + counter metric when the streak crosses
             MASC_STAY_SILENT_LOOP_THRESHOLD (default 10). *)
          Keeper_stay_silent_loop_detector.record_turn
            ~keeper_name:updated_meta.Keeper_types.name
            ~speech_act:updated_meta.Keeper_types.runtime.last_speech_act;
          (* #12799: observe consecutive passive-read turns to detect keepers
             stuck issuing only status/read tools without execution progress.
             Derive the dominant progress class from the tool names used this
             turn: if all tools are passive_status / claim_context the streak
             increments; any execution or completion tool resets it. *)
          (let progress_class =
             let names = result.tools_used in
             if names = [] then
               (* No tools called: treat as passive.  A turn with no tool
                  calls is a pure reasoning/text turn — no execution or
                  task completion occurred, so it counts against the
                  passive streak rather than resetting it. *)
               "passive_status"
             else if List.for_all
                       (fun name ->
                          match
                            Keeper_tool_disclosure.classify_tool_progress name
                          with
                          | Keeper_tool_disclosure.Execution
                          | Keeper_tool_disclosure.Completion -> false
                          | Keeper_tool_disclosure.Passive_status
                          | Keeper_tool_disclosure.Claim_context -> true)
                       names
             then "passive_status"
             else "execution"
           in
           Keeper_passive_loop_detector.record_turn
             ~keeper_name:updated_meta.Keeper_types.name
             ~progress_class);
          (try
             (* Spec: KeeperTaskAcquisition.tla AssignTask vs
                EmptyQueueSleep — non-empty queue picks "turn"
                (claim-and-finish path), empty picks
                "scheduled_autonomous" (no claim this cycle). *)
             let any_pending =
               observation.pending_mentions <> []
               || observation.pending_board_events <> []
               || observation.pending_scope_messages <> []
             in
             let channel =
               if any_pending then "turn" else "scheduled_autonomous"
             in
             (* Cycle 44: KeeperTaskAcquisition.tla post-action guards
                pin the structural invariant the decision relied on.
                The [@@fsm_guard] PPX now routes assertions through
                [Keeper_fsm_guard_runtime.wrap_unit ~stage:"guard"]
                automatically, so the manual outer wrap is removed to
                avoid double-counting Prometheus violations. *)
             if any_pending
             then post_assign_task ~any_pending ~channel
             else post_empty_queue_sleep ~any_pending ~channel;
             Keeper_unified_metrics.append_metrics_snapshot ~config ~meta:updated_meta ~observation
               ~result ~latency_ms ~turn_cost
               ~turn_generation:lifecycle.turn_generation
               ~channel
               ~snapshot_source:"keeper_unified_turn"
               ~context_ratio:lifecycle.context_ratio
               ~context_tokens:lifecycle.context_tokens
               ~context_max:lifecycle.context_max
               ~message_count:lifecycle.message_count
               ~compaction:lifecycle.compaction
               ~handoff_json:lifecycle.handoff_json
               ?timeout_budget_json:
                 (Option.map oas_timeout_budget_resolution_to_yojson
                    !last_timeout_budget)
               ()
          with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               (* #10047: surface drop as a Prometheus counter so
                  dashboards can alert when state advances without a
                  matching metric record (keeper was running but jsonl
                  shows no turn). *)
               let channel =
                 if observation.pending_mentions <> []
                    || observation.pending_board_events <> []
                    || observation.pending_scope_messages <> []
                 then "turn"
                 else "scheduled_autonomous"
               in
               Prometheus.inc_counter
                 Keeper_metrics.metric_keeper_metric_emit_dropped
                 ~labels:[
                   ("keeper", updated_meta.Keeper_types.name);
                   ("channel", channel);
                   ("site", "keeper_unified_turn");
                 ] ();
               Log.Keeper.error
                 "write metrics snapshot failed after keeper cycle: %s"
                 (Printexc.to_string exn);
               Prometheus.inc_counter
                 Keeper_metrics.metric_keeper_turn_metrics_snapshot_failures
                 ~labels:[("keeper", meta.name); ("site", "post_cycle")]
                 ());
          let turn_mode = Keeper_unified_metrics.turn_mode_of_result result in
          let turn_mode_label =
            Keeper_unified_metrics.turn_mode_to_string turn_mode
          in
          let model_used = Keeper_agent_run.surface_model_used result in
          let resolved_model_id =
            Keeper_agent_run.surface_resolved_model_id result
          in
          let usage_trust =
            Keeper_unified_metrics.classify_usage_trust
              ~usage_reported:result.usage_reported
              ~usage:result.usage
              ~model_used
              ~resolved_model_id
              ~context_max:lifecycle.context_max
          in
          let usage_trusted =
            Keeper_unified_metrics.usage_trust_is_trusted usage_trust
          in
          let wall_tokens_per_second =
            if usage_trusted && latency_ms > 0 then
              Some
                (float_of_int result.usage.output_tokens
                 /. (float_of_int latency_ms /. 1000.0))
            else None
          in
          (* Emit turn-completed event to Activity Graph for timeline token visibility *)
          (try
            let event =
              Activity_graph.emit config
                ~actor:{ kind = "agent"; id = updated_meta.agent_name }
                ~kind:"keeper.turn_completed"
                ~payload:(`Assoc
                  ([
                    ("keeper_name", `String updated_meta.name);
                    ("input_tokens", (if usage_trusted then `Int result.usage.input_tokens else `Null));
                    ("output_tokens", (if usage_trusted then `Int result.usage.output_tokens else `Null));
                    ("cache_creation_tokens", (if usage_trusted then `Int result.usage.cache_creation_input_tokens else `Null));
                    ("cache_read_tokens", (if usage_trusted then `Int result.usage.cache_read_input_tokens else `Null));
                    ("cost_usd", (if usage_trusted then `Float turn_cost else `Null));
                    ("latency_ms", `Int latency_ms);
                    ("model_used", `String model_used);
                    ("resolved_model_id", `String resolved_model_id);
                    ( "usage_trust",
                      `String
                        (Keeper_unified_metrics.usage_trust_to_string
                           usage_trust) );
                    ( "usage_anomaly_reasons",
                      `List
                        (List.map
                           (fun reason -> `String reason)
                           (Keeper_unified_metrics.usage_trust_reasons
                              usage_trust)) );
                    ("turn_mode", `String turn_mode_label);
                    ("context_ratio", `Float lifecycle.context_ratio);
                    ("tools_used", `List (List.map (fun s -> `String s) result.tools_used));
                  ]
                  @ (match wall_tokens_per_second with
                     | Some v -> [("tokens_per_second", `Float v)]
                     | None -> [])
                  @ (match result.inference_telemetry with
                     | Some t ->
                       (match t.reasoning_tokens with Some n -> [("reasoning_tokens", `Int n)] | None -> [])
                       @ (match t.timings with
                          | Some ti ->
                            (match ti.prompt_per_second with
                             | Some v -> [("prompt_per_second", `Float v)]
                             | None -> [])
                            @ (match ti.predicted_per_second with
                               | Some v -> [("hw_decode_tokens_per_second", `Float v)]
                               | None -> [])
                          | None -> [])
                     | None -> [])))
                ~tags:["keeper"; "turn"; "metrics"]
                ()
            in
            Log.Keeper.debug
              "%s: activity graph turn_completed emitted seq=%d"
              updated_meta.name event.seq
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              report_keeper_cycle_side_effect_issue
                ~config
                ~keeper_name:updated_meta.name
                ~side_effect:"activity graph turn_completed emit"
                (Printexc.to_string exn));
          Keeper_unified_metrics.broadcast_lifecycle_events ~name:updated_meta.name
            ~turn_generation:lifecycle.turn_generation
            ~compaction:lifecycle.compaction
            ~handoff_json:lifecycle.handoff_json;
          Keeper_unified_metrics.append_decision_record ~config ~meta:updated_meta ~observation
            ~latency_ms ~semaphore_wait_ms ~outcome:"success"
            ~degraded_retry_applied
            ?degraded_retry_cascade
            ?fallback_reason
            ~turn_mode
            ~social_state
            ~result:(Some result) ();
          (match explicit_accountability_claim with
          | Some claim ->
              let trace_id =
                Keeper_id.Trace_id.to_string updated_meta.runtime.trace_id
              in
              let validated_evidence = Keeper_unified_metrics.visible_run_validation result in
              let strong_evidence =
                Keeper_unified_metrics.has_substantive_tool_calls result.tools_used
                || Option.is_some validated_evidence
              in
              Keeper_accountability.record_completion_claim config
                ~keeper_name:updated_meta.name
                ~agent_name:updated_meta.agent_name
                ~trace_id
                ~turn_number:updated_meta.runtime.usage.total_turns
                ~subject:claim.subject
                ?task_id:claim.task_id
                ~evidence_refs:claim.evidence_refs
                ~surface:(Social.delivery_surface_to_string social_state.delivery_surface)
                ~strong_evidence
                ~strong_evidence_refs:
                  (Keeper_unified_metrics.accountability_evidence_refs
                     ~trace_id
                     ~turn_number:updated_meta.runtime.usage.total_turns
                     ~result
                     ~validated_evidence)
                ()
          | None -> ());
          let outcome_str =
            match result.stop_reason with
            | Oas_worker.Completed -> "completed"
            | Oas_worker.TurnBudgetExhausted { turns_used; limit; _ } ->
                Printf.sprintf "budget_exhausted(%d/%d)" turns_used limit
            | Oas_worker.MutationBoundaryReached { turns_used; tool_name } ->
                (match tool_name with
                 | Some tool ->
                     Printf.sprintf "mutation_boundary(%d:%s)" turns_used tool
                 | None ->
                     Printf.sprintf "mutation_boundary(%d)" turns_used)
          in
          let outcome_label =
            match result.stop_reason with
            | Oas_worker.Completed -> "success"
            | Oas_worker.TurnBudgetExhausted _ -> "budget_exhausted"
            | Oas_worker.MutationBoundaryReached _ -> "mutation_boundary"
          in
          Prometheus.inc_counter Keeper_metrics.metric_keeper_turns
            ~labels:[("keeper_name", updated_meta.name); ("outcome", outcome_label)] ();
          if usage_trusted then begin
            Prometheus.inc_counter Keeper_metrics.metric_keeper_input_tokens
              ~labels:[("keeper_name", updated_meta.name); ("model", model_used)]
              ~delta:(float_of_int result.usage.input_tokens) ();
            Prometheus.inc_counter Keeper_metrics.metric_keeper_output_tokens
              ~labels:[("keeper_name", updated_meta.name); ("model", model_used)]
              ~delta:(float_of_int result.usage.output_tokens) ();
            (* #7469 Step 1: emit prompt-cache usage so Anthropic/Bedrock
               hit rate is observable. Skip when both are zero — non-caching
               providers (GLM/local-llama) would otherwise register a series
               per keeper+model combination that never moves off zero.
               Metric names pulled from [Prometheus] constants so a typo
               here would fail to compile instead of silently creating a
               dead series. *)
            (if result.usage.cache_creation_input_tokens > 0 then
               Prometheus.inc_counter Keeper_metrics.metric_keeper_cache_creation_tokens
                 ~labels:[("keeper_name", updated_meta.name); ("model", model_used)]
                 ~delta:(float_of_int result.usage.cache_creation_input_tokens) ());
            (if result.usage.cache_read_input_tokens > 0 then
               Prometheus.inc_counter Keeper_metrics.metric_keeper_cache_read_tokens
                 ~labels:[("keeper_name", updated_meta.name); ("model", model_used)]
                 ~delta:(float_of_int result.usage.cache_read_input_tokens) ())
          end else begin
            let reasons =
              match Keeper_unified_metrics.usage_trust_reasons usage_trust with
              | [] -> [Keeper_unified_metrics.usage_trust_to_string usage_trust]
              | reasons -> reasons
            in
            List.iter
              (fun reason ->
                 Prometheus.inc_counter
                   Keeper_metrics.metric_keeper_usage_anomalies
                   ~labels:
                     [
                       ("keeper_name", updated_meta.name);
                       ("model", model_used);
                       ("reason", reason);
                     ]
                   ())
              reasons;
            Log.Keeper.warn
              "%s: keeper usage telemetry untrusted model=%s resolved_model=%s reasons=%s input=%d output=%d context_max=%d"
              updated_meta.name model_used resolved_model_id
              (String.concat "," reasons)
              result.usage.input_tokens
              result.usage.output_tokens
              lifecycle.context_max
          end;
          let logged_total_tokens =
            if usage_trusted then
              result.usage.input_tokens + result.usage.output_tokens
            else 0
          in
          Log.Keeper.info
            "%s: keeper cycle OK model=%s tokens=%d latency=%dms mode=%s stop=%s"
            updated_meta.name model_used logged_total_tokens
            latency_ms
            turn_mode_label
            outcome_str;
          (* 7. Persist updated meta — RMW retry to avoid losing the cycle's
             usage/trace data when a heartbeat fiber bumps meta_version
             between the cycle's read and its write. #9764 / #9769:
             field-level merge preserves heartbeat-owned fields from
             disk so the retry does not clobber concurrent heartbeat
             writes (previous "caller wins" retry was losing the race).
             Self-healing circuit breaker: clear [auto_resume_after_sec]
             so a successful turn resets the exponential back-off to the
             initial delay for the next auto-pause cycle. *)
          let updated_meta =
            if updated_meta.auto_resume_after_sec <> None
            then { updated_meta with auto_resume_after_sec = None }
            else updated_meta
          in
          (match
             write_meta_with_merge
               ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
               config updated_meta
           with
           | Ok () -> ()
           | Error msg ->
               Prometheus.inc_counter
                 Keeper_metrics.metric_keeper_write_meta_failures
                 ~labels:
                   [ ("keeper", updated_meta.name);
                     ("phase",
                      if is_version_conflict_error msg
                      then "keeper_cycle_cas_race"
                      else "keeper_cycle")
                   ]
                 ();
               if is_version_conflict_error msg then
                 Log.Keeper.warn
                   "write_meta lost CAS race after retries (keeper cycle): %s" msg
               else
                 Log.Keeper.error
                   "write_meta failed after keeper cycle: %s" msg);
                   Prometheus.inc_counter
                     Keeper_metrics.metric_keeper_write_meta_cycle_failures
                     ~labels:[("keeper", meta.name); ("site", "keeper_cycle")]
                     ();
          (* 8. Handle stop reason *)
          Keeper_turn_fsm.emit_transition
            ~keeper_name:meta.name ~turn_id:keeper_turn_id
            ~prev:Keeper_turn_fsm.Streaming
            Keeper_turn_fsm.Completing;
          (match result.stop_reason with
           | Oas_worker.TurnBudgetExhausted { turns_used; limit } ->
             (* INFO, not WARN: mirrors MutationBoundaryReached below.
                The keeper made progress and saved a checkpoint; this is
                a normal pause-and-resume signal, not a failure. *)
             Log.Keeper.info
               "keeper:%s turn budget exhausted (%d/%d), checkpoint saved — will resume next cycle"
               updated_meta.name turns_used limit;
             (* Do NOT increment turn_failures — this is not a crash.
                The keeper made progress and saved a checkpoint.
                Reset failures since the turn itself ran successfully. *)
             Keeper_registry.reset_turn_failures ~base_path:config.base_path
               updated_meta.name
           | Oas_worker.MutationBoundaryReached { tool_name; _ } ->
             Log.Keeper.info
               "keeper:%s mutation boundary reached after %s, checkpoint saved — will resume next cycle"
               updated_meta.name
               (match tool_name with Some tool -> tool | None -> "committed tool");
             Keeper_registry.reset_turn_failures ~base_path:config.base_path
               updated_meta.name
           | Oas_worker.Completed ->
             Keeper_registry.reset_turn_failures ~base_path:config.base_path
               updated_meta.name);
          Keeper_turn_fsm.emit_transition
            ~keeper_name:meta.name ~turn_id:keeper_turn_id
            ~prev:Keeper_turn_fsm.Completing
            Keeper_turn_fsm.Done;
          (* Cycle 45: KeeperTaskAcquisition.tla TurnComplete post-action
             — the cycle ran to completion and is about to return an
             [Ok] result.  Manual [wrap_unit] removed: the PPX-injected
             [wrap_unit ~stage:"guard"] already routes [Assert_failure]
             to the Prometheus counter. *)
          cycle_completed := true;
          post_turn_complete_task ~cycle_completed;
          Ok updated_meta))

let run_unified_turn = run_keeper_cycle
