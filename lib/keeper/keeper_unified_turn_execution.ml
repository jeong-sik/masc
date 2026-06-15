(** Keeper_unified_turn_execution — Execution body for unified keeper cycles.

    Extracted from [Keeper_unified_turn.run_keeper_cycle]. Contains the
    [do_run] closure, [retry_loop] recursive function, retry/admission
    budgeting, and cleanup/finalization logic.

    @since God file decomposition *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime
open Result.Syntax
include Keeper_turn_helpers
include Keeper_turn_liveness
include Keeper_turn_runtime_budget
include Keeper_unified_turn_types

type retry_loop_input =
  { run_meta : keeper_meta
  ; execution : runtime_execution
  ; run_generation : int
  ; attempt : int
  ; is_retry : bool
  ; allow_degraded_wall_clock_retry_budget : bool
  ; attempted_runtimes : string list
  }

type ctx =
  { attempt : int
  ; base_dir : string
  ; build_turn_prompt :
      base_system_prompt:string -> messages:Agent_sdk.Types.message list ->
      Keeper_agent_run.turn_prompt
  ; runtime_rotation_attempts : Keeper_execution_receipt.runtime_rotation_attempt list ref
  ; channel : Keeper_world_observation.keeper_cycle_channel
  ; cleanup : unit -> unit
  ; committed_mutating_tools_snapshot : unit -> string list
  ; config : Workspace.config
  ; current_turn_blocker_info : blocker_info option ref
  ; degraded_retry_info : EC.degraded_retry option ref
  ; drain_turn_event_bus : ?site:string -> unit -> Keeper_turn_runtime_budget.turn_event_bus_summary
  ; event_bus_integrity_error_snapshot : unit -> Agent_sdk.Error.sdk_error option
  ; failure_reason : Keeper_turn_fsm.failure_reason option ref
  ; generation : int
  ; keeper_turn_id : int
  ; last_execution : runtime_execution ref
  ; last_provider_timeout_budget : provider_timeout_budget option ref
  ; max_cost_usd : float option
  ; meta : keeper_meta
  ; turn_ctx_cell : Keeper_tool_call_log.turn_ctx_cell
  ; observation : Keeper_world_observation.world_observation
  ; post_commit_failure_reason : Keeper_registry.failure_reason option ref
  ; profile_defaults : Keeper_types_profile.keeper_profile_defaults
  ; prompt_timeout_estimate_tokens : int
  ; record_runtime_rotation_attempt
      : ?productive_phase_elapsed_ms:int
      -> ?retry_phase_elapsed_ms:int
      -> from_runtime:string
      -> retry:EC.degraded_retry
      -> outcome:Keeper_execution_receipt.runtime_rotation_outcome
      -> Agent_sdk.Error.sdk_error
      -> unit
  ; shared_context : Agent_sdk.Context.t option
  ; trajectory_acc : Trajectory.accumulator
  ; turn_affordances : string list
  ; turn_id : int
  }

let run (ctx : ctx)
      ~(initial_execution : runtime_execution)
      ~(timeout_sec : float)
      ~(remaining_turn_budget_s : unit -> float)
      ~(retry_phase_started_at : float option ref)
      ~(current_turn_phase_elapsed_ms : unit -> int * int option)
      ~(keeper_profile : Keeper_types_profile.keeper_profile_defaults)
      ~(max_turns : int)
      ~(max_idle_turns : int)
      ~(user_message : string)
      ~(registry_base_path : string)
      ~(degraded_retry_slot_phase_budget_sec : float)
      ~(record_streaming_cancelled_observation : ?cancel_reason:string -> config:Workspace.config -> run_meta:keeper_meta -> run_generation:int -> runtime_id:string -> keeper_turn_id:int -> unit -> unit)
      ~(runtime_id_of_meta : keeper_meta -> string)
      ~(start_background_turn_event_bus_drain : clock:float Eio.Time.clock_ty Eio.Resource.t -> unit)
  : (Keeper_agent_run.run_result, Agent_sdk.Error.sdk_error) result
=
  let { config
      ; meta
      ; turn_ctx_cell
      ; observation
      ; generation
      ; keeper_turn_id
      ; turn_id
      ; channel
      ; shared_context
      ; base_dir
      ; build_turn_prompt
      ; turn_affordances
      ; max_cost_usd
      ; trajectory_acc
      ; last_execution
      ; last_provider_timeout_budget
      ; degraded_retry_info
      ; runtime_rotation_attempts
      ; current_turn_blocker_info
      ; post_commit_failure_reason
      ; profile_defaults
      ; prompt_timeout_estimate_tokens
      ; cleanup
      ; drain_turn_event_bus
      ; event_bus_integrity_error_snapshot
      ; committed_mutating_tools_snapshot
      ; record_runtime_rotation_attempt
      ; failure_reason
      ; attempt = _attempt
      } =
    ctx
  in
  (match Eio_context.get_clock () with
   | Error msg -> Error (Agent_sdk.Error.Internal msg)
   | Ok clock ->
   let do_run
        ~(execution : runtime_execution)
        ~run_meta
        ~run_generation
        ~is_retry
        ~oas_timeout_s
    =
    last_execution := execution;
    Otel_genai.with_keeper_turn_span
      ~keeper_name:run_meta.name
      ~agent_name:run_meta.agent_name
      ~runtime_id:execution.runtime_id
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
      (fun trace_link ->
         Keeper_registry.mark_turn_provider_attempt_started
           ~base_path:config.base_path
           meta.name;
         Keeper_unified_turn_attempt_watchdog.dispatch
           ~clock
           ~keeper_name:meta.name
           ~attempt_watchdog_s:None
           ~on_cancelled:(fun reason ->
             record_streaming_cancelled_observation
               ~cancel_reason:reason
               ~config
               ~run_meta
               ~run_generation
               ~runtime_id:execution.runtime_id
               ~keeper_turn_id
               ())
           ~run:(fun () ->
             (* Emit before the provider/tool run so operator forensics can see
                that the keeper entered Streaming. [dispatch] observes external
                cancellation only; it must not impose a MASC wall-clock timeout
                around active tool execution. *)
             Keeper_turn_fsm.emit_transition
               ~keeper_name:meta.name
               ~turn_id:keeper_turn_id
               ~prev:Keeper_turn_fsm.Awaiting_provider
               Keeper_turn_fsm.Streaming;
             Keeper_agent_run.run_turn
               ~config
               ~meta:run_meta
               ~turn_ctx_cell
               ~base_dir
               ~max_context:execution.max_context
               ~build_turn_prompt
               ~user_message
               ~runtime_id:execution.runtime_id
               ~world_observation:observation
               ~turn_affordances
               ~generation:run_generation
               ~max_turns
               ~max_idle_turns
               ~history_user_source:"world_state_prompt"
               ~history_assistant_source:"internal_assistant"
               ~degraded_retry_applied:
                 (Option.is_some !degraded_retry_info)
               ?degraded_retry_runtime:
                 (Option.map
                    (fun (retry : EC.degraded_retry) ->
                       retry.next_runtime)
                    !degraded_retry_info)
               ?fallback_reason:
                 (Option.map
                    (fun (retry : EC.degraded_retry) ->
                       retry.fallback_reason)
                    !degraded_retry_info)
               ~runtime_rotation_attempts:
                 (List.rev !runtime_rotation_attempts)
               ~temperature:execution.temperature
               ~max_tokens:execution.max_tokens
               ~oas_timeout_s
               ~oas_timeout_is_explicit:false
               ?max_cost_usd
               ~trajectory_acc
               ~is_retry
               ?shared_context
               ?event_bus:(Keeper_event_bus.get ())
               ?trace_link:(trace_link ())
               ()))
  in
  let rec retry_loop (input : retry_loop_input) =
    let { run_meta
        ; execution
        ; run_generation
        ; attempt
        ; is_retry
        ; allow_degraded_wall_clock_retry_budget
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
    let attempt_provider_timeout_budget = ref None in
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
      let allow_wall_clock_retry_budget =
        allow_wall_clock_retry_budget_for_attempt
          ~is_retry
          ~degraded_rotation_first_attempt:
            allow_degraded_wall_clock_retry_budget
          ~attempt
          ~attempted_runtimes
      in
      let provider_timeout_budget =
        resolve_bounded_provider_timeout_budget_with_turn_budget
          ~allow_wall_clock_retry_budget
          ~is_retry
          ~max_turns
          ~estimated_input_tokens:prompt_timeout_estimate_tokens
          ~remaining_turn_budget_s:(remaining_turn_budget_s ())
      in
      attempt_provider_timeout_budget := Some provider_timeout_budget;
      last_provider_timeout_budget := Some provider_timeout_budget;
      do_run
        ~execution
        ~run_meta
        ~run_generation
        ~is_retry
        ~oas_timeout_s:provider_timeout_budget.effective_timeout_sec
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
      Ok result
    | Error err ->
      (* RFC-XXXX: reclassify_provider_timeout_for_attempt removed.
         The per-attempt wall-clock watchdog no longer fires, so the
         structural OAS timeout path is dead. Provider errors pass
         through unchanged for the downstream typed error classifier. *)
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
        && EC.is_auto_recoverable_turn_error err
      then (
        let err_preview =
          short_preview (Agent_sdk.Error.to_string err)
        in
        let reason =
          if EC.is_server_rejected_parse_error err
          then "server parse rejection"
          else "transient error"
        in
        Log.Keeper.warn
          "%s: %s after committed reconcile-safe tool(s) [%s] — \
           auto-recovering (error: %s)"
          meta.name
          reason
          (String.concat ", " committed_tools)
          err_preview;
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string TurnErrorAfterTools)
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
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string PostTurnWireinFailures)
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
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string TurnErrorAfterTools)
          ~labels:[ "keeper", meta.name ]
          ();
        mark_terminal_error reclassified;
        Error reclassified)
      else (
        match
          next_fail_open_runtime_for_turn_with_budget
            ~base_runtime:(runtime_id_of_meta meta)
            ~effective_runtime:execution_runtime_id
            ~attempted_runtimes
            ~estimated_input_tokens:prompt_timeout_estimate_tokens
            ~max_turns
            ~time_spent_in_turn_s:
              (timeout_sec -. remaining_turn_budget_s ())
            ~remaining_turn_budget_s:(remaining_turn_budget_s ())
            err
        with
        | Degraded_retry_allowed degraded_retry ->
          Keeper_unified_turn_cascade_resolution.publish_cascade_resolution
            ~keeper_name:meta.name
            ~runtime_id:execution.runtime_id
            ~decision:Degraded_retry_allowed
            ~reason:(EC.degraded_retry_reason_to_string degraded_retry.fallback_reason)
            ~next_runtime:(Some degraded_retry.next_runtime)
            ~attempt
            ~error_kind:(Some (Keeper_agent_error.sdk_error_kind err))
            ~error_message:(Some (Agent_sdk.Error.to_string err));
          (match
             Keeper_unified_turn_pre_dispatch
             .build_runtime_execution
               ~meta
               ~profile_defaults
               ~runtime_id:
                 (* RFC-0206: raw runtime id (no prefix validation); keep the
                    empty→fallback behaviour only. *)
                 (if String.trim degraded_retry.next_runtime = ""
                  then execution.runtime_id
                  else degraded_retry.next_runtime)
           with
           | Error fail_open_err ->
             let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
               current_turn_phase_elapsed_ms ()
             in
             record_runtime_rotation_attempt
               ~productive_phase_elapsed_ms
               ?retry_phase_elapsed_ms
               ~from_runtime:execution.runtime_id
               ~retry:degraded_retry
               ~outcome:
                 Keeper_execution_receipt.Rotation_setup_failed
               fail_open_err;
             Log.Keeper.warn
               "%s: recoverable runtime failure in %s suggested \
                degraded retry to %s (reason=%s), but retry setup \
                failed: %s"
               meta.name
               execution_runtime_id
               degraded_retry.next_runtime
               (EC.degraded_retry_reason_to_string
                  degraded_retry.fallback_reason)
               (short_preview
                  (Agent_sdk.Error.to_string fail_open_err));
             mark_terminal_error fail_open_err;
             Error fail_open_err
           | Ok next_execution ->
             let next_execution_runtime_id =
               next_execution.runtime_id
             in
             if Option.is_none !retry_phase_started_at
             then retry_phase_started_at := Some (Eio.Time.now clock);
             let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
               current_turn_phase_elapsed_ms ()
             in
             record_runtime_rotation_attempt
               ~productive_phase_elapsed_ms
               ?retry_phase_elapsed_ms
               ~from_runtime:execution.runtime_id
               ~retry:degraded_retry
               ~outcome:
                 Keeper_execution_receipt.Rotation_retry_scheduled
               err;
             degraded_retry_info := Some degraded_retry;
             Log.Keeper.warn
               "%s: recoverable runtime failure in %s; rotation \
                retry on runtime=%s reason=%s max_context=%d \
                context_budget=%d primary_budget=%d \
                requested_override=%s: %s"
               meta.name
               execution_runtime_id
               next_execution_runtime_id
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
             retry_loop
               { run_meta
               ; execution = next_execution
               ; run_generation
               ; attempt = 1
               ; is_retry = true
               ; allow_degraded_wall_clock_retry_budget = true
               ; attempted_runtimes =
                   next_execution_runtime_id :: attempted_runtimes
               })
        | Degraded_retry_slot_phase_exhausted degraded_retry ->
          Keeper_unified_turn_cascade_resolution.publish_cascade_resolution
            ~keeper_name:meta.name
            ~runtime_id:execution.runtime_id
            ~decision:Degraded_retry_slot_phase_exhausted
            ~reason:(EC.degraded_retry_reason_to_string degraded_retry.fallback_reason)
            ~next_runtime:(Some degraded_retry.next_runtime)
            ~attempt
            ~error_kind:(Some (Keeper_agent_error.sdk_error_kind err))
            ~error_message:(Some (Agent_sdk.Error.to_string err));
          let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
            current_turn_phase_elapsed_ms ()
          in
          record_runtime_rotation_attempt
            ~productive_phase_elapsed_ms
            ?retry_phase_elapsed_ms
            ~from_runtime:execution.runtime_id
            ~retry:degraded_retry
            ~outcome:
              Keeper_execution_receipt.Rotation_slot_phase_exhausted
            err;
          Log.Keeper.warn
            "%s: recoverable runtime failure in %s suggested \
             degraded retry to %s (reason=%s), but productive slot \
             phase budget %.1fs is exhausted after %.1fs; ending \
             this cycle to release the outer turn holder: %s"
            meta.name
            execution_runtime_id
            degraded_retry.next_runtime
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
          Keeper_unified_turn_cascade_resolution.publish_cascade_resolution
            ~keeper_name:meta.name
            ~runtime_id:execution.runtime_id
            ~decision:Transient_network_retry
            ~reason:"transient_network_error"
            ~next_runtime:None
            ~attempt
            ~error_kind:(Some (Keeper_agent_error.sdk_error_kind err))
            ~error_message:(Some (Agent_sdk.Error.to_string err));
          let delay = EC.transient_backoff_sec attempt in
          Log.Keeper.warn
            "%s: transient network error runtime=%s max_context=%d \
             context_budget=%d primary_budget=%d \
             requested_override=%s retry=%d/%d backoff=%.0fs: %s"
            meta.name
            execution_runtime_id
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
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string OasExecutionErrors)
            ~labels:
              [ "keeper", meta.name
              ; "phase", Keeper_oas_execution_error_phase.(to_label Recoverable_runtime_transient)
              ]
            ();
          (* Retry backoff remains inside the same keeper turn holder.  The
             delay is an observation, not an admission state that can produce
             a second semaphore timeout while the original turn is still
             logically active. *)
          Eio.Time.sleep clock delay;
          retry_loop
            { run_meta
            ; execution
            ; run_generation
            ; attempt = attempt + 1
            ; is_retry = true
            ; allow_degraded_wall_clock_retry_budget = false
            ; attempted_runtimes
            }
        | No_degraded_retry when EC.is_context_overflow err ->
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
          let overflow_event =
            context_overflow_event_of_error
              ~fallback_tokens:execution.max_context
              ~turn_event_bus:current_turn_event_bus
              err
          in
          current_turn_blocker_info
          := Some
               { klass = Sdk_token_budget_exceeded
               ; detail =
                   Keeper_state_machine.event_to_string
                     overflow_event
                   ^ ": "
                   ^ Agent_sdk.Error.to_string err
               };
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
            "%s: OAS returned context overflow after its owned retry \
             path; MASC will not compact/retry at keeper layer: %s"
            meta.name
            (short_preview (Agent_sdk.Error.to_string err));
          mark_terminal_error err;
          Error err
        | No_degraded_retry ->
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
          Error err)
  in
  (* Do not wrap the full keeper turn in a cumulative wall-clock timeout.
     Long voice/OAS turns can keep making stream or tool progress beyond the
     legacy 600s cap. Runaway detection is owned by stream idle, provider
     attempt liveness, tool-level timeouts, max-turn limits, and the optional
     supervisor stale-turn watchdog. Retry admission must not reintroduce the
     cumulative wall-clock cap between provider attempts. *)
  retry_loop
    { run_meta = meta
    ; execution = initial_execution
    ; run_generation = generation
    ; attempt = 1
    ; is_retry = false
    ; allow_degraded_wall_clock_retry_budget = false
    ; attempted_runtimes =
        [ initial_execution.runtime_id
        ]
    }
)
