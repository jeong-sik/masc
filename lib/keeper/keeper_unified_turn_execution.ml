(** Keeper_unified_turn_execution — Execution body for unified keeper cycles.

    Extracted from [Keeper_unified_turn.run_keeper_cycle]. Contains the
    [do_run] closure, [retry_loop] recursive function, wall-clock timeout
    wrapper, and cleanup/finalization logic.

    @since God file decomposition *)

open Keeper_types
open Keeper_exec_context
module KCP = Keeper_cascade_profile
include Keeper_turn_helpers
include Keeper_turn_liveness
include Keeper_turn_cascade_budget
include Keeper_unified_turn_types

type retry_loop_input =
  { run_meta : keeper_meta
  ; execution : cascade_execution
  ; run_generation : int
  ; attempt : int
  ; is_retry : bool
  ; allow_degraded_wall_clock_retry_budget : bool
  ; attempted_cascades : string list
  }

type ctx =
  { attempt : int
  ; base_dir : string
  ; build_turn_prompt : keeper_meta -> string
  ; cascade_rotation_attempts : Keeper_execution_receipt.cascade_rotation_attempt list ref
  ; channel : Keeper_world_observation.keeper_cycle_channel
  ; cleanup : unit -> unit
  ; committed_mutating_tools_snapshot : unit -> string list
  ; config : Coord.config
  ; current_turn_blocker_info : Keeper_state_machine.turn_blocker_info option ref
  ; degraded_retry_info : EC.degraded_retry option ref
  ; drain_turn_event_bus : ?site:string -> unit -> Keeper_unified_turn_event_bus.turn_event_bus_snapshot
  ; event_bus_integrity_error_snapshot : unit -> Agent_sdk.Error.sdk_error option
  ; failure_reason : Keeper_turn_fsm.failure_reason option ref
  ; generation : int
  ; keeper_turn_id : int
  ; last_execution : cascade_execution ref
  ; last_provider_timeout_budget : provider_timeout_budget option ref
  ; max_cost_usd : float option
  ; meta : keeper_meta
  ; observation : Keeper_world_observation.world_observation
  ; post_commit_failure_reason : Keeper_registry.failure_reason option ref
  ; profile_defaults : Keeper_types_profile.keeper_profile_defaults
  ; prompt_timeout_estimate_tokens : int
  ; record_cascade_rotation_attempt
      : ?slot_release_at_phase:Keeper_execution_receipt.slot_release_at_phase
      -> ?productive_phase_elapsed_ms:int
      -> ?retry_phase_elapsed_ms:int
      -> from_cascade:Cascade_name.t
      -> retry:EC.degraded_retry
      -> outcome:Keeper_execution_receipt.cascade_rotation_outcome
      -> Agent_sdk.Error.sdk_error
      -> unit
  ; shared_context : Keeper_shared_context.shared_context option
  ; trajectory_acc : Trajectory.t
  ; turn_affordances : Keeper_unified_metrics.observed_affordances
  ; turn_id : int
  ; turn_slot_control : Keeper_turn_slot.control option
  }

