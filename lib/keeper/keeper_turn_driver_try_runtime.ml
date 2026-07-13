(** Linear runtime-provider attempt loop for keeper turns.

    The deleted runtime scheduler used to own the outer fallback loop.  Runtime
    dispatch now keeps the only behavior still needed here: try the resolved
    provider candidates in order until one is accepted or the list is exhausted.
*)

type try_runtime_ctx =
  { runtime_id : string
  ; error_runtime_id : string
  ; keeper_name : string
  ; name : string
  ; candidate_count : int
  ; configured_labels : string list
  ; capture : Runtime_observation.runtime_metrics_capture
  ; runtime_strategy_name_ref : string option ref
  ; try_provider_ctx : Keeper_turn_driver_try_provider.try_provider_ctx
  ; runtime_mcp_policy : Llm_provider.Llm_transport.runtime_mcp_policy option
  ; tools : Agent_sdk.Tool.t list
  ; required_lane_provider_rejections : Keeper_internal_error.provider_rejection list
  ; emit_runtime_manifest :
      ?status:string ->
      ?decision:Yojson.Safe.t ->
      ?oas_turn_count:int ->
      Keeper_runtime_manifest.event_kind ->
      unit
  ; runtime_manifest_context : Keeper_runtime_manifest.turn_context option
  ; runtime_manifest_append : (Keeper_runtime_manifest.t -> unit) option
  ; turn_start : Mtime.t
  ; seq_ref : int ref
  ; health_cooldown_fail_open : bool
  ; base_path : string option
  ; session_id : string option
  ; accept : Agent_sdk_response.api_response -> bool
  ; error_runtime_id_for_backpressure : string
  ; record_provider_health_result :
      Runtime_candidate.t -> success:bool -> http_status:int option -> unit
  ; filter_provider_health_fail_open : Runtime_candidate.t list -> Runtime_candidate.t list
  ; turn_deadline : Runtime_deadline.t option
  }

let sdk_error_to_http_error err =
  match Keeper_runtime_attempt.sdk_error_to_runtime_outcome err with
  | Some (Runtime_attempt_fsm.Call_err http_err) -> Some http_err
  | Some (Runtime_attempt_fsm.Accept_rejected { reason; _ }) ->
    Some (Llm_provider.Http_client.AcceptRejected { reason })
  | Some (Runtime_attempt_fsm.Call_ok _) | None -> None

let is_accept_rejected_sdk_error err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some (Keeper_internal_error.Accept_rejected _) -> true
  | Some
      ( Keeper_internal_error.Runtime_exhausted _
      | Keeper_internal_error.Capacity_backpressure _
      | Keeper_internal_error.Resumable_cli_session _
      | Keeper_internal_error.Turn_timeout _
      | Keeper_internal_error.Provider_timeout _
      | Keeper_internal_error.Internal_unhandled_exception _
      | Keeper_internal_error.Internal_bridge_exception _
      | Keeper_internal_error.Internal_contract_rejected _
      | Keeper_internal_error.Receipt_persistence_failed _ )
  | None ->
    false

let accept_no_progress_should_try_next err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some err ->
    Keeper_internal_error.accept_rejection_has_no_progress_retry_hint err
  | None -> false

let accept_no_progress_retry_kind err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some err -> Keeper_internal_error.accept_no_progress_retry_kind err
  | None -> None

(* RFC-0271 §4.1 [Retry_no_thinking] gate: a [Thinking_only_no_progress]
   rejection is retried once on the SAME candidate with thinking forced off,
   provided the rejected attempt had thinking enabled and this turn has not
   already spent its single re-shape. [Empty] rejections and
   thinking-already-off attempts are not re-shaped (nothing to change). *)
let should_retry_no_thinking ~recovered ~enable_thinking ~retry_kind =
  let thinking_was_enabled =
    match enable_thinking with
    | Some false -> false
    | Some true | None -> true
  in
  let is_thinking_only =
    match retry_kind with
    | Some `Thinking_only_no_progress -> true
    | Some `Empty_no_progress | None -> false
  in
  (not recovered) && is_thinking_only && thinking_was_enabled

let accept_rejected_result_should_try_next ~is_last err =
  (not is_last) && accept_no_progress_should_try_next err

let same_run_retry_has_input_authority ctx =
  Keeper_turn_driver_try_provider.same_run_retry_allowed
    ctx.try_provider_ctx.checkpoint_stage_observed

