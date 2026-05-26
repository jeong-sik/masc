(** Keeper_turn_driver_try_cascade — Cascade retry loop with provider dispatch.

    Extracted from [Keeper_turn_driver.run_named]. The [try_cascade]
    recursive function iterates through provider candidates, handling
    pre-dispatch gates, health cooldowns, capacity management, and
    FSM-based cascade decisions.

    @since God file decomposition *)

open Result.Syntax
open Cascade_name

include Cascade_error_classify
include Cascade_attempt_fsm
include Keeper_turn_driver_helpers
include Keeper_turn_driver_provider_attempt

let provider_attempt_provenance = base_provider_attempt_provenance

type try_cascade_ctx =
  { (* Cascade identity *)
    cascade_name : string
  ; error_cascade_name : Cascade_name.t
  ; keeper_name : string
  ; name : string
  ; (* Candidates *)
    candidate_count : int
  ; configured_labels : string list
  ; error_selected_model_raw : string option
  ; capture : Cascade_observation.cascade_metrics_capture
  ; cascade_strategy_name_ref : string option ref
  ; (* Provider dispatch *)
    try_provider_ctx : Keeper_turn_driver_try_provider.try_provider_ctx
  ; (* Tool config *)
    runtime_manifest_required_tool_names : string list
  ; runtime_mcp_policy : Llm_provider.Llm_transport.runtime_mcp_policy option
  ; tools : Agent_sdk.Tool.t list
  ; require_tool_choice_support : bool
  ; (* Rejection tracking *)
    required_lane_provider_rejections : Cascade_error_classify.provider_rejection list
  ; (* Manifest *)
    emit_runtime_manifest :
      ?status:string ->
      ?decision:Yojson.Safe.t ->
      ?oas_turn_count:int ->
      Keeper_runtime_manifest.event_kind ->
      unit
  ; runtime_manifest_context : Keeper_runtime_manifest.turn_context option
  ; runtime_manifest_append : (Keeper_runtime_manifest.t -> unit) option
  ; cascade_engine : Keeper_cascade_engine.t
  ; turn_start : Mtime.t
  ; seq_ref : int ref
  ; (* Other config *)
    health_cooldown_fail_open : bool
  ; base_path : string option
  ; session_id : string option
  ; tier_admission_policy : Cascade_tier_admission.admission_policy
  ; (* Cascade accept predicate *)
    accept : Agent_sdk_response.api_response -> bool
  ; (* Error cascade name for backpressure *)
    error_cascade_name_for_backpressure : Cascade_name.t
  ; (* Provider health recording *)
    record_provider_health_result :
      Cascade_runtime_candidate.t -> success:bool -> http_status:int option -> unit
  ; (* Provider health filtering *)
    filter_provider_health_fail_open :
      Cascade_runtime_candidate.t list -> Cascade_runtime_candidate.t list
  ; (* Provider health error recording *)
    record_provider_health_error :
      Cascade_runtime_candidate.t -> Provider_error.t -> unit
  }

(* Manifest ID helpers — pure functions taking manifest context. *)

let manifest_turn_label (manifest_ctx : Keeper_runtime_manifest.turn_context) =
  match manifest_ctx.manifest_keeper_turn_id with
  | Some value -> string_of_int value
  | None -> "unknown"

let provider_attempt_id_for_context manifest_ctx attempt_index =
  Printf.sprintf "%s:keeper-%s:provider-attempt-%d"
    manifest_ctx.Keeper_runtime_manifest.manifest_trace_id
    (manifest_turn_label manifest_ctx)
    attempt_index

let provider_attempt_edge_id manifest_ctx event attempt_index =
  Printf.sprintf "%s:%s"
    (provider_attempt_id_for_context manifest_ctx attempt_index)
    (Keeper_runtime_manifest.event_kind_to_string event)