let run (ctx : ctx)
      ~(initial_execution : cascade_execution)
      ~(timeout_sec : float)
      ~(remaining_turn_budget_s : unit -> float)
      ~(retry_phase_started_at : float option ref)
      ~(current_turn_phase_elapsed_ms : unit -> int * int option)
      ~(keeper_profile : Keeper_types_profile.keeper_profile)
      ~(max_turns : int)
      ~(max_idle_turns : int)
      ~(initial_tool_requirement : Keeper_cascade_routing.tool_requirement)
      ~(user_message : string)
      ~(append_manifest : site:string -> ?status:string -> ?clock_refs:Keeper_runtime_manifest.clock_refs -> ?cascade_name:string -> ?decision:Keeper_runtime_manifest.decision_entry -> Keeper_runtime_manifest.event -> unit)
      ~(registry_base_path : string)
      ~(degraded_retry_slot_phase_budget_sec : float)
      ~(record_streaming_cancelled_observation : config:Coord.config -> run_meta:keeper_meta -> run_generation:int -> cascade_name:string -> keeper_turn_id:int -> unit -> unit)
      ~(active_fail_open_rotation_cascades : unit -> string list option)
      ~(cascade_name_of_meta : keeper_meta -> string)
      ~(start_background_turn_event_bus_drain : clock:'a Eio.Switch.r -> unit)
  : Agent_sdk.Types.api_response result
=
  let { config
      ; meta
      ; observation
      ; generation
      ; keeper_turn_id
      ; turn_id
      ; channel
      ; turn_slot_control
      ; shared_context
      ; base_dir
      ; build_turn_prompt
      ; turn_affordances
      ; max_cost_usd
      ; trajectory_acc
      ; last_execution
      ; last_provider_timeout_budget
      ; degraded_retry_info
      ; cascade_rotation_attempts
      ; current_turn_blocker_info
      ; post_commit_failure_reason
      ; profile_defaults
      ; prompt_timeout_estimate_tokens
      ; cleanup
      ; drain_turn_event_bus
      ; event_bus_integrity_error_snapshot
      ; committed_mutating_tools_snapshot
      ; record_cascade_rotation_attempt
      ; failure_reason
      ; attempt = _attempt
      } =
    ctx
  in
  let clock =
    match Eio_context.get_clock () with
    | Error msg -> failwith msg
    | Ok c -> c
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
         Keeper_unified_turn_attempt_watchdog.dispatch
           ~clock
           ~attempt_watchdog_s
           ~oas_timeout_s
           ~on_cancelled:(fun () ->
             record_streaming_cancelled_observation
               ~config
               ~run_meta
               ~run_generation
               ~cascade_name:execution.cascade_name
               ~keeper_turn_id
               ())
           ~run:(fun () ->
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
                 (Env_config_keeper.KeeperCascade.provider_allowlist ())
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
               ()))
  in
  let fail_open_rotation_cascades =
    active_fail_open_rotation_cascades ()
  in
  let rec retry_loop (input : retry_loop_input) =
    let { run_meta
        ; execution
        ; run_generation
        ; attempt
        ; is_retry
        ; allow_degraded_wall_clock_retry_budget
        ; attempted_cascades
        }
      =
      input
    in
    let execution_cascade_name =
      Cascade_name.to_string execution.cascade_name
    in
    let mark_terminal_error err =
      if EC.is_input_required_error err then begin
        let ir =
          match err with
          | Agent_sdk.Error.Agent (Agent_sdk.Error.InputRequired ir) -> ir
          | _ -> assert false
        in
        Keeper_registry.mark_turn_cascade_done
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
      end else
        Keeper_unified_turn_terminal_error.handle
          ~config
          ~keeper_name:meta.name
          ~attempt
          ~attempted_cascades
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
          ~attempted_cascades
      in
      match
        resolve_bounded_provider_timeout_budget_with_turn_budget
          ~allow_wall_clock_retry_budget
          ~is_retry
          ~max_turns
          ~estimated_input_tokens:prompt_timeout_estimate_tokens
          ~remaining_turn_budget_s:(remaining_turn_budget_s ())
      with
      | None ->
        let remaining_turn_budget_sec =
          remaining_turn_budget_s ()
        in
        let attempt_kind =
          if is_retry
          then Keeper_turn_cascade_budget.Retry_attempt
          else Keeper_turn_cascade_budget.First_attempt
        in
        (match
           Keeper_turn_cascade_budget.decide_retry_admission_for_turn
             ~remaining_turn_budget_s:remaining_turn_budget_sec
             ~attempt_kind
             ~allow_wall_clock_retry_budget
             ~estimated_input_tokens:prompt_timeout_estimate_tokens
             ~max_turns
         with
        | Error (denial : Cascade_internal_error.retry_admission_denial) ->
          Error
            (Keeper_turn_driver.sdk_error_of_masc_internal_error
               (Keeper_turn_driver.Retry_admission_denied
                  {
                    denial_reason = denial;
                    is_retry;
                  }))
        | Ok () ->
          Error
            (Keeper_turn_driver.sdk_error_of_masc_internal_error
               (Keeper_turn_driver.Turn_timeout
                  {
                    elapsed_sec =
                      Float.max 0.0
                        (timeout_sec -. remaining_turn_budget_sec);
                  })))
      | Some provider_timeout_budget ->
        attempt_provider_timeout_budget := Some provider_timeout_budget;
        last_provider_timeout_budget := Some provider_timeout_budget;
        let attempt_watchdog_s =
          attempt_watchdog_timeout_sec
            ~remaining_turn_budget_s:(remaining_turn_budget_s ())
            provider_timeout_budget
        in
        do_run
          ~execution
          ~run_meta
          ~run_generation
          ~is_retry
          ~oas_timeout_s:provider_timeout_budget.effective_timeout_sec
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
        reclassify_provider_timeout_for_attempt
          ~provider_timeout_budget:!attempt_provider_timeout_budget
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
                 (Cascade_name.of_string_or
                    ~fallback:execution.cascade_name
                    degraded_retry.next_cascade)
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
               Cascade_name.to_string next_execution.cascade_name
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
                 { run_meta
                 ; execution = next_execution
                 ; run_generation
                 ; attempt = 1
                 ; is_retry = true
                 ; allow_degraded_wall_clock_retry_budget = true
                 ; attempted_cascades =
                     next_execution_cascade_name :: attempted_cascades
                 }
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
            { run_meta
            ; execution
            ; run_generation
            ; attempt = attempt + 1
            ; is_retry = true
            ; allow_degraded_wall_clock_retry_budget = false
            ; attempted_cascades
            }
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
  try
    Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
      retry_loop
        { run_meta = meta
        ; execution = initial_execution
        ; run_generation = generation
        ; attempt = 1
        ; is_retry = false
        ; allow_degraded_wall_clock_retry_budget = false
        ; attempted_cascades =
            [ Cascade_name.to_string
                initial_execution.cascade_name
            ]
        })
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
                  { elapsed_sec = timeout_sec }))))