let report_continuation_required ctx =
  Log.Keeper.info
    ~keeper_name:ctx.keeper_name
    "%s: same-run provider retry deferred after a typed OAS checkpoint stage; \
     current OAS contract cannot continue without admitting the input again"
    ctx.keeper_name

let http_status_of_http_error = function
  | Some (Llm_provider.Http_client.HttpError { code; _ }) -> Some code
  | _ -> None

(* KLV-DNS (RFC-keeper-liveness-ssot §6): classify the last transport error
   observed before candidate exhaustion into a typed
   [Keeper_internal_error.runtime_exhaustion_reason]. Before this, exhaustion
   always produced a plain [Agent_sdk.Error.Internal <free-text message>]
   (see [Runtime_attempt_fsm.to_user_message]), so
   [Keeper_error_classify.is_runtime_exhausted_error] — the sole gate for
   [record_failure_observation]'s typed Turn_consecutive_failures accounting
   could not distinguish DNS/network exhaustion. The classification remains
   evidence for fallback and diagnostics; it never rewrites Keeper lifecycle.

   Capacity-shaped failures are intentionally split by source here:
   [ProviderFailure { kind = Capacity_exhausted; _ }] maps to the typed,
   retryable [Capacity_exhausted] runtime exhaustion reason, while transport
   [NetworkError { kind = Local_resource_exhaustion; _ }] remains bucketed
   with [All_providers_failed]. Wiring the dedicated backpressure envelope
   ([Keeper_turn_driver_backpressure], currently dead — no caller constructs
   [Capacity_backpressure] either) is a separate, larger fix. *)
