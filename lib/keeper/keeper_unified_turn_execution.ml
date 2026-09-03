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
  ; attempt : int
  ; is_retry : bool
  ; attempted_runtimes : string list
  }

type declared_lane_failure =
  | Provider_context_overflow of { limit_tokens : int option }
  | Declared_runtime_lane_exhausted

(* Only the context-window axis classifies as [Provider_context_overflow]:
   the blocker below publishes the [Agent_core_context_window_exceeded] class,
   which would be wrong for a declared-byte refusal. *)
let declared_lane_failure_of_error err =
  match capacity_refusal_of_error err with
  | Some (Provider_context_window { limit_tokens }) ->
    Provider_context_overflow { limit_tokens }
  | Some (Serialized_request_body _)
  | Some (Provider_request_body_refusal _)
  | None -> Declared_runtime_lane_exhausted

(* [context_overflow_detected(limit=N)] is a durable string in operator blocker
   history, not a rendering of any current type. Rows written years apart are
   read with the same grep, so the shape is fixed here and changing it splits
   that history. *)
let context_overflow_blocker_label ~limit_tokens =
  Printf.sprintf
    "context_overflow_detected(limit=%s)"
    (match limit_tokens with
     | Some n -> string_of_int n
     | None -> "?")

let run_provider_dispatch_if_authorized ~before_dispatch_authority dispatch =
  match before_dispatch_authority () with
  | Error reason ->
    Error
      (Agent_core.Error.Internal
         ("keeper provider dispatch authority rejected: " ^ reason))
  | Ok () -> dispatch ()
;;

(** [run] operates on the immutable [Keeper_unified_turn_types.turn_state]
    accumulator instead of casual [ref] cells. *)

type ctx =
  { attempt : int
  ; base_dir : string
  ; build_turn_prompt :
      base_system_prompt:string -> messages:Agent_core.Types.message list ->
      Keeper_agent_run.turn_prompt
  ; channel : Keeper_world_observation.keeper_cycle_channel
  ; continuation_channel : Keeper_continuation_channel.t option
      (* Reply route for a continuation-bearing wake, handed to tool setup so
         surface posts know the admitted external destination. *)
  ; hitl_resolution : Keeper_event_queue.hitl_resolution option
      (* Typed decision for the originating Keeper's exact external-effect
         Gate. It is never converted to a generic AGENT_CORE approval. *)
  ; cleanup : unit -> unit
  ; config : Workspace.config
  ; drain_turn_event_bus : ?site:string -> unit -> Keeper_turn_runtime_budget.turn_event_bus_summary
  ; event_bus : Agent_core.Event_bus.t option
  ; event_bus_integrity_error_snapshot : unit -> Agent_core.Error.t option
  ; tool_completed_count_snapshot : unit -> int
  ; keeper_turn_id : int
  ; meta : keeper_meta
  ; turn_ctx_cell : Keeper_tool_call_log.turn_ctx_cell
  ; observation : Keeper_world_observation.world_observation
  ; profile_defaults : Keeper_types_profile.keeper_profile_defaults
  ; publication_recovery :
      Keeper_publication_recovery_availability.turn_context
  ; skill_snapshot : Skill_catalog_snapshot.t
  ; task_skill_selection :
      (Keeper_task_skill_turn.t, Keeper_task_skill_turn.error) result
  ; shared_context : Agent_core.Context.t option
  ; trajectory_acc : Trajectory.accumulator
  ; turn_id : int
  ; deferred_runtime_lane : Keeper_turn_driver.deferred_runtime_lane option
  ; on_deferred_runtime_consumed : (unit -> unit) option
  }

let run (ctx : ctx)
      ~(autonomous_yield_requested :
          unit -> (Keeper_agent_run.autonomous_yield_request option, string) result)
      ~(initial_execution : runtime_execution)
      ~(turn_state : turn_state)
      ~(before_dispatch_authority : unit -> (unit, string) result)
      ~(current_turn_phase_elapsed_ms : float option -> int * int option)
      ~(user_message : string)
      ~(registry_base_path : string)
      ~(record_streaming_cancelled_observation : config:Workspace.config -> run_meta:keeper_meta -> runtime_id:string -> keeper_turn_id:int -> unit -> unit)
      ~(runtime_id_of_meta : keeper_meta -> string)
      ~(start_background_turn_event_bus_drain : clock:float Eio.Time.clock_ty Eio.Resource.t -> unit)
  : (Keeper_agent_run.run_result, Agent_core.Error.t) result * turn_state
