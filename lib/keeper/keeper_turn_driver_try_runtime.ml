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
  ; wait_timeout_sec : float option
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
      | Keeper_internal_error.Admission_queue_timeout _
      | Keeper_internal_error.Admission_queue_rejected _
      | Keeper_internal_error.Turn_timeout _
      | Keeper_internal_error.Provider_timeout _
      | Keeper_internal_error.Max_tokens_ceiling_violation _
      | Keeper_internal_error.Ambiguous_post_commit _
      | Keeper_internal_error.Internal_unhandled_exception _
      | Keeper_internal_error.Internal_bridge_exception _
      | Keeper_internal_error.Internal_contract_rejected _ )
  | None ->
    false

let accept_no_progress_should_try_next err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some err ->
    Keeper_internal_error.accept_rejection_has_no_progress_retry_hint err
  | None -> false

let accept_no_progress_read_only_should_try_next err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some err ->
    Keeper_internal_error.accept_rejection_has_read_only_no_progress_retry_hint
      err
  | None -> false

let accept_no_progress_retry_kind err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some err -> Keeper_internal_error.accept_no_progress_retry_kind err
  | None -> None

let accept_rejected_result_should_try_next ~is_last err =
  (not is_last) && accept_no_progress_should_try_next err

let checkpoint_for_accept_rejected_retry ~resume_checkpoint ~checkpoint_after err =
  match accept_no_progress_retry_kind err with
  | Some (`Empty_no_progress | `Thinking_only_no_progress) -> resume_checkpoint
  | Some `Read_only_no_progress -> checkpoint_after
  | None -> checkpoint_after

let http_status_of_http_error = function
  | Some (Llm_provider.Http_client.HttpError { code; _ }) -> Some code
  | _ -> None

let sdk_error_of_exhausted last_err =
  Agent_sdk.Error.Internal (Runtime_attempt_fsm.to_user_message last_err)

let sdk_error_of_nonretryable_attempt_error ~original_error last_err =
  if is_accept_rejected_sdk_error original_error
  then original_error
  else sdk_error_of_exhausted (Some last_err)

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
      ?resume_checkpoint
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
    , ctx.wait_timeout_sec
    , ctx.turn_deadline )
  in
  let rec loop resume_checkpoint last_err = function
    | [] -> Error (sdk_error_of_exhausted last_err)
    | candidate :: rest ->
      let is_last = rest = [] in
      maybe_mark_provider_attempt_started ctx;
      emit_attempt_started ctx candidate ~is_last ~per_provider_timeout_s;
      let started_at = Mtime_clock.now () in
      let result, checkpoint_after, _success_sample =
        Keeper_turn_driver_try_provider.run_try_provider
          ctx.try_provider_ctx
          ?resume_checkpoint
          ?per_provider_timeout_s
          candidate
      in
      let latency_ms =
        emit_attempt_finished ctx candidate ~started_at result checkpoint_after
      in
      (match result with
       | Ok run_result when ctx.accept run_result.Runtime_agent.response ->
         Keeper_turn_driver_provider_attempt.record_candidate_health_success
           ~keeper_name:ctx.keeper_name
           candidate
           ~latency_ms;
         ctx.record_provider_health_result candidate ~success:true ~http_status:None;
         on_success ~provider_key:(Runtime_candidate.health_key candidate);
         Ok run_result
       | Ok run_result ->
         let last_tool_context =
           Keeper_turn_driver_try_provider.accept_rejection_context_of_run_result
             ~initial_messages:ctx.try_provider_ctx.initial_messages
             run_result
         in
         let err =
           Keeper_turn_driver_try_provider.accept_rejected_error
             ~last_tool_context
             ~runtime_id:ctx.error_runtime_id
             ~response:run_result.Runtime_agent.response
         in
         let reason =
           match Keeper_internal_error.classify_masc_internal_error err with
           | Some (Keeper_internal_error.Accept_rejected { reason; _ }) -> reason
           | _ -> Agent_sdk.Error.to_string err
         in
         Keeper_turn_driver_provider_attempt.record_candidate_health_rejected
           ~keeper_name:ctx.keeper_name
           candidate
           ~reason;
         if accept_rejected_result_should_try_next ~is_last err
         then
           let checkpoint_for_retry =
             checkpoint_for_accept_rejected_retry
               ~resume_checkpoint
               ~checkpoint_after
               err
           in
           let next_last_err =
             match sdk_error_to_http_error err with
             | Some http_err -> Some http_err
             | None -> last_err
           in
           loop checkpoint_for_retry next_last_err rest
         else Error err
       | Error err ->
         Keeper_turn_driver_provider_attempt.record_candidate_health_error
           ~keeper_name:ctx.keeper_name
           candidate
           err;
         let original_error = err in
         let http_err = sdk_error_to_http_error err in
         ctx.record_provider_health_result
           candidate
           ~success:false
           ~http_status:(http_status_of_http_error http_err);
         match http_err with
         | Some http_err
           when (not is_last)
                && (Runtime_attempt_fsm.should_try_next http_err
                    || accept_no_progress_should_try_next original_error)
           ->
           loop checkpoint_after (Some http_err) rest
         | Some http_err ->
           Error
             (sdk_error_of_nonretryable_attempt_error ~original_error http_err)
         | None ->
           if is_last then Error err else loop checkpoint_after last_err rest)
  in
  loop resume_checkpoint last_err candidates

module For_testing = struct
  let accept_no_progress_should_try_next = accept_no_progress_should_try_next

  let accept_no_progress_read_only_should_try_next =
    accept_no_progress_read_only_should_try_next

  let accept_rejected_result_should_try_next =
    accept_rejected_result_should_try_next
end