let runtime_exhaustion_reason_of_http_error
  : Llm_provider.Http_client.http_error option
    -> Keeper_internal_error.runtime_exhaustion_reason
  = function
  | None -> Keeper_internal_error.No_providers_available
  | Some (Llm_provider.Http_client.NetworkError { kind = Llm_provider.Http_client.Dns_failure; _ }) ->
    Keeper_internal_error.Dns_failure
  | Some (Llm_provider.Http_client.NetworkError { kind = Llm_provider.Http_client.Connection_refused; _ }) ->
    Keeper_internal_error.Connection_refused
  | Some
      (Llm_provider.Http_client.NetworkError
         { kind =
             ( Llm_provider.Http_client.Tls_error
             | Llm_provider.Http_client.Timeout
             | Llm_provider.Http_client.Local_resource_exhaustion
             | Llm_provider.Http_client.End_of_file
             | Llm_provider.Http_client.Unknown )
         ; _
         }) ->
    (* Transient at the transport layer (matches
       [Runtime_attempt_fsm.should_try_next]'s [true] for [NetworkError]);
       no dedicated reason exists, so bucket with the retryable
       all-candidates-failed reason rather than the non-retryable
       [Other_detail]. *)
    Keeper_internal_error.All_providers_failed
  | Some (Llm_provider.Http_client.TimeoutError _) ->
    Keeper_internal_error.All_providers_failed
  | Some (Llm_provider.Http_client.HttpError _ as http_err)
    when Runtime_attempt_fsm.should_try_next http_err ->
    Keeper_internal_error.All_providers_failed
  | Some (Llm_provider.Http_client.HttpError { code; _ }) ->
    Keeper_internal_error.Other_detail (Printf.sprintf "HTTP %d" code)
  | Some (Llm_provider.Http_client.AcceptRejected { reason }) ->
    (* Defensive only: [sdk_error_of_nonretryable_attempt_error] returns
       [original_error] directly whenever [is_accept_rejected_sdk_error]
       holds, so a properly-classified accept-rejection never reaches
       here as [last_err]. *)
    Keeper_internal_error.Other_detail reason
  | Some (Llm_provider.Http_client.ProviderTerminal { kind = Llm_provider.Http_client.Max_turns _; _ }) ->
    Keeper_internal_error.Max_turns_exceeded
  | Some
      (Llm_provider.Http_client.ProviderTerminal
         { kind = Llm_provider.Http_client.Session_conflict; _ }) ->
    (* Preserve the closed provider kind through MASC policy and persistence;
       no provider prose is parsed or collapsed into [Other_detail]. *)
    Keeper_internal_error.Session_conflict
  | Some (Llm_provider.Http_client.ProviderTerminal { kind = Llm_provider.Http_client.Other _; message }) ->
    Keeper_internal_error.Other_detail message
  | Some
      (Llm_provider.Http_client.ProviderFailure
         { kind = Llm_provider.Http_client.Capacity_exhausted _; _ }) ->
    Keeper_internal_error.Capacity_exhausted
  | Some (Llm_provider.Http_client.ProviderFailure { kind; message }) ->
    Keeper_internal_error.Other_detail
      (Llm_provider.Http_client.provider_failure_to_string ~kind ~message)

let sdk_error_of_exhausted ~runtime_id last_err =
  Keeper_internal_error.sdk_error_of_masc_internal_error
    (Keeper_internal_error.Runtime_exhausted
       { runtime_id; reason = runtime_exhaustion_reason_of_http_error last_err })

let sdk_error_of_nonretryable_attempt_error ~runtime_id ~original_error last_err =
  if is_accept_rejected_sdk_error original_error
  then original_error
  else sdk_error_of_exhausted ~runtime_id (Some last_err)

let maybe_mark_provider_attempt_started ctx =
  match ctx.base_path, String.trim ctx.keeper_name with
  | Some base_path, keeper_name when keeper_name <> "" ->
    Keeper_registry.mark_turn_provider_attempt_started ~base_path keeper_name
  | _ -> ()

let emit_attempt_started ctx candidate ~is_last ~per_provider_timeout_s =
  let timeout =
    Runtime_candidate.effective_attempt_timeout_resolution
      ~is_last
      ~configured_timeout_s:per_provider_timeout_s
      candidate
  in
  ctx.emit_runtime_manifest
    ~status:"started"
    ~decision:
      (Keeper_turn_driver_provider_attempt.provider_attempt_started_decision
         { started_provenance =
             Keeper_turn_driver_provider_attempt.base_provider_attempt_provenance
         ; started_is_last = is_last
         ; started_per_provider_timeout_s = timeout.timeout_s
         ; started_attempt_timeout_source = timeout.source
         ; started_attempt_watchdog_source = "runtime_provider_attempt"
         })
    Keeper_runtime_manifest.Provider_attempt_started

let emit_attempt_finished ctx candidate ~started_at result checkpoint_after =
  let latency_ms =
    let ns =
      Mtime.Span.to_uint64_ns (Mtime.span started_at (Mtime_clock.now ()))
    in
    Int64.to_float ns /. 1_000_000.
  in
  let status =
    Keeper_turn_driver_provider_attempt.provider_attempt_status_of_result result
  in
  let error =
    match result with
    | Ok _ -> `Null
    | Error err -> `String (Agent_sdk.Error.to_string err)
  in
  ctx.emit_runtime_manifest
    ~status
    ~decision:
      (Keeper_turn_driver_provider_attempt.provider_attempt_finished_decision
         { finished_provenance =
             Keeper_turn_driver_provider_attempt.base_provider_attempt_provenance
         ; finished_status = status
         ; finished_latency_ms = latency_ms
         ; finished_checkpoint_after_present = Option.is_some checkpoint_after
         ; finished_error = error
         ; finished_exception_kind =
             Keeper_turn_driver_provider_attempt
             .provider_attempt_exception_kind_of_result
               result
         })
    Keeper_runtime_manifest.Provider_attempt_finished;
  latency_ms

let run
      ?(on_success = fun ~provider_key:_ -> ())
      ?(pre_dispatch_required_tool_rejections_rev = [])
      ?per_provider_timeout_s
      ?last_capacity_source:_
      ?last_capacity_backpressure:_
      ctx
      candidates
      last_err
  =
  let _ =
    ( pre_dispatch_required_tool_rejections_rev
    , ctx.candidate_count
    , ctx.configured_labels
    , ctx.capture
    , ctx.runtime_mcp_policy
    , ctx.tools
    , ctx.required_lane_provider_rejections
    , ctx.runtime_manifest_context
    , ctx.runtime_manifest_append
    , ctx.turn_start
    , ctx.seq_ref
    , ctx.health_cooldown_fail_open
    , ctx.session_id
    , ctx.error_runtime_id_for_backpressure
    , ctx.filter_provider_health_fail_open
    , ctx.turn_deadline )
  in
  let rec loop last_err recovered_no_thinking = function
    | [] -> Error (sdk_error_of_exhausted ~runtime_id:ctx.error_runtime_id last_err)
    | candidate :: rest ->
      let is_last = rest = [] in
      let record_attempt_success run_result =
        ctx.record_provider_health_result candidate ~success:true ~http_status:None;
        on_success ~provider_key:(Runtime_candidate.health_key candidate);
        Ok run_result
      in
      maybe_mark_provider_attempt_started ctx;
      emit_attempt_started ctx candidate ~is_last ~per_provider_timeout_s;
      let started_at = Mtime_clock.now () in
      let result, checkpoint_after, _success_sample =
        Keeper_turn_driver_try_provider.run_try_provider
          ctx.try_provider_ctx
          ?per_provider_timeout_s
          candidate
      in
      let _latency_ms =
        emit_attempt_finished ctx candidate ~started_at result checkpoint_after
      in
      (match result with
       | Ok run_result when ctx.accept run_result.Runtime_agent.response ->
         record_attempt_success run_result
       | Ok run_result ->
         let err =
           Keeper_turn_driver_try_provider.accept_rejected_error
             ~runtime_id:ctx.error_runtime_id
             ~response:run_result.Runtime_agent.response
         in
         let try_next_or_error err ~recovered =
           if
             accept_rejected_result_should_try_next ~is_last err
             && same_run_retry_has_input_authority ctx
           then
             let next_last_err =
               match sdk_error_to_http_error err with
               | Some http_err -> Some http_err
               | None -> last_err
             in
             loop next_last_err recovered rest
           else (
             if not (same_run_retry_has_input_authority ctx)
             then report_continuation_required ctx;
             Error err)
         in
         (* RFC-0271 §4.1 [Retry_no_thinking]: a [Thinking_only_no_progress]
            rejection on a thinking-enabled attempt gets ONE same-candidate retry
            with thinking forced off, before the (existing) reroute to the next
            candidate. This is the cheap deterministic re-shape that avoids a full
            reroute to a more expensive lane when the model merely over-thought.
            Bounded to once per turn via [recovered_no_thinking]. *)
         if
           should_retry_no_thinking
             ~recovered:recovered_no_thinking
             ~enable_thinking:ctx.try_provider_ctx.enable_thinking
             ~retry_kind:(accept_no_progress_retry_kind err)
           && same_run_retry_has_input_authority ctx
         then begin
           (* Mark progress so the RFC-0012 mid-turn watchdog does not kill the
              recovery attempt as no-progress (RFC-0271 §4.3). *)
           maybe_mark_provider_attempt_started ctx;
           emit_attempt_started ctx candidate ~is_last ~per_provider_timeout_s;
           let retry_started_at = Mtime_clock.now () in
           let retry_result, retry_checkpoint_after, _retry_sample =
             Keeper_turn_driver_try_provider.run_try_provider
               ctx.try_provider_ctx
               ~enable_thinking_override:false
               ?per_provider_timeout_s
               candidate
           in
           ignore
             (emit_attempt_finished
                ctx
                candidate
                ~started_at:retry_started_at
                retry_result
                retry_checkpoint_after);
           (match retry_result with
            | Ok retry_run when ctx.accept retry_run.Runtime_agent.response ->
              record_attempt_success retry_run
            | Ok _ | Error _ ->
              try_next_or_error
                err
                ~recovered:true)
         end
         else
           try_next_or_error
             err
             ~recovered:recovered_no_thinking
       | Error err ->
         let original_error = err in
         let http_err = sdk_error_to_http_error err in
         ctx.record_provider_health_result
           candidate
           ~success:false
           ~http_status:(http_status_of_http_error http_err);
         let same_run_retry_has_input_authority =
           same_run_retry_has_input_authority ctx
         in
         if not same_run_retry_has_input_authority
         then report_continuation_required ctx;
         match http_err with
         | Some http_err
           when (not is_last)
                && same_run_retry_has_input_authority
                && (Runtime_attempt_fsm.should_try_next http_err
                    || accept_no_progress_should_try_next original_error)
           ->
           loop (Some http_err) recovered_no_thinking rest
         | Some http_err ->
           Error
             (sdk_error_of_nonretryable_attempt_error
                ~runtime_id:ctx.error_runtime_id
                ~original_error
                http_err)
         | None ->
           if is_last || not same_run_retry_has_input_authority
           then Error err
           else
             loop last_err recovered_no_thinking rest)
  in
  loop last_err false candidates

module For_testing = struct
  let accept_no_progress_should_try_next = accept_no_progress_should_try_next
  let should_retry_no_thinking = should_retry_no_thinking

  let accept_rejected_result_should_try_next =
    accept_rejected_result_should_try_next

  let runtime_exhaustion_reason_of_http_error =
    runtime_exhaustion_reason_of_http_error

  let sdk_error_of_exhausted = sdk_error_of_exhausted
end