=
  let { config
      ; meta
      ; turn_ctx_cell
      ; observation
      ; keeper_turn_id
      ; turn_id
      ; channel
      ; continuation_channel
      ; hitl_resolution
      ; shared_context
      ; base_dir
      ; build_turn_prompt
      ; trajectory_acc
      ; profile_defaults
      ; publication_recovery
      ; skill_snapshot
      ; task_skill_selection
      ; cleanup
      ; drain_turn_event_bus
      ; event_bus
      ; event_bus_integrity_error_snapshot = _
      ; tool_completed_count_snapshot = _
      ; attempt = _attempt
      ; deferred_runtime_lane
      ; on_deferred_runtime_consumed
      } =
    ctx
  in
  (match Eio_context.get_clock () with
   | Error msg -> Error (Agent_core.Error.Internal msg), turn_state
   | Ok clock ->
   (* Same-run retry authority comes from AGENT_CORE's typed checkpoint boundary.
      AGENT_CORE invokes the sink only after mutating the agent state at a declared
      checkpoint stage, and MASC marks the stage before delegating persistence.
      Therefore a sink failure also closes replay authority: the attempt may
      already contain effects even when the durable write failed. A lossy
      Event_bus observation must never reopen or close this boundary.

      [test_keeper_turn_driver_failover] proves both directions: transport
      failure before any stage may fall back, while every typed stage blocks a
      same-run fallback. *)
   let checkpoint_stage_observed = Atomic.make false in
   let deferred_runtime_lane_ref = ref None in
  let do_run
        ~(execution : runtime_execution)
        ~run_meta
        ~is_retry
        ~(turn_state : turn_state)
    =
    let turn_state =
      { turn_state with last_execution = Some execution }
    in
    let result =
      Otel_genai.with_keeper_turn_span
        ~keeper_name:run_meta.name
        ~agent_name:run_meta.name
        ~runtime_id:execution.runtime_id
        ~trace_id:
          (Keeper_id.Trace_id.to_string run_meta.runtime.trace_id)
        ~max_context:execution.max_context
        ~channel:(Keeper_world_observation.channel_to_string channel)
        ~is_retry
        ~current_task_id:
          (Option.map
             Keeper_id.Task_id.to_string
             run_meta.current_task_id)
        (fun trace_link ->
           run_provider_dispatch_if_authorized
             ~before_dispatch_authority
             (fun () ->
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
                 ~publication_recovery
                 ~profile_defaults
                 ?continuation_channel
                 ?hitl_resolution
                 ~turn_ctx_cell
                 ~base_dir
                 ~max_context:execution.max_context
                 ~build_turn_prompt
                 ~user_message
                 ~turn_kind:Turn_record.Autonomous
                 ~skill_snapshot
                 ~task_skill_selection
                 ~runtime_id:execution.runtime_id
                 ~world_observation:observation
                 ~history_user_source:"world_state_prompt"
                 (* This is an ordinary durable conversation turn. The current
                    observation remains ephemeral dynamic context, while the
                    tiny [Continue.] cue and assistant response preserve normal
                    multi-turn ordering without a separate turn identity. *)
                 ~user_turn_record:Keeper_run_prompt.Record_user_turn
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
                 ?deferred_runtime_lane:
                   (if is_retry then None else deferred_runtime_lane)
                 ~on_runtime_retry_deferred:
                   (fun hint -> deferred_runtime_lane_ref := Some hint)
                 ?on_deferred_runtime_consumed:
                   (if is_retry then None else on_deferred_runtime_consumed)
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
                      reached via the Keeper Owner child); the chat
                      lane runs [run_keeper_msg_turn_admitted] on a separate
                      path. Thus the probe is lane-gated and runs only at AGENT_CORE's
                      post-tool boundary. Its signals come from the exact chat
                      receipt and durable-event queues their consumers drain. *)
                 ~autonomous_yield_requested
                 ()
            with
            | Eio.Cancel.Cancelled _ as exn ->
              record_streaming_cancelled_observation
                ~config
                ~run_meta
                ~runtime_id:execution.runtime_id
                ~keeper_turn_id
                ();
              raise exn))
    in
    result, turn_state
  in
  let retry_loop (input : retry_loop_input) (turn_state : turn_state) =
    let { run_meta
        ; execution
        ; attempt
        ; is_retry
        ; attempted_runtimes
        }
      =
      input
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
          ir.Agent_core.Error.request_id
          (let q = ir.Agent_core.Error.question in
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
      let turn_state =
        match !deferred_runtime_lane_ref with
        | Some hint ->
          { turn_state with deferred_runtime_lane = Some hint }
        | None -> turn_state
      in
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
           current AGENT_CORE contract cannot continue without admitting the input again"
          meta.name
          checkpoint_observed;
      match !deferred_runtime_lane_ref with
      | Some hint ->
        let reason =
          (match
             Keeper_error_classify.recoverable_runtime_failure_reason
               hint.failure
           with
           | Some reason -> reason
           | None -> Keeper_error_classify.Deferred_runtime_lane)
          |> Keeper_error_classify.degraded_retry_reason_to_string
        in
        Log.Keeper.info
          ~keeper_name:meta.name
          "%s: deferred frozen runtime lane suffix after checkpoint \
           failed_runtime=%s next_runtime=%s remaining=%d reason=%s"
          meta.name
          hint.failed_runtime_id
          hint.next_runtime_id
          (List.length hint.later_runtime_ids)
          reason;
        mark_terminal_error err;
        Error err, turn_state
      | None when Option.is_some deferred_runtime_lane ->
        Keeper_unified_turn_cascade_resolution.publish_cascade_resolution
          ~keeper_name:meta.name
          ~runtime_id:execution.runtime_id
          ~decision:No_degraded_retry
          ~reason:"frozen_runtime_suffix_exhausted"
          ~next_runtime:None
          ~attempt
          ~error_kind:(Some Agent_core.Error.(category err |> category_label))
          ~error_message:(Some (Agent_core.Error.to_string err));
        mark_terminal_error err;
        Error err, turn_state
      | None ->
        (match declared_lane_failure_of_error err with
         | Provider_context_overflow { limit_tokens } ->
          Keeper_unified_turn_cascade_resolution.publish_cascade_resolution
            ~keeper_name:meta.name
            ~runtime_id:execution.runtime_id
            ~decision:No_degraded_retry
            ~reason:"provider_context_overflow"
            ~next_runtime:None
            ~attempt
            ~error_kind:(Some Agent_core.Error.(category err |> category_label))
            ~error_message:(Some (Agent_core.Error.to_string err));
          let current_turn_event_bus =
            drain_turn_event_bus ~site:"context_overflow_capture" ()
          in
          let overflow_evidence_detail =
            turn_event_bus_evidence_detail current_turn_event_bus
          in
          let turn_state =
            { turn_state with
              current_turn_blocker_info =
                Some
                  (Keeper_meta_contract.blocker_info_of_class
                     ~detail:
                       (context_overflow_blocker_label ~limit_tokens
                        ^ ": "
                        ^ overflow_evidence_detail
                        ^ ": "
                        ^ Agent_core.Error.to_string err)
                     Agent_core_context_window_exceeded)
            }
          in
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string Agent_coreExecutionErrors)
            ~labels:
              [ "keeper", meta.name
              ; "phase",
                Keeper_agent_core_execution_error_phase.(
                  to_label Provider_context_overflow)
              ]
            ();
          Log.Keeper.warn
            "%s: provider returned typed context overflow after runtime \
             rotation: %s"
            meta.name
            (short_preview (Agent_core.Error.to_string err));
          (* Return the typed provider error and mark this attempt terminal.
             Whole-request provider fit remains tracked in #26551. *)
          mark_terminal_error err;
          Error err, turn_state
         | Declared_runtime_lane_exhausted ->
          Keeper_unified_turn_cascade_resolution.publish_cascade_resolution
            ~keeper_name:meta.name
            ~runtime_id:execution.runtime_id
            ~decision:No_degraded_retry
            ~reason:"declared_runtime_lane_exhausted"
            ~next_runtime:None
            ~attempt
            ~error_kind:(Some Agent_core.Error.(category err |> category_label))
            ~error_message:(Some (Agent_core.Error.to_string err));
          mark_terminal_error err;
          Error err, turn_state)
  in
  (* Do not wrap the full keeper turn in a cumulative wall-clock timeout.
     Long voice/AGENT_CORE turns can keep making stream or tool progress beyond the
     legacy 600s cap. Runaway detection is owned by stream idle, provider
     attempt liveness, tool-level timeouts, max-turn limits, and the optional
     supervisor stale-turn watchdog. Retry admission must not reintroduce the
     cumulative wall-clock cap between provider attempts. *)
  let result, turn_state =
    retry_loop
      { run_meta = meta
      ; execution = initial_execution
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

module For_testing = struct
  type nonrec declared_lane_failure = declared_lane_failure =
    | Provider_context_overflow of { limit_tokens : int option }
    | Declared_runtime_lane_exhausted

  let declared_lane_failure_of_error = declared_lane_failure_of_error
end
