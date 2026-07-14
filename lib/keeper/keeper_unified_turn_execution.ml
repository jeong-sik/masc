(** Keeper_unified_turn_execution — Execution body for unified keeper cycles.

    Extracted from [Keeper_unified_turn.run_keeper_cycle]. Contains the
    [do_run] closure, runtime rotation loop, and cleanup/finalization logic.

    @since God file decomposition *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime
open Result.Syntax
include Keeper_turn_helpers
include Keeper_turn_runtime_budget
include Keeper_unified_turn_types

type retry_loop_input =
  { run_meta : keeper_meta
  ; execution : runtime_execution
  ; run_generation : int
  ; attempt : int
  ; is_retry : bool
  ; attempted_runtimes : string list
  }

let autonomous_yield_request ~base_path ~keeper_name ~channel =
  if
    Keeper_turn_admission.chat_waiting ~base_path ~keeper_name
    || (match Keeper_chat_queue.pending_count ~keeper_name with
        | Ok count -> count > 0
        | Error _ -> true)
  then
    let boundary =
      match channel with
      | Keeper_world_observation.Scheduled_autonomous ->
        Keeper_agent_run.Yield_immediately
      | Keeper_world_observation.Reactive ->
        Keeper_agent_run.Yield_after_current_turn
    in
    Some Keeper_agent_run.{ reason = Chat_waiting; boundary }
  else
    let pending = Keeper_registry_event_queue.snapshot ~base_path keeper_name in
    if Keeper_event_queue.is_empty pending
    then None
    else
      Some
        Keeper_agent_run.
          { reason = Durable_stimulus_waiting
          ; boundary = Yield_after_current_turn
          }
;;

(** [run] operates on the immutable [Keeper_unified_turn_types.turn_state]
    accumulator instead of casual [ref] cells. *)

type ctx =
  { attempt : int
  ; base_dir : string
  ; build_turn_prompt :
      base_system_prompt:string -> messages:Agent_sdk.Types.message list ->
      Keeper_agent_run.turn_prompt
  ; channel : Keeper_world_observation.keeper_cycle_channel
  ; continuation_delivery_channel : Keeper_continuation_channel.t option
      (* Exact originating channel for a continuation-bearing wake. Non-board
         intake admits one stimulus per turn, so this never chooses between
         unrelated conversations. [None] fails closed to no external delivery. *)
  ; hitl_resolution : Keeper_event_queue.hitl_resolution option
      (* Typed decision for the originating Keeper's exact external-effect
         Gate. It is never converted to a generic OAS approval. *)
  ; cleanup : unit -> unit
  ; config : Workspace.config
  ; drain_turn_event_bus : ?site:string -> unit -> Keeper_turn_runtime_budget.turn_event_bus_summary
  ; event_bus : Agent_sdk.Event_bus.t option
  ; event_bus_integrity_error_snapshot : unit -> Agent_sdk.Error.sdk_error option
  ; tool_completed_count_snapshot : unit -> int
  ; generation : int
  ; keeper_turn_id : int
  ; meta : keeper_meta
  ; turn_ctx_cell : Keeper_tool_call_log.turn_ctx_cell
  ; observation : Keeper_world_observation.world_observation
  ; profile_defaults : Keeper_types_profile.keeper_profile_defaults
  ; shared_context : Agent_sdk.Context.t option
  ; trajectory_acc : Trajectory.accumulator
  ; turn_id : int
  }

let run (ctx : ctx)
      ~(initial_execution : runtime_execution)
      ~(turn_state : turn_state)
      ~(current_turn_phase_elapsed_ms : float option -> int * int option)
      ~(user_message : string)
      ~(registry_base_path : string)
      ~(record_streaming_cancelled_observation : config:Workspace.config -> run_meta:keeper_meta -> run_generation:int -> runtime_id:string -> keeper_turn_id:int -> unit -> unit)
      ~(runtime_id_of_meta : keeper_meta -> string)
      ~(start_background_turn_event_bus_drain : clock:float Eio.Time.clock_ty Eio.Resource.t -> unit)
  : (Keeper_agent_run.run_result, Agent_sdk.Error.sdk_error) result * turn_state
=
  let { config
      ; meta
      ; turn_ctx_cell
      ; observation
      ; generation
      ; keeper_turn_id
      ; turn_id
      ; channel
      ; continuation_delivery_channel
      ; hitl_resolution
      ; shared_context
      ; base_dir
      ; build_turn_prompt
      ; trajectory_acc
      ; profile_defaults
      ; cleanup
      ; drain_turn_event_bus
      ; event_bus
      ; event_bus_integrity_error_snapshot = _
      ; tool_completed_count_snapshot = _
      ; attempt = _attempt
      } =
    ctx
  in
  (match Eio_context.get_clock () with
   | Error msg -> Error (Agent_sdk.Error.Internal msg), turn_state
   | Ok clock ->
   (* Same-run retry authority comes from OAS's typed checkpoint boundary.
      OAS invokes the sink only after mutating the agent state at a declared
      checkpoint stage, and MASC marks the stage before delegating persistence.
      Therefore a sink failure also closes replay authority: the attempt may
      already contain effects even when the durable write failed. A lossy
      Event_bus observation must never reopen or close this boundary.

      [test_keeper_turn_driver_failover] proves both directions: transport
      failure before any stage may fall back, while every typed stage blocks a
      same-run fallback. *)
   let checkpoint_stage_observed = Atomic.make false in
  let do_run
        ~(execution : runtime_execution)
        ~run_meta
        ~run_generation
        ~is_retry
        ~(turn_state : turn_state)
    =
    let turn_state =
      { turn_state with last_execution = Some execution }
    in
    let result =
      Otel_genai.with_keeper_turn_span
        ~keeper_name:run_meta.name
        ~agent_name:run_meta.agent_name
        ~runtime_id:execution.runtime_id
        ~trace_id:
          (Keeper_id.Trace_id.to_string run_meta.runtime.trace_id)
        ~generation:run_generation
        ~max_context:execution.max_context
        ~channel:(Keeper_world_observation.channel_to_string channel)
        ~is_retry
        ~current_task_id:
          (Option.map
             Keeper_id.Task_id.to_string
             run_meta.current_task_id)
        (fun trace_link ->
           Keeper_registry.mark_turn_provider_attempt_started
             ~base_path:config.base_path
             meta.name;
           try
               (* Emit before the provider/tool run so operator forensics can see
                  that the keeper entered Streaming. The surrounding [try]
                  records external cancellation without imposing a wall-clock
                  timeout around active tool execution. *)
               Keeper_turn_fsm.emit_transition
                 ~keeper_name:meta.name
                 ~turn_id:keeper_turn_id
                 ~prev:Keeper_turn_fsm.Awaiting_provider
                 Keeper_turn_fsm.Streaming;
               Keeper_agent_run.run_turn
                 ~config
                 ~meta:run_meta
                 ~profile_defaults
                 ?continuation_delivery_channel
                 ?hitl_resolution
                 ~turn_ctx_cell
                 ~base_dir
                 ~max_context:execution.max_context
                 ~build_turn_prompt
                 ~user_message
                 ~runtime_id:execution.runtime_id
                 ~world_observation:observation
                 ~generation:run_generation
                 ~history_user_source:"world_state_prompt"
                 ~history_assistant_source:"internal_assistant"
                 ~degraded_retry_applied:
                   (Option.is_some turn_state.degraded_retry_info)
                 ?degraded_retry_runtime:
                   (Option.map
                      (fun (retry : EC.degraded_retry) ->
                         retry.next_runtime)
                      turn_state.degraded_retry_info)
                 ?fallback_reason:
                   (Option.map
                      (fun (retry : EC.degraded_retry) ->
                         retry.fallback_reason)
                      turn_state.degraded_retry_info)
                 ~runtime_rotation_attempts:
                   (List.rev turn_state.runtime_rotation_attempts)
                 ~temperature:execution.temperature
                 ~trajectory_acc
                 ~is_retry
                 ?shared_context
                 ?event_bus
                 ?trace_link:(trace_link ())
                 ~on_checkpoint_stage:
                   (Keeper_turn_driver_try_provider.observe_checkpoint_stage
                      checkpoint_stage_observed)
                   (* This module is the autonomous lane's turn runner
                      ([Keeper_unified_turn.run_keeper_cycle] → here, only ever
                      reached via [Keeper_turn_admission.run_if_free]); the chat
                      lane runs [run_keeper_msg_turn_admitted] on a separate
                      path. So passing the yield hook here is inherently
                      lane-gated. Scheduled-idle chat can take the slot
                      immediately; reactive chat and a durable event waiting
                      behind the event leased by this cycle cause a checkpointed
                      yield after at least one provider turn. A chat turn receives
                      neither preemption hook. Both signals are read from the
                      exact queues their consumers drain, so no cadence, timeout, or
                      inferred text state participates in the decision. *)
                 ~autonomous_yield_requested:(fun () ->
                   autonomous_yield_request
                     ~base_path:config.base_path
                     ~keeper_name:meta.name
                     ~channel)
                 ()
           with
           | Eio.Cancel.Cancelled _ as exn ->
             record_streaming_cancelled_observation
               ~config
               ~run_meta
               ~run_generation
               ~runtime_id:execution.runtime_id
               ~keeper_turn_id
               ();
             raise exn)
    in
    result, turn_state
  in
  let record_runtime_rotation_attempt
        turn_state
        ~productive_phase_elapsed_ms
        ?retry_phase_elapsed_ms
        ~(from_runtime : string)
        ~(retry : EC.degraded_retry)
        ~(outcome : Keeper_execution_receipt.runtime_rotation_outcome)
        (err : Agent_sdk.Error.sdk_error)
    =
    let attempt : Keeper_execution_receipt.runtime_rotation_attempt =
      Keeper_unified_turn_rotation_attempt.build
        ~recorded_at:(now_iso ())
        ~productive_phase_elapsed_ms
        ?retry_phase_elapsed_ms
        ~from_runtime
        ~retry
        ~outcome
        err
    in
    { turn_state with
      runtime_rotation_attempts = attempt :: turn_state.runtime_rotation_attempts
    }
  in
  let rec retry_loop (input : retry_loop_input) (turn_state : turn_state) =
    let { run_meta
        ; execution
        ; run_generation
        ; attempt
        ; is_retry
        ; attempted_runtimes
        }
      =
      input
    in
    let execution_runtime_id =
      execution.runtime_id
    in
    let mark_terminal_error err =
      match EC.extract_input_required err with
      | Some ir ->
        Keeper_registry.mark_turn_runtime_done
          ~base_path:config.base_path
          meta.name;
        Log.Keeper.info
          "[input_required] keeper=%s agent paused: request_id=%s \
           question=%s"
          meta.name
          ir.Agent_sdk.Error.request_id
          (let q = ir.Agent_sdk.Error.question in
           if String.length q > 80
           then String.sub q 0 80 ^ "…"
           else q);
        Keeper_turn_fsm.emit_transition
          ~keeper_name:meta.name
          ~turn_id:keeper_turn_id
          ~prev:Keeper_turn_fsm.Streaming
          (Keeper_turn_fsm.Cancelled
             Keeper_turn_fsm.Cancelled_input_required)
      | None ->
        Keeper_unified_turn_terminal_error.handle
          ~config
          ~keeper_name:meta.name
          ~attempt
          ~attempted_runtimes
          err
    in
    let attempt_result, turn_state =
      do_run
        ~execution
        ~run_meta
        ~run_generation
        ~is_retry
        ~turn_state
    in
    match attempt_result with
    | Ok result ->
      let selected_model =
        match result.runtime_observation with
        | Some observation -> observation.selected_model
        | None -> None
      in
      Keeper_registry.set_turn_selected_model
        ~base_path:config.base_path
        meta.name
        selected_model;
      Keeper_registry.mark_turn_runtime_done
        ~base_path:config.base_path
        meta.name;
      Ok result, turn_state
    | Error err ->
      let checkpoint_observed =
        not
          (Keeper_turn_driver_try_provider.same_run_retry_allowed
             checkpoint_stage_observed)
      in
      let same_run_retry_has_input_authority = not checkpoint_observed in
      if not same_run_retry_has_input_authority
      then
        Log.Keeper.info
          ~keeper_name:meta.name
          "%s: same-run runtime retry deferred after durable run progress \
           (checkpoint_observed=%b); \
           current OAS contract cannot continue without admitting the input again"
          meta.name
          checkpoint_observed;
      match
          ( Keeper_turn_runtime_budget.plan_degraded_retry_step
            ~base_runtime:(runtime_id_of_meta meta)
            ~current_runtime_id:execution_runtime_id
            ~attempted_runtimes
            ~attempt
            ~err
            ~allow_retry:(fun _ -> same_run_retry_has_input_authority)
            ~publish_cascade_resolution:
              (fun ~runtime_id ~decision ~reason ~next_runtime ~attempt err ->
                 Keeper_unified_turn_cascade_resolution.publish_cascade_resolution
                   ~keeper_name:meta.name
                   ~runtime_id
                   ~decision
                   ~reason
                   ~next_runtime
                   ~attempt
                   ~error_kind:(Some (Keeper_agent_error.sdk_error_kind err))
                   ~error_message:(Some (Agent_sdk.Error.to_string err)))
            ~emit_runtime_selected:
              (fun ~runtime_id ~fallback_reason ->
                 Keeper_metrics.emit_runtime_selected
                   ~keeper_name:meta.name
                   ~runtime_id
                   ~fallback_reason)
            ~emit_runtime_rotation:
              (fun ~from_runtime ~to_runtime ~reason ->
                 Keeper_metrics.emit_runtime_rotation
                   ~keeper_name:meta.name
                   ~from_runtime
                   ~to_runtime
                   ~reason)
            ~setup_runtime:
              (fun runtime_id ->
                 Keeper_unified_turn_pre_dispatch.build_runtime_execution
                   ~meta
                   ~runtime_id)
          , context_overflow_event_of_error err )
        with
        | Keeper_turn_runtime_budget.Degraded_retry_step_setup_failed
            { retry = degraded_retry; reason = fallback_reason; fail_open_err }, _ ->
             let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
               current_turn_phase_elapsed_ms turn_state.retry_phase_started_at
             in
             let turn_state =
               record_runtime_rotation_attempt
                 turn_state
                 ~productive_phase_elapsed_ms
                 ?retry_phase_elapsed_ms
                 ~from_runtime:execution.runtime_id
                 ~retry:degraded_retry
                 ~outcome:
                   Keeper_execution_receipt.Rotation_setup_failed
                 fail_open_err
             in
             Log.Keeper.warn
               "%s: recoverable runtime failure in %s suggested \
                degraded retry to %s (reason=%s), but retry setup \
                failed: %s"
               meta.name
               execution_runtime_id
               degraded_retry.next_runtime
               fallback_reason
               (short_preview
                  (Agent_sdk.Error.to_string fail_open_err));
             mark_terminal_error fail_open_err;
             Error fail_open_err, turn_state
        | Keeper_turn_runtime_budget.Degraded_retry_step_prepared
            { retry = degraded_retry; reason = fallback_reason; next = next_execution }, _ ->
             let next_execution_runtime_id =
               next_execution.runtime_id
             in
             let turn_state =
               if Option.is_none turn_state.retry_phase_started_at
               then { turn_state with retry_phase_started_at = Some (Eio.Time.now clock) }
               else turn_state
             in
             let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
               current_turn_phase_elapsed_ms turn_state.retry_phase_started_at
             in
             let turn_state =
               record_runtime_rotation_attempt
                 turn_state
                 ~productive_phase_elapsed_ms
                 ?retry_phase_elapsed_ms
                 ~from_runtime:execution.runtime_id
                 ~retry:degraded_retry
                 ~outcome:
                   Keeper_execution_receipt.Rotation_retry_scheduled
                 err
             in
             let turn_state =
               { turn_state with degraded_retry_info = Some degraded_retry }
             in
             Log.Keeper.warn
               "%s: recoverable runtime failure in %s; rotation \
               retry on runtime=%s reason=%s max_context=%d \
                context_budget=%d primary_budget=%d \
                requested_override=%s: %s"
               meta.name
               execution_runtime_id
               next_execution_runtime_id
               fallback_reason
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
             retry_loop
               { run_meta
               ; execution = next_execution
               ; run_generation
               ; attempt = 1
               ; is_retry = true
               ; attempted_runtimes =
                   next_execution_runtime_id :: attempted_runtimes
               }
               turn_state
        | Keeper_turn_runtime_budget.Degraded_retry_step_not_allowed, Some overflow_event ->
          Keeper_unified_turn_cascade_resolution.publish_cascade_resolution
            ~keeper_name:meta.name
            ~runtime_id:execution.runtime_id
            ~decision:No_degraded_retry
            ~reason:"context_overflow_after_oas_retry"
            ~next_runtime:None
            ~attempt
            ~error_kind:(Some (Keeper_agent_error.sdk_error_kind err))
            ~error_message:(Some (Agent_sdk.Error.to_string err));
          let current_turn_event_bus =
            drain_turn_event_bus ~site:"context_overflow_capture" ()
          in
          let overflow_evidence_detail =
            turn_event_bus_overflow_evidence_detail current_turn_event_bus
          in
          let turn_state =
            { turn_state with
              current_turn_blocker_info =
                Some
                  (Keeper_meta_contract.blocker_info_of_class
                     ~detail:
                       (Keeper_state_machine.event_to_string overflow_event
                        ^ ": "
                        ^ overflow_evidence_detail
                        ^ ": "
                        ^ Agent_sdk.Error.to_string err)
                     Sdk_context_window_exceeded)
            }
          in
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string OasExecutionErrors)
            ~labels:
              [ "keeper", meta.name
              ; "phase",
                Keeper_oas_execution_error_phase.(
                  to_label Context_overflow_after_oas_retry)
              ]
            ();
          Log.Keeper.warn
            "%s: provider returned typed context overflow after runtime \
             rotation; recording explicit lane recovery evidence: %s"
            meta.name
            (short_preview (Agent_sdk.Error.to_string err));
          (* This attempt returns its typed provider error. The Keeper lifecycle
             remains active; MASC lane compaction owns subsequent recovery. *)
          record_overflow_failure
            ~config
            ~meta
            ~reason:"context_overflow_after_oas_retry";
          mark_terminal_error err;
          Error err, turn_state
        | Keeper_turn_runtime_budget.Degraded_retry_step_not_allowed, None ->
          Keeper_unified_turn_cascade_resolution.publish_cascade_resolution
            ~keeper_name:meta.name
            ~runtime_id:execution.runtime_id
            ~decision:No_degraded_retry
            ~reason:"terminal_error_no_degraded_retry"
            ~next_runtime:None
            ~attempt
            ~error_kind:(Some (Keeper_agent_error.sdk_error_kind err))
            ~error_message:(Some (Agent_sdk.Error.to_string err));
          mark_terminal_error err;
          Error err, turn_state
  in
  (* Do not wrap the full keeper turn in a cumulative wall-clock timeout.
     Long voice/OAS turns can keep making stream or tool progress beyond the
     legacy 600s cap. Runaway detection is owned by stream idle, provider
     attempt liveness, tool-level timeouts, max-turn limits, and the optional
     supervisor stale-turn watchdog. Retry admission must not reintroduce the
     cumulative wall-clock cap between provider attempts. *)
  let result, turn_state =
    retry_loop
      { run_meta = meta
      ; execution = initial_execution
      ; run_generation = generation
      ; attempt = 1
      ; is_retry = false
      ; attempted_runtimes =
          [ initial_execution.runtime_id
          ]
      }
      turn_state
  in
  result, turn_state
)
