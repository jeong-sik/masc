(** Keeper_unified_turn_execution — Execution body for unified keeper cycles.

    Extracted from [Keeper_unified_turn.run_keeper_cycle]. Contains the
    [do_run] closure, the runtime attempt, and cleanup/finalization logic.

    @since God file decomposition *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime
open Result.Syntax
include Keeper_turn_helpers
include Keeper_turn_runtime_budget
include Keeper_unified_turn_types

type declared_lane_failure =
  | Provider_context_overflow
  | Declared_runtime_lane_exhausted

(* How this lane continues after a failed turn. It restarts its cycle: the next
   cycle is a new turn, and a hint that named the path this one failed on would
   become [turn_state.deferred_runtime_lane] below and start the next cycle on
   that path again (RFC last-path-resumes-after-progress §3.5). Read by a test,
   because the only caller of [run] is production.  *)
let lane_retry_continuation = Keeper_turn_driver.Restart_cycle

(* The paused agent's question is logged cut to this many bytes. *)
let input_required_question_log_max_bytes = 80

(* Only a typed provider context-window refusal is [Provider_context_overflow]:
   that branch below publishes the cascade reason and the execution-error
   phase [provider_context_overflow], which would be wrong for the provider's
   refusal of the request body. A serving-constraint boundary or an
   unmeasurable token count is not a context window either. A limit the
   provider reported stays in [err] and reaches the cascade resolution's
   error message through [Agent_core.Error.to_string]. *)
let declared_lane_failure_of_error (err : Agent_core.Error.t) =
  match err with
  | Agent_core.Error.Api (ContextOverflow _) -> Provider_context_overflow
  | Agent_core.Error.Api
      (InvalidRequest
         { reason =
             ( Request_body_refused_by_provider _
             | Json_parse_error
             | Attempt_rejected
             | Refusal_body_not_received
             | Unknown_invalid_request )
         ; _
         })
  | Agent_core.Error.Api (InputCapacity _)
  | Agent_core.Error.Api
      ( RateLimited _ | Overloaded _ | ServerError _ | AuthError _
      | AuthorizationError _ | PaymentRequired _ | NotFound _ | NetworkError _
      | Timeout _ )
  | Agent_core.Error.Provider _
  | Agent_core.Error.Agent _
  | Agent_core.Error.Config _
  | Agent_core.Error.Mcp _
  | Agent_core.Error.Serialization _
  | Agent_core.Error.Io _
  | Agent_core.Error.Orchestration _ | Agent_core.Error.Media _
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } ->
    Declared_runtime_lane_exhausted

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
  { base_dir : string
  ; build_turn_prompt :
      base_system_prompt:string -> messages:Agent_core.Types.message list ->
      Keeper_agent_run.turn_prompt
  ; channel : Keeper_world_observation.keeper_cycle_channel
  ; continuation_channel : Keeper_continuation_channel.t option
      (* Reply route for a continuation-bearing wake, handed to tool setup so
         surface posts know the admitted external destination. *)
  ; approval_admission : Keeper_approval_origin.admission
  ; hitl_resolutions : Keeper_hitl_resolution_batch.t option
      (* Typed decision for the originating Keeper's exact external-effect
         Gate. It is never converted to a generic AGENT_CORE approval. *)
  ; config : Workspace.config
  ; drain_turn_event_bus : ?site:string -> unit -> Keeper_turn_runtime_budget.turn_event_bus_summary
  ; event_bus : Agent_core.Event_bus.t option
  ; keeper_turn_id : int
  ; meta : keeper_meta
  ; preview : Keeper_turn_preview.writer
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
  ; deferred_runtime_lane : Keeper_turn_driver.deferred_runtime_lane option
  ; on_deferred_runtime_consumed : (unit -> unit) option
  }

let run (ctx : ctx)
      ~event_scope
      ~observation_token
      ~(initial_execution : runtime_execution)
      ~(turn_state : turn_state)
      ~(before_dispatch_authority : unit -> (unit, string) result)
      ~(user_message : string)
      ~(record_streaming_cancelled_observation : config:Workspace.config -> run_meta:keeper_meta -> runtime_id:string -> keeper_turn_id:int -> unit -> unit)
  : (Keeper_agent_run.run_result, Agent_core.Error.t) result * turn_state
=
  let { config
      ; meta
      ; preview
      ; turn_ctx_cell
      ; observation
      ; keeper_turn_id
      ; channel
      ; continuation_channel
      ; approval_admission
      ; hitl_resolutions
      ; shared_context
      ; base_dir
      ; build_turn_prompt
      ; trajectory_acc
      ; profile_defaults
      ; publication_recovery
      ; skill_snapshot
      ; task_skill_selection
      ; drain_turn_event_bus
      ; event_bus
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
   let checkpoint_progress =
     Atomic.make Keeper_turn_driver_try_provider.No_checkpoint_stage
   in
   (* One collector for this approval continuation's common tool stream.
      The actual preparer supplies its input association; runtime attempt
      boundaries quarantine abandoned rows without changing that association.
      The turn owns the shared transcript, never a representative approval. *)
   let tool_projection =
     let approved = Option.fold ~none:false ~some:(fun batch ->
       List.exists (fun (resolution : Keeper_event_queue.hitl_resolution) ->
         match resolution.decision with
         | Keeper_event_queue.Hitl_approved -> true
         | Keeper_event_queue.Hitl_rejected _ -> false)
         (Keeper_hitl_resolution_batch.resolutions batch)) hitl_resolutions in
     if approved then Some (Keeper_loop_tool_projection.create ()) else None
   in
   let turn_ref =
     Ids.Turn_ref.make
       ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
       ~absolute_turn:keeper_turn_id
   in
   let live_stream =
     Keeper_autonomous_stream.create ~base_path:config.base_path
       ~keeper_name:meta.name ~turn_ref
   in
   let deferred_runtime_lane_ref = ref None in
   (* Every candidate to error, as the runtime walk names it, newest first,
      with whether the walk invoked it. Written on every failed attempt so
      the head is the candidate the turn ends on. Mirrors
      [deferred_runtime_lane_ref]: the walk runs below this scope and only
      the callback crosses back. *)
   let runtime_attempt_errors_ref : runtime_attempt_error list ref = ref [] in
   (* The candidate error the walk returned as the lane's error, with the
      candidate that produced it. Written once per walk that ends on a
      candidate's error. *)
   let lane_terminal_error_ref : Keeper_turn_driver.lane_terminal_error option ref =
     ref None
   in
   (* The candidate that produced the walk's result, written once when the
      walk returns one. A turn can still fail after that, in finalization. *)
   let answering_runtime_id_ref : string option ref = ref None in
  let do_run
        ~(execution : runtime_execution)
        ~run_meta
        ~(turn_state : turn_state)
    =
    let turn_state =
      { turn_state with last_execution = Some execution }
    in
    let authorized_settlement =
      Otel_genai.with_keeper_turn_span
        ~keeper_name:run_meta.name
        ~agent_name:run_meta.name
        ~runtime_id:execution.runtime_id
        ~trace_id:
          (Keeper_id.Trace_id.to_string run_meta.runtime.trace_id)
        ~max_context:execution.max_context
        ~channel:(Keeper_world_observation.channel_to_string channel)
        ~current_task_id:
          (Option.map
             Keeper_id.Task_id.to_string
             run_meta.current_task_id)
        (fun trace_link ->
           run_provider_dispatch_if_authorized
             ~before_dispatch_authority
             (fun () ->
            Ok (
            Keeper_registry.mark_turn_provider_attempt_started
              ~observation_token:(Some observation_token)
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
                 ~approval_admission
                 ~preview
                 ~event_scope
                 ~observation_token
                 ~config
                 ~meta:run_meta
                 ~publication_recovery
                 ~profile_defaults
                 ?continuation_channel
                 ?hitl_resolutions
                 ?on_gate_inputs_prepared:(Option.map
                   Keeper_loop_tool_projection.bind_prepared_inputs tool_projection)
                 ~turn_ctx_cell
                 ~base_dir
                 ~max_context:execution.max_context
                 ~build_turn_prompt
                 ~user_message
                 ~input_speaker:(Keeper_unified_prompt.autonomous_input_speaker observation)
                 ~turn_kind:Turn_record.Autonomous
                 ~skill_snapshot
                 ~task_skill_selection
                 ~runtime_id:execution.runtime_id
                 ~world_observation:observation
                 ~answered_ask_inputs:(Keeper_unified_prompt.answered_ask_inputs observation)
                 ~history_user_source:Keeper_types_support.World_state_prompt
                 (* This is an ordinary durable conversation turn. The current
                    observation remains ephemeral dynamic context, while the
                    tiny [Continue.] cue and assistant response preserve normal
                    multi-turn ordering without a separate turn identity. *)
                 ~user_turn_record:Keeper_run_prompt.Record_user_turn
                 ~history_assistant_source:Keeper_types_support.Internal_assistant
                 (* [deferred_runtime_lane] is the whole degraded-retry input.
                    This call also passed the lane's runtime and reason
                    separately, under a flag that said a retry had been
                    applied whenever a lane was merely pending — which is what
                    the receipt then printed (#37108). The receipt now reads
                    the lane from here and decides for itself. *)
                 ?deferred_runtime_lane
                 ~runtime_retry_deferral:
                   { Keeper_turn_driver.continuation = lane_retry_continuation
                   ; on_deferred = (fun hint -> deferred_runtime_lane_ref := Some hint)
                   }
                 ~on_runtime_attempt_failed:
                   (fun ~runtime_id ~dispatch ~error ->
                      runtime_attempt_errors_ref
                      := ({ runtime_id; dispatch; error } : runtime_attempt_error)
                         :: !runtime_attempt_errors_ref)
                 ~on_runtime_lane_terminal_error:
                   (fun terminal -> lane_terminal_error_ref := Some terminal)
                 ~on_runtime_selected:
                   (fun ~runtime_id -> answering_runtime_id_ref := Some runtime_id)
                 ?on_deferred_runtime_consumed
                 ~temperature:execution.temperature
                 ~trajectory_acc
                 ?shared_context
                 ?event_bus
                 ~on_event:(fun event ->
                   Keeper_autonomous_stream.on_event live_stream event;
                   Option.iter (fun projection -> Keeper_loop_tool_projection.on_event projection event) tool_projection)
                 ~on_tool_stream_observation:(fun observation ->
                   Keeper_autonomous_stream.on_tool_stream_observation live_stream observation;
                   Option.iter (fun projection -> Keeper_loop_tool_projection.on_tool_stream_observation projection observation) tool_projection)
                 ~on_tool_result_ready:(Keeper_autonomous_stream.on_tool_result_ready live_stream)
                 ~tool_result_commit_policy:Keeper_hooks_agent_core.Observe_commit
                 ?trace_link:(trace_link ())
                 ~on_checkpoint_stage:
                   (Keeper_turn_driver_try_provider.observe_checkpoint_stage
                      checkpoint_progress)
                 ()
            with
            | Eio.Cancel.Cancelled _ as exn ->
              record_streaming_cancelled_observation
                ~config
                ~run_meta
                ~runtime_id:execution.runtime_id
                ~keeper_turn_id
                ();
              raise exn)))
    in
    let settlement : Keeper_agent_run.turn_settlement =
      match authorized_settlement with
      | Ok settlement -> settlement
      (* Authority rejected the dispatch, so no provider ran, no receipt was
         written, and neither lane settled. *)
      | Error err ->
        Keeper_agent_run.not_dispatched err
    in
    (* The receipt's own verdict rides up on [turn_state] so the decision
       record below reports it rather than deciding again. *)
    let turn_state =
      { turn_state with degraded_retry_settled = Some settlement }
    in
    settlement.Keeper_agent_run.result, turn_state
  in
  let run_once (turn_state : turn_state) =
    let mark_terminal_error err =
      match EC.extract_input_required err with
      | Some ir ->
        Keeper_registry.mark_turn_runtime_done
          ~observation_token:(Some observation_token)
          ~base_path:config.base_path
          meta.name;
        Log.Keeper.info
          "[input_required] keeper=%s agent paused: request_id=%s \
           question=%s"
          meta.name
          ir.Agent_core.Error.request_id
          (let q = ir.Agent_core.Error.question in
           if String.length q > input_required_question_log_max_bytes
           then
             String_util.utf8_prefix ~max_bytes:input_required_question_log_max_bytes q
             ^ "…"
           else q);
        Keeper_turn_fsm.emit_transition
          ~keeper_name:meta.name
          ~turn_id:keeper_turn_id
          ~prev:Keeper_turn_fsm.Streaming
          (Keeper_turn_fsm.Cancelled
             Keeper_turn_fsm.Cancelled_input_required)
      | None ->
        Keeper_unified_turn_terminal_error.handle
          ~observation_token
          ~config
          ~keeper_name:meta.name
          ~runtime_id:initial_execution.runtime_id
          err
    in
    let attempt_result, turn_state =
      do_run
        ~execution:initial_execution
        ~run_meta:meta
        ~turn_state
    in
    match attempt_result with
    | Ok result ->
      let selected_model =
        match result.runtime_observation with
        | Some observation -> observation.selected_model
        | None -> None
      in
      Keeper_registry.set_turn_selected_runtime
        ~observation_token:(Some observation_token)
        ~base_path:config.base_path
        meta.name
        (Keeper_turn_selected_runtime.selected_runtime
           (Keeper_turn_selected_runtime.Completed
              { runtime_id = result.Keeper_agent_result.runtime_id
              ; selected_model
              }));
      Keeper_registry.mark_turn_runtime_done
        ~observation_token:(Some observation_token)
        ~base_path:config.base_path
        meta.name;
      Ok result, turn_state
    | Error err ->
      Keeper_registry.set_turn_selected_runtime
        ~observation_token:(Some observation_token)
        ~base_path:config.base_path
        meta.name
        (Keeper_turn_selected_runtime.selected_runtime
           (Keeper_turn_selected_runtime.Failed
              { answering_runtime_id = !answering_runtime_id_ref
              ; terminal_origin_runtime_id =
                  Option.map
                    (fun (terminal : Keeper_turn_driver.lane_terminal_error) ->
                       terminal.origin_runtime_id)
                    !lane_terminal_error_ref
              }));
      let turn_state =
        match !deferred_runtime_lane_ref with
        | Some hint ->
          { turn_state with deferred_runtime_lane = Some hint }
        | None -> turn_state
      in
      let turn_state =
        { turn_state with
          runtime_attempt_errors = List.rev !runtime_attempt_errors_ref
        ; lane_terminal_error = !lane_terminal_error_ref
        }
      in
      let checkpoint_observed =
        not
          (Keeper_turn_driver_try_provider.same_run_retry_allowed
             checkpoint_progress)
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
          ~runtime_id:initial_execution.runtime_id
          ~reason:"frozen_runtime_suffix_exhausted"
          ~error_kind:(Some Agent_core.Error.(category err |> category_label))
          ~error_message:(Some (Agent_core.Error.to_string err));
        mark_terminal_error err;
        Error err, turn_state
      | None ->
        (match declared_lane_failure_of_error err with
         | Provider_context_overflow ->
          Keeper_unified_turn_cascade_resolution.publish_cascade_resolution
            ~keeper_name:meta.name
            ~runtime_id:initial_execution.runtime_id
            ~reason:"provider_context_overflow"
            ~error_kind:(Some Agent_core.Error.(category err |> category_label))
            ~error_message:(Some (Agent_core.Error.to_string err));
          (* Pull the events published before the overflow. The drain moves
             the tool-call FSM and the registry's pending tool count; its
             summary is merged into the turn total that the finalize drain
             returns, so the value here is not needed. *)
          let (_ : Keeper_turn_runtime_budget.turn_event_bus_summary) =
            drain_turn_event_bus ~site:"context_overflow_capture" ()
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
            "%s: provider returned typed context overflow after the lane \
             walk: %s"
            meta.name
            (short_preview (Agent_core.Error.to_string err));
          (* Return the typed provider error and mark this attempt terminal.
             Whole-request provider fit remains tracked in #26551. *)
          mark_terminal_error err;
          Error err, turn_state
         | Declared_runtime_lane_exhausted ->
          Keeper_unified_turn_cascade_resolution.publish_cascade_resolution
            ~keeper_name:meta.name
            ~runtime_id:initial_execution.runtime_id
            ~reason:"declared_runtime_lane_exhausted"
            ~error_kind:(Some Agent_core.Error.(category err |> category_label))
            ~error_message:(Some (Agent_core.Error.to_string err));
          mark_terminal_error err;
          Error err, turn_state)
  in
  (* Do not wrap the full keeper turn in a cumulative wall-clock timeout.
     Long voice/AGENT_CORE turns can keep making stream or tool progress for a
     long time. Runaway detection is owned by stream idle, provider attempt
     liveness, tool-level timeouts, max-turn limits, and the optional
     supervisor stale-turn watchdog. *)
  let result, turn_state =
    try run_once turn_state with
    | Eio.Cancel.Cancelled _ as exn ->
      Keeper_autonomous_stream.finish live_stream Keeper_autonomous_stream.Cancelled;
      raise exn
    | exn ->
      Keeper_autonomous_stream.finish live_stream (Keeper_autonomous_stream.Failed (Printexc.to_string exn));
      raise exn
  in
  (* Common tool visibility is optional. Bind the actual turn and its complete
     prepared approval vector before the existing store appends any row. *)
  (try (match tool_projection with
   | None -> ()
   | Some projection ->
     let turn_ref =
       Ids.Turn_ref.make
         ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
         ~absolute_turn:keeper_turn_id
     in
     let persisted =
       Keeper_loop_tool_projection.persist_continuation
         projection
         ~base_dir:config.base_path
         ~keeper_name:meta.name
         ~turn_ref
         ~turn_failed:(Result.is_error result)
     in
     Keeper_autonomous_stream.publish_committed_tool_ownerships live_stream
       persisted.Keeper_loop_tool_projection.committed_ownerships;
     (* A quarantined row is missing from the projection below; the chat
        lane's live bridge would have reported the conflict as it happened,
        and this lane has no bridge, so it is said here, one line per row. *)
     List.iter
       (fun (kind, (occurrence : Keeper_chat_events.tool_stream_occurrence), detail) ->
          Log.Keeper.warn
            ~keeper_name:meta.name
            "%s: continuation turn tool row quarantined for turn %s (%s at \
             stream_scope=%d block_index=%d): %s"
            meta.name
            (Ids.Turn_ref.to_string turn_ref)
            (Keeper_chat_events.stream_protocol_error_kind_to_string kind)
            occurrence.stream_scope
            occurrence.block_index
            detail)
       persisted.Keeper_loop_tool_projection.quarantined;
     (match persisted.Keeper_loop_tool_projection.outcome with
      | Keeper_loop_tool_projection.Nothing_to_project -> ()
      | Keeper_loop_tool_projection.Projected (Keeper_chat_store.Appended _) -> ()
      | Keeper_loop_tool_projection.Projected (Keeper_chat_store.Already_present _) ->
        Log.Keeper.info
          ~keeper_name:meta.name
          "%s: continuation turn tool rows were already present for turn %s"
          meta.name
          (Ids.Turn_ref.to_string turn_ref)
      | Keeper_loop_tool_projection.Projection_dropped reason ->
        Log.Keeper.warn
          ~keeper_name:meta.name
          "%s: continuation turn tool rows were not projected: %s"
          meta.name
          (Keeper_loop_tool_projection.drop_reason_to_string reason)))
   with
   | Eio.Cancel.Cancelled _ as exn ->
     Keeper_autonomous_stream.finish live_stream Keeper_autonomous_stream.Cancelled;
     raise exn
   | exn ->
     Log.Keeper.warn ~keeper_name:meta.name
       "optional common tool transcript projection failed: %s" (Printexc.to_string exn));
  Keeper_autonomous_stream.finish live_stream
    (match result with
     | Ok result -> Keeper_autonomous_stream.Completed
         { reply = result.Keeper_agent_run.response_text; turn_outcome = result.turn_outcome }
     | Error error -> Keeper_autonomous_stream.Failed (Agent_core.Error.to_string error));
  result, turn_state
)

module For_testing = struct
  type nonrec declared_lane_failure = declared_lane_failure =
    | Provider_context_overflow
    | Declared_runtime_lane_exhausted

  let declared_lane_failure_of_error = declared_lane_failure_of_error
end