let provider_attempt_clock_refs ctx ~event ~attempt_index ?parent_event_id
    ?caused_by () =
  match ctx.runtime_manifest_context with
  | None -> `Assoc []
  | Some manifest_ctx ->
    Keeper_runtime_manifest.clock_refs
      ~edge_id:(provider_attempt_edge_id manifest_ctx event attempt_index)
      ~lane:"provider"
      ~source_clock:Provider
      ~provider_attempt_id:
        (provider_attempt_id_for_context manifest_ctx attempt_index)
      ?parent_event_id ?caused_by ()

let try_provider ctx ?resume_checkpoint ?per_provider_timeout_s candidate =
  Keeper_turn_driver_try_provider.run_try_provider
    ctx.try_provider_ctx
    ?resume_checkpoint
    ?per_provider_timeout_s
    candidate

let record_cascade_attempt ctx candidate ?http_status ~outcome () =
  match ctx.base_path with
  | None -> ()
  | Some base_path ->
    if String.equal (String.trim ctx.keeper_name) ""
    then ()
    else
      let record : Keeper_types.cascade_attempt_record =
        { provider_id = Cascade_runtime_candidate.provider_label candidate
        ; http_status
        ; outcome
        ; timestamp =
            Unix.gettimeofday ()
        }
      in
      Keeper_registry_cascade_attempt.record ~base_path
        ~keeper_name:ctx.keeper_name record

let emit_capacity_blocked_manifest ctx ~capacity_key =
  ctx.emit_runtime_manifest
    ~status:"blocked"
    ~decision:(client_capacity_full_decision ~capacity_key)
    Keeper_runtime_manifest.Pre_dispatch_blocked

let emit_tier_admission_blocked_manifest ctx signal =
  ctx.emit_runtime_manifest
    ~status:"blocked"
    ~decision:(Keeper_turn_driver_admission.cascade_tier_admission_blocked_decision signal)
    Keeper_runtime_manifest.Pre_dispatch_blocked

let capacity_backpressure_of_http_error ctx ?source last_err =
  Keeper_turn_driver_backpressure.capacity_backpressure_of_http_error
    ?source ~cascade_name:ctx.error_cascade_name_for_backpressure last_err

let capacity_backpressure_of_pending ctx last_capacity_backpressure =
  Keeper_turn_driver_backpressure.capacity_backpressure_of_pending
    ~cascade_name:ctx.error_cascade_name_for_backpressure last_capacity_backpressure

let capacity_backpressure_of_sdk_error ctx sdk_err =
  Keeper_turn_driver_backpressure.capacity_backpressure_of_sdk_error
    ~cascade_name:ctx.error_cascade_name_for_backpressure
    ~message_looks_like_capacity_backpressure
    ~sdk_error_of_masc_internal_error sdk_err

let rec run
    ?(on_success = fun ~provider_key:_ -> ())
    ?(pre_dispatch_required_tool_rejections_rev = [])
    ?resume_checkpoint ?per_provider_timeout_s ?last_capacity_source
    ?last_capacity_backpressure ctx remaining last_err =
  match remaining with
  | [] ->
    let pre_dispatch_no_tool_capable =
      match last_err, last_capacity_backpressure with
      | None, None ->
        no_tool_capable_provider_of_pre_dispatch_rejections
          ~cascade_name:ctx.error_cascade_name
          ~configured_labels:ctx.configured_labels
          ~runtime_manifest_required_tool_names:ctx.runtime_manifest_required_tool_names
          ~runtime_mcp_policy:ctx.runtime_mcp_policy
          ~tools:ctx.tools
          ~required_lane_provider_rejections:ctx.required_lane_provider_rejections
          ~pre_dispatch_provider_rejections:
            (List.rev pre_dispatch_required_tool_rejections_rev)
      | Some _, _ | _, Some _ -> None
    in
    let reason : Keeper_types.cascade_exhaustion_reason = match last_err with
      | Some (Llm_provider.Http_client.NetworkError { message; kind }) ->
          if kind = Llm_provider.Http_client.Connection_refused
             || String_util.contains_substring_ci message "connection refused" then
            Keeper_types.Connection_refused
          else if kind = Llm_provider.Http_client.Dns_failure then
            Keeper_types.Dns_failure
          else if message_looks_like_cli_wrapped_max_turns message then
            Keeper_types.Max_turns_exceeded
          else
            Keeper_types.cascade_exhaustion_reason_from_message
              (Cascade_fsm.to_user_message last_err)
      | Some (Llm_provider.Http_client.TimeoutError { message; _ }) ->
          if message_looks_like_cli_wrapped_max_turns message then
            Keeper_types.Max_turns_exceeded
          else
            Keeper_types.cascade_exhaustion_reason_from_message
              (Cascade_fsm.to_user_message last_err)
      | Some (Llm_provider.Http_client.HttpError { body; _ }) ->
          if message_looks_like_cli_wrapped_max_turns body then
            Keeper_types.Max_turns_exceeded
          else
            Keeper_types.cascade_exhaustion_reason_from_message
              (Cascade_fsm.to_user_message last_err)
      | Some (Llm_provider.Http_client.AcceptRejected { reason = r }) ->
          if message_looks_like_cli_wrapped_max_turns r then
            Keeper_types.Max_turns_exceeded
          else
            Keeper_types.cascade_exhaustion_reason_from_message
              (Cascade_fsm.to_user_message last_err)
      | Some (Llm_provider.Http_client.CliTransportRequired _) ->
          Keeper_types.cascade_exhaustion_reason_from_message
              (Cascade_fsm.to_user_message last_err)
      | Some (Llm_provider.Http_client.ProviderTerminal
          { kind = Llm_provider.Http_client.Max_turns _; _ }) ->
          Keeper_types.Max_turns_exceeded
      | Some (Llm_provider.Http_client.ProviderTerminal
          { kind = Llm_provider.Http_client.Other _; _ }) ->
          Keeper_types.cascade_exhaustion_reason_from_message
              (Cascade_fsm.to_user_message last_err)
      | Some (Llm_provider.Http_client.ProviderFailure _ as err) ->
          let message = Cascade_fsm.to_user_message (Some err) in
          if message_looks_like_cli_wrapped_max_turns message then
            Keeper_types.Max_turns_exceeded
          else
            Keeper_types.cascade_exhaustion_reason_from_message message
      | None -> Keeper_types.No_providers_available
    in
    let observation =
      Cascade_observation.cascade_observation_with_metrics
        ~cascade_name:ctx.error_cascade_name
        ?strategy:!(ctx.cascade_strategy_name_ref) ~configured_labels:ctx.configured_labels
        ~candidate_count:ctx.candidate_count ~selected_model_raw:ctx.error_selected_model_raw
        ~capture:ctx.capture ()
    in
    Cascade_observation.record_cascade ~keeper_name:ctx.keeper_name
      ~cascade_name:ctx.error_cascade_name
      ~outcome:`Failure ~observation:(Some observation) ();
    let terminal_error =
      match last_err with
      | Some (Llm_provider.Http_client.NetworkError { message; _ })
        when message_looks_like_resumable_cli_session message ->
          sdk_error_of_masc_internal_error
            (Resumable_cli_session
               {
                 cascade_name = ctx.error_cascade_name;
                 detail = resumable_cli_session_detail message;
                 exit_code = resumable_cli_session_exit_code message;
               })
      | Some (Llm_provider.Http_client.AcceptRejected { reason })
        when message_looks_like_resumable_cli_session reason ->
          sdk_error_of_masc_internal_error
            (Resumable_cli_session
               {
                 cascade_name = ctx.error_cascade_name;
                 detail = resumable_cli_session_detail reason;
                 exit_code = resumable_cli_session_exit_code reason;
               })
      | _ ->
        (match
           match
             capacity_backpressure_of_http_error ctx
               ?source:last_capacity_source last_err
           with
           | Some _ as capacity_error -> capacity_error
           | None ->
             capacity_backpressure_of_pending ctx last_capacity_backpressure
         with
         | Some capacity_error ->
           sdk_error_of_masc_internal_error capacity_error
         | None ->
           sdk_error_of_masc_internal_error
             (match pre_dispatch_no_tool_capable with
              | Some internal_error -> internal_error
              | None ->
                Cascade_exhausted
                  {
                    cascade_name = ctx.error_cascade_name;
                    reason;
                  }))
    in
    Error terminal_error
  | candidate :: rest ->
    (if ctx.health_cooldown_fail_open then (
       let now = Unix.gettimeofday () in
       let all_candidates = candidate :: rest in
       let cooldown_expirations =
         List.filter_map
           (fun c ->
              match Cascade_runtime_candidate.first_health_cooldown c with
              | None -> None
              | Some (key, _) -> (
                match
                  Cascade_health_tracker.provider_info
                    Cascade_health_tracker.global ~provider_key:key
                with
                | None -> None
                | Some info -> info.cooldown_expires_at))
           all_candidates
       in
       if List.length cooldown_expirations = List.length all_candidates
          && cooldown_expirations <> []
       then (
         let min_expiry =
           List.fold_left Float.min Float.infinity cooldown_expirations
         in
         let wait_sec =
           Float.max 0.0
             (Float.min
                (min_expiry -. now)
                Cascade_health_tracker_config.default_capacity_backpressure_backoff_sec)
         in
         if wait_sec > 0.0 then (
           Log.Misc.info
             "cascade %s: fleet-level backoff -- all %d provider(s) in \
              cooldown, waiting %.1fs for earliest recovery"
             ctx.cascade_name
             (List.length all_candidates)
             wait_sec;
           match Eio_context.get_clock_opt () with
           | Some clock -> Eio.Time.sleep clock wait_sec
           | None -> ()))));
    Eio_guard.fair_yield ();
    let pre_dispatch_blocked =
      match ctx.runtime_manifest_required_tool_names with
      | [] -> None
      | required_tool_names ->
      let provider_label = Cascade_runtime_candidate.provider_label candidate in
      match
        Cascade_runtime_candidate.resolve_tool_lane_for_oas_tools
          ?agent_name:(Cascade_oas_runner.keeper_agent_name_opt ctx.keeper_name)
          ~tool_requirement:`Required
          ~tools:ctx.tools
          candidate
      with
      | Error _ -> None
      | Ok (effective_tools, runtime_mcp_policy) ->
        let satisfying_tools =
          effective_tools
          |> List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name)
        in
        let satisfying_tools =
          match runtime_mcp_policy with
          | Some policy ->
            Json_util.dedupe_keep_order
              (satisfying_tools @ policy.Llm_provider.Llm_transport.allowed_tool_names)
          | None -> satisfying_tools
        in
        let snapshot =
          Provider_capability.known
            ~provider_name:provider_label
            ~satisfying_tools
            ~tool_choice_support:ctx.require_tool_choice_support
        in
        (match
           Provider_capability.can_satisfy_required_action
             ~require_tool_choice:ctx.require_tool_choice_support
             snapshot
             ~required_tools:required_tool_names
         with
         | Some false ->
           let missing =
             match
               Provider_capability.missing_required_tools
                 snapshot ~required_tools:required_tool_names
             with
             | Some m -> m
             | None -> required_tool_names
           in
           let skip_reason =
             Cascade_candidate_skip_reason.Required_tool_unsupported { missing }
           in
           let provider_rejection =
             provider_rejection_for_required_tool_unsupported
               ~provider_label
               ~missing_required_tools:missing
           in
           Log.Misc.info
             "cascade %s: pre-dispatch blocked provider=%s reason=%s \
              missing=[%s]"
             ctx.cascade_name
             provider_label
             (Cascade_candidate_skip_reason.to_manifest_tag skip_reason)
             (String.concat ", " missing);
           Provider_capability.record_pre_dispatch_required_tool_filtered
             ~provider:provider_label
             ~missing_count:(List.length missing);
           ctx.emit_runtime_manifest
             ~status:"blocked"
             ~decision:
               (`Assoc
                  [ "blocker", `String "required_tool_unsupported"
                  ; "provider", `String provider_label
                  ; ( "missing_tools",
                      `List (List.map (fun t -> `String t) missing) )
                  ; "provider_attempt_started", `Bool false
                  ])
             Keeper_runtime_manifest.Pre_dispatch_blocked;
           Some provider_rejection
         | Some true | None -> None)
    in
    match pre_dispatch_blocked with
    | Some provider_rejection ->
      run ~on_success ?resume_checkpoint ?per_provider_timeout_s
        ~pre_dispatch_required_tool_rejections_rev:
          (provider_rejection :: pre_dispatch_required_tool_rejections_rev)
        ?last_capacity_source ?last_capacity_backpressure ctx rest last_err
    | None ->
    let tier_admission_id = Cascade_runtime_candidate.tier_id candidate in
    let health_cooldown =
      Cascade_runtime_candidate.first_health_cooldown candidate
    in
    let should_skip_health_cooldown =
      match health_cooldown with
      | None -> false
      | Some _ -> not ctx.health_cooldown_fail_open
    in
    if should_skip_health_cooldown then (
      match health_cooldown with
      | Some (_blocked_health_key, msg) ->
          Log.Misc.debug
            "cascade %s: skipping %s (provider_key=%s cooldown: %s)"
            ctx.cascade_name runtime_candidate_label runtime_candidate_label msg;
          run ~on_success ?resume_checkpoint ?per_provider_timeout_s
            ~pre_dispatch_required_tool_rejections_rev
            ?last_capacity_source ?last_capacity_backpressure ctx rest last_err
      | None ->
          run ~on_success ?resume_checkpoint ?per_provider_timeout_s
            ~pre_dispatch_required_tool_rejections_rev
            ?last_capacity_source ?last_capacity_backpressure ctx rest last_err)
    else (
    (match health_cooldown with
     | Some (_blocked_health_key, msg) ->
         Log.Misc.warn
           "cascade %s: attempting %s despite health/cooldown fail-open \
            (provider_key=%s cooldown: %s)"
           ctx.cascade_name runtime_candidate_label runtime_candidate_label msg
     | None -> ());
    let is_last = rest = [] in
    let attempt_index = max 1 (ctx.candidate_count - List.length rest) in
    match Keeper_turn_driver_cascade_health.acquire_client_capacity_slot candidate with
    | `Full (capacity_key, retry_after_s) ->
      emit_capacity_blocked_manifest ctx ~capacity_key;
      record_cascade_attempt ctx candidate ~outcome:(`Failure "client_capacity_full") ();
      Cascade_observation.record_fallback_event ctx.capture
        ~from_model:runtime_candidate_label
        ~to_model:runtime_candidate_label
        ~reason:"client_capacity_full";
      Log.Misc.info
        "[cascade-fallback] cascade %s: %s skipped because client capacity \
         key %s is full, trying next"
        ctx.cascade_name
        runtime_candidate_label
        capacity_key;
      let capacity_detail =
        Printf.sprintf "client capacity key %s is full" capacity_key
      in
      run ~on_success ?resume_checkpoint ?per_provider_timeout_s
        ~pre_dispatch_required_tool_rejections_rev
        ~last_capacity_backpressure:
          (Client_capacity, capacity_detail, retry_after_s)
        ctx rest last_err
    | (`No_client_capacity | `Acquired _) as capacity_slot ->
    let capacity_release =
      match capacity_slot with
      | `Acquired (_capacity_key, release) -> Some release
      | `No_client_capacity -> None
      | `Full _ -> None
    in
    Log.Misc.debug "cascade %s: trying %s (is_last=%b)" ctx.cascade_name runtime_candidate_label is_last;
    let timeout_resolution =
      Cascade_runtime_candidate.effective_attempt_timeout_resolution
        ~is_last
        ~configured_timeout_s:per_provider_timeout_s
        candidate
    in
    let pp_timeout = timeout_resolution.timeout_s in
    let liveness_mode = Cascade_attempt_liveness_config.current_mode () in
    let liveness_observer_attached =
      match liveness_mode with
      | Cascade_attempt_liveness_config.Off -> false
      | Cascade_attempt_liveness_config.Observe
      | Cascade_attempt_liveness_config.Enforce ->
        true
    in
    let attempt_watchdog_source =
      match liveness_mode, pp_timeout with
      | Cascade_attempt_liveness_config.Enforce, _ ->
        "liveness_observer_enforce"
      | Cascade_attempt_liveness_config.Observe, Some _ ->
        "legacy_outer_wall_observe_liveness"
      | Cascade_attempt_liveness_config.Observe, None ->
        "oas_max_execution_time_observe_liveness"
      | Cascade_attempt_liveness_config.Off, Some _ -> "legacy_outer_wall"
      | Cascade_attempt_liveness_config.Off, None -> "oas_max_execution_time"
    in
    let liveness_budget_source =
      if liveness_observer_attached then (
        let resolved_budget =
          Cascade_attempt_liveness_config.budget_for_candidate
            ~candidate_key:Cascade_attempt_liveness_config.runtime_candidate_key
        in
        Some
          (Cascade_attempt_liveness_config.budget_source_label
             resolved_budget.source))
      else
        None
    in
    let attempt_started_at = Mtime_clock.now () in
    let started_record =
      { started_provenance = provider_attempt_provenance
      ; started_is_last = is_last
      ; started_per_provider_timeout_s = pp_timeout
      ; started_attempt_timeout_source = timeout_resolution.source
      ; started_attempt_watchdog_source = attempt_watchdog_source
      ; started_liveness_mode =
          Cascade_attempt_liveness_config.mode_label liveness_mode
      ; started_liveness_budget_source = liveness_budget_source
      }
    in
    let provider_attempt_finished_emitted = ref false in
    let emit_provider_attempt_finished_once
          ~status
          ?oas_turn_count
          ~checkpoint_after_present
          ~response_model:_
          ~error
          ?exception_kind
          attempt_latency_ms
      =
      if not !provider_attempt_finished_emitted then (
        provider_attempt_finished_emitted := true;
        let finished_record =
          { finished_provenance = provider_attempt_provenance
          ; finished_status = status
          ; finished_latency_ms = attempt_latency_ms
          ; finished_checkpoint_after_present = checkpoint_after_present
          ; finished_error = error
          ; finished_exception_kind = exception_kind
          }
        in
        ctx.emit_runtime_manifest
          ~status
          ?oas_turn_count
          ~decision:
            (Keeper_runtime_manifest.with_clock_refs
               ~clock_refs:
                 (provider_attempt_clock_refs ctx
                    ~event:Keeper_runtime_manifest.Provider_attempt_finished
                    ~attempt_index
                    ~parent_event_id:
                      (match ctx.runtime_manifest_context with
                       | None -> ""
                       | Some manifest_ctx ->
                         provider_attempt_edge_id manifest_ctx
                           Keeper_runtime_manifest.Provider_attempt_started
                           attempt_index)
                    ~caused_by:"provider_attempt_started" ())
               (provider_attempt_finished_decision finished_record))
          Keeper_runtime_manifest.Provider_attempt_finished)
    in
    let record_attempt_terminal ~error attempt_latency_ms =
      let latency_ms =
        if Float.is_finite attempt_latency_ms && attempt_latency_ms >= 0.0
        then Some (int_of_float attempt_latency_ms)
        else None
      in
      Cascade_observation.record_attempt_terminal ctx.capture
        ~model_id:runtime_candidate_label ~latency_ms ~error
    in
    let attempt_with_admission =
      Keeper_turn_driver_admission.with_keeper_cascade_tier_admission
        ~tier_id:tier_admission_id
        ~admission_policy:ctx.tier_admission_policy
        (fun () ->
           Eio.Switch.run (fun provider_attempt_sw ->
        Option.iter
          (fun release -> Eio.Switch.on_release provider_attempt_sw release)
          capacity_release;
        ctx.emit_runtime_manifest
          ~status:"started"
          ~decision:
            (Keeper_runtime_manifest.with_clock_refs
               ~clock_refs:
                 (provider_attempt_clock_refs ctx
                    ~event:Keeper_runtime_manifest.Provider_attempt_started
                    ~attempt_index ())
               (provider_attempt_started_decision started_record))
          Keeper_runtime_manifest.Provider_attempt_started;
        Eio.Switch.on_release provider_attempt_sw (fun () ->
          if not !provider_attempt_finished_emitted then
            let attempt_latency_ms =
              (Int64.to_float (Mtime.Span.to_uint64_ns (Mtime.span attempt_started_at (Mtime_clock.now ()))) /. 1_000_000.)
            in
            Eio.Cancel.protect (fun () ->
              emit_provider_attempt_finished_once
                ~status:"cancelled"
                ~checkpoint_after_present:false
                ~response_model:`Null
                ~error:
                  (`String
                    "provider attempt scope released before completion; parent \
                     cancellation or outer timeout interrupted the attempt")
                ~exception_kind:"cancelled"
                attempt_latency_ms;
              record_attempt_terminal
                ~error:
                  (Some
                     "provider attempt scope released before completion; parent \
                      cancellation or outer timeout interrupted the attempt")
                attempt_latency_ms));
        match
          try_provider ctx
            ?resume_checkpoint
            ?per_provider_timeout_s:pp_timeout
            candidate
        with
        | result, checkpoint_after, liveness_success_sample ->
          let attempt_latency_ms =
            (Int64.to_float (Mtime.Span.to_uint64_ns (Mtime.span attempt_started_at (Mtime_clock.now ()))) /. 1_000_000.)
          in
          emit_provider_attempt_finished_once
            ~status:(provider_attempt_status_of_result result)
            ?oas_turn_count:
              (match result with
               | Ok run_result -> Some run_result.turns
               | Error _ -> None)
            ~checkpoint_after_present:(Option.is_some checkpoint_after)
            ~response_model:
              (match result with
               | Ok _ -> `Null
               | Error _ -> `Null)
            ~error:
              (match result with
               | Ok _ -> `Null
               | Error sdk_err -> `String (Agent_sdk.Error.to_string sdk_err))
            ?exception_kind:(provider_attempt_exception_kind_of_result result)
            attempt_latency_ms;
          record_attempt_terminal
            ~error:
              (match result with
               | Ok _ -> None
               | Error sdk_err -> Some (Agent_sdk.Error.to_string sdk_err))
            attempt_latency_ms;
          result, checkpoint_after, liveness_success_sample, attempt_latency_ms
        | exception exn ->
          let bt = Printexc.get_raw_backtrace () in
          let attempt_latency_ms =
            (Int64.to_float (Mtime.Span.to_uint64_ns (Mtime.span attempt_started_at (Mtime_clock.now ()))) /. 1_000_000.)
          in
          let status, error = provider_attempt_status_and_error_of_exception exn in
          emit_provider_attempt_finished_once
            ~status
            ~checkpoint_after_present:false
            ~response_model:`Null
            ~error:(`String error)
            ~exception_kind:status
            attempt_latency_ms;
          record_attempt_terminal ~error:(Some error) attempt_latency_ms;
          Printexc.raise_with_backtrace exn bt))
    in
    match attempt_with_admission with
    | Error signal ->
      Keeper_turn_driver_admission.release_client_capacity_quietly capacity_release;
      emit_tier_admission_blocked_manifest ctx signal;
      Keeper_turn_driver_admission.emit_cascade_tier_admission_signal_metric
        ~cascade_name:ctx.cascade_name signal;
      record_cascade_attempt ctx candidate ~outcome:(`Failure "tier_admission_full") ();
      Cascade_observation.record_fallback_event ctx.capture
        ~from_model:runtime_candidate_label
        ~to_model:runtime_candidate_label
        ~reason:"tier_admission_full";
      Log.Misc.info
        "[cascade-fallback] cascade %s: %s skipped because tier admission \
         %s is full, trying next"
        ctx.cascade_name
        runtime_candidate_label
        tier_admission_id;
      let capacity_detail =
        Printf.sprintf "tier admission %s is full" tier_admission_id
      in
      run ~on_success ?resume_checkpoint ?per_provider_timeout_s
        ~pre_dispatch_required_tool_rejections_rev
        ~last_capacity_backpressure:
          (Tier_admission, capacity_detail, None)
        ctx rest last_err
    | Ok (result, checkpoint_after, liveness_success_sample, attempt_latency_ms) ->
    let record_accepted_liveness_sample () =
      match liveness_success_sample with
      | None -> ()
      | Some (candidate_key, sample) ->
        Cascade_attempt_liveness_config.record_success_sample
          ~candidate_key
          sample
    in
    let next_resume = match checkpoint_after with
      | Some _ -> checkpoint_after
      | None -> resume_checkpoint
    in
    (match result with
    | Ok result when ctx.accept result.response ->
      ctx.record_provider_health_result candidate ~success:true ~http_status:None;
      record_accepted_liveness_sample ();
      Keeper_turn_driver_cascade_health.record_candidate_success
        candidate ~latency_ms:attempt_latency_ms result;
      let observation =
        Cascade_observation.cascade_observation_with_metrics
          ~cascade_name:ctx.error_cascade_name
          ?strategy:!(ctx.cascade_strategy_name_ref) ~configured_labels:ctx.configured_labels
          ~candidate_count:ctx.candidate_count
          ~selected_model_raw:(success_selected_model_raw candidate)
          ~capture:ctx.capture
        ~oas_internal_cascade_allowed:
          (Keeper_cascade_engine.allows_oas_internal_cascade ctx.cascade_engine)
        ()
      in
      let result = { result with cascade_observation = Some observation } in
              Cascade_observation.record_cascade ~keeper_name:ctx.keeper_name
                ~cascade_name:ctx.error_cascade_name
                ~outcome:`Success ~observation:(Some observation) ();
              record_cascade_attempt ctx candidate ~outcome:`Success ();
              on_success ~provider_key:(Cascade_runtime_candidate.health_key candidate);
              Ok result
    | Ok result ->
      let reason = "response rejected by accept" in
      Keeper_turn_driver_cascade_health.record_candidate_rejected candidate ~reason;
      let outcome = Cascade_fsm.Accept_rejected
        { response = result.response; reason } in
      (match Cascade_fsm.decide ~accept_on_exhaustion:true ~is_last outcome with
         | Cascade_fsm.Accept_on_exhaustion { response; _ } ->
         ctx.record_provider_health_result candidate ~success:true ~http_status:None;
         record_accepted_liveness_sample ();
         Keeper_turn_driver_cascade_health.record_candidate_success
           candidate ~latency_ms:attempt_latency_ms result;
         let observation =
           Cascade_observation.cascade_observation_with_metrics
             ~cascade_name:ctx.error_cascade_name
             ?strategy:!(ctx.cascade_strategy_name_ref) ~configured_labels:ctx.configured_labels
             ~candidate_count:ctx.candidate_count
             ~selected_model_raw:(success_selected_model_raw candidate)
             ~capture:ctx.capture
        ~oas_internal_cascade_allowed:
          (Keeper_cascade_engine.allows_oas_internal_cascade ctx.cascade_engine)
        ()
         in
         let result = { result with cascade_observation = Some observation } in
                 Cascade_observation.record_cascade ~keeper_name:ctx.keeper_name
                   ~cascade_name:ctx.error_cascade_name
                   ~outcome:`Success ~observation:(Some observation) ();
                 record_cascade_attempt ctx candidate ~outcome:`Success ();
                 on_success ~provider_key:(Cascade_runtime_candidate.health_key candidate);
                 Ok result
       | Cascade_fsm.Try_next { last_err = new_err } ->
         record_candidate_health_rejected candidate ~reason;
         Log.Misc.info "[cascade-fallback] cascade %s: accept rejected %s (%s), trying next"
           ctx.cascade_name runtime_candidate_label reason;
         Cascade_observation.record_fallback_event ctx.capture
           ~from_model:runtime_candidate_label ~to_model:runtime_candidate_label ~reason;
         run
           ~pre_dispatch_required_tool_rejections_rev
           ?resume_checkpoint
           ctx

           (ctx.filter_provider_health_fail_open rest)
           new_err
       | Cascade_fsm.Exhausted _ ->
         record_candidate_health_rejected candidate ~reason;
         let observation =
           Cascade_observation.cascade_observation_with_metrics
             ~cascade_name:ctx.error_cascade_name
             ?strategy:!(ctx.cascade_strategy_name_ref) ~configured_labels:ctx.configured_labels
             ~candidate_count:ctx.candidate_count ~selected_model_raw:ctx.error_selected_model_raw
             ~capture:ctx.capture
        ~oas_internal_cascade_allowed:
          (Keeper_cascade_engine.allows_oas_internal_cascade ctx.cascade_engine)
        ()
         in
         Cascade_observation.record_cascade ~keeper_name:ctx.keeper_name
           ~cascade_name:ctx.error_cascade_name
           ~outcome:`Rejected ~observation:(Some observation) ();
         Log.Misc.error
           "cascade %s exhausted: all tiers rejected by accept predicate \
            (last runtime=%s, reason=%s)"
           ctx.cascade_name runtime_candidate_label reason;
         Error
           (sdk_error_of_masc_internal_error
              (Accept_rejected
                 {
                   scope = ctx.cascade_name;
                   model = Some runtime_candidate_label;
                   reason;
                 }))
         | Cascade_fsm.Accept _resp ->
         Cascade_metrics.on_cascade_invariant_violation ();
         Log.Misc.warn
           "cascade %s: unexpected Accept in Accept_rejected branch (runtime=%s)"
           ctx.cascade_name runtime_candidate_label;
         ctx.record_provider_health_result candidate ~success:true ~http_status:None;
         record_accepted_liveness_sample ();
         Keeper_turn_driver_cascade_health.record_candidate_success
           candidate ~latency_ms:attempt_latency_ms result;
         let observation =
           Cascade_observation.cascade_observation_with_metrics
             ~cascade_name:ctx.error_cascade_name
             ?strategy:!(ctx.cascade_strategy_name_ref) ~configured_labels:ctx.configured_labels
             ~candidate_count:ctx.candidate_count
             ~selected_model_raw:(success_selected_model_raw candidate)
             ~capture:ctx.capture
        ~oas_internal_cascade_allowed:
          (Keeper_cascade_engine.allows_oas_internal_cascade ctx.cascade_engine)
        ()
         in
         let result = { result with cascade_observation = Some observation } in
                 Cascade_observation.record_cascade ~keeper_name:ctx.keeper_name
                   ~cascade_name:ctx.error_cascade_name
                   ~outcome:`Success ~observation:(Some observation) ();
                 record_cascade_attempt ctx candidate ~outcome:`Success ();
                 on_success ~provider_key:(Cascade_runtime_candidate.health_key candidate);
                 Ok result)
    | Error sdk_err ->
      let sdk_err =
        match
          sdk_error_to_resumable_cli_session
            ~cascade_name:ctx.error_cascade_name sdk_err
        with
        | Some err -> err
        | None -> sdk_err
      in
      let err_str = Agent_sdk.Error.to_string sdk_err in
      record_candidate_health_error candidate sdk_err;
      let provider_error =
        emit_sdk_provider_error_metric
          ~cascade_name:ctx.error_cascade_name
          ~provider:runtime_candidate_label
          sdk_err
      in
      record_cascade_attempt ctx candidate
        ?http_status:(Keeper_turn_driver_cascade_health.http_status_of_provider_error provider_error)
        ~outcome:(`Failure (Agent_sdk.Error.to_string sdk_err))
        ();
      Option.iter (ctx.record_provider_health_error candidate) provider_error;
      let _ = err_str in
      let cascade_outcome = sdk_error_to_cascade_outcome sdk_err in
      Option.iter
        (fun _ -> Keeper_turn_driver_cascade_health.record_candidate_error candidate sdk_err)
        cascade_outcome;
      (match cascade_outcome with
       | Some outcome ->
         let decision =
           if sdk_error_is_hard_quota sdk_err then
             let last_err = match outcome with
               | Cascade_fsm.Call_err e -> Some e
               | Cascade_fsm.Call_ok _
               | Cascade_fsm.Accept_rejected _ -> None
             in
             Cascade_fsm.Exhausted { last_err }
           else
             (* accept_on_exhaustion is irrelevant for Call_err outcomes
                (decide only consults it on Accept_rejected). *)
             Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last outcome
         in
         (match decision with
          | Cascade_fsm.Try_next { last_err = new_err } ->
            let class_label =
              match sdk_error_cascade_fallback_class sdk_err with
              | Some class_name -> Printf.sprintf "[%s] " class_name
              | None -> ""
            in
            if sdk_error_is_max_turns_exceeded sdk_err then
              Log.Misc.warn
                "[cascade-fallback] cascade %s: %s failed (%s%s), trying \
                 next [sunk cost; see #10982]"
                ctx.cascade_name runtime_candidate_label class_label
                (Agent_sdk.Error.to_string sdk_err)
            else
              Log.Misc.info
                "[cascade-fallback] cascade %s: %s failed (%s%s), trying next"
                ctx.cascade_name runtime_candidate_label class_label
                (Agent_sdk.Error.to_string sdk_err);
            Cascade_observation.record_fallback_event ctx.capture
              ~from_model:runtime_candidate_label ~to_model:runtime_candidate_label
              ~reason:(class_label ^ Agent_sdk.Error.to_string sdk_err);
            let retry_resume_checkpoint =
              if sdk_error_is_server_rejected_parse_error sdk_err then (
                Log.Misc.info
                  "[cascade-fallback] cascade %s: %s server rejected the \
                   resumed request body; dropping resume checkpoint for \
                   next provider"
                  ctx.cascade_name runtime_candidate_label;
                None)
              else
                next_resume
            in
            let last_capacity_source =
              Option.bind new_err Keeper_turn_driver_backpressure.capacity_backpressure_source_of_http_error
            in
            run
              ~pre_dispatch_required_tool_rejections_rev
              ?resume_checkpoint:retry_resume_checkpoint
              ?last_capacity_source
              ctx
              (ctx.filter_provider_health_fail_open rest)
              new_err
          | Cascade_fsm.Exhausted _ ->
            let observation =
              Cascade_observation.cascade_observation_with_metrics
                ~cascade_name:ctx.error_cascade_name
                ?strategy:!(ctx.cascade_strategy_name_ref) ~configured_labels:ctx.configured_labels
                ~candidate_count:ctx.candidate_count
                ~selected_model_raw:ctx.error_selected_model_raw ~capture:ctx.capture ()
            in
            Cascade_observation.record_cascade ~keeper_name:ctx.keeper_name
              ~cascade_name:ctx.error_cascade_name
              ~outcome:`Failure ~observation:(Some observation) ();
            let log =
              if sdk_error_is_required_tool_contract_violation sdk_err then
                Log.Misc.warn
              else Log.Misc.error
            in
            log "cascade %s exhausted: all tiers failed (last runtime=%s, error=%s)"
              ctx.cascade_name runtime_candidate_label (Agent_sdk.Error.to_string sdk_err);
            Error
              (Option.value
                 (capacity_backpressure_of_sdk_error ctx sdk_err)
                 ~default:sdk_err)
          | Cascade_fsm.Accept _
          | Cascade_fsm.Accept_on_exhaustion _ -> Error sdk_err)
       | None ->
         let observation =
           Cascade_observation.cascade_observation_with_metrics
             ~cascade_name:ctx.error_cascade_name
             ?strategy:!(ctx.cascade_strategy_name_ref) ~configured_labels:ctx.configured_labels
             ~candidate_count:ctx.candidate_count
             ~selected_model_raw:ctx.error_selected_model_raw ~capture:ctx.capture ()
         in
         Cascade_observation.record_cascade ~keeper_name:ctx.keeper_name
           ~cascade_name:ctx.error_cascade_name
           ~outcome:`Failure ~observation:(Some observation) ();
         Log.Misc.error "cascade %s: non-cascadable error from %s: %s"
           ctx.cascade_name runtime_candidate_label (Agent_sdk.Error.to_string sdk_err);
         Error sdk_err)))
