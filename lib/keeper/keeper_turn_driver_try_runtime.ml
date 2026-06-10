(** Linear runtime-provider attempt loop for keeper turns.

    The deleted runtime scheduler used to own the outer fallback loop.  Runtime
    dispatch now keeps the only behavior still needed here: try the resolved
    provider candidates in order until one is accepted or the list is exhausted.

    Track A (task-708): cascade health_filtered_candidate_count=0 fallback with
    least-recently-failed (LRF) re-probe.  When all candidates are exhausted,
    [lrf_fallback_candidates] is retried once. *)

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
  ; lrf_fallback_candidates : Runtime_candidate.t list option
      (** Track A (task-708): least-recently-failed candidates to retry once
          when the primary candidate list is exhausted. *)
  }

let sdk_error_to_http_error err =
  match Keeper_runtime_attempt.sdk_error_to_runtime_outcome err with
  | Some (Runtime_attempt_fsm.Call_err http_err) -> Some http_err
  | Some (Runtime_attempt_fsm.Accept_rejected { reason; _ }) ->
    Some (Llm_provider.Http_client.AcceptRejected { reason })
  | Some (Runtime_attempt_fsm.Call_ok _) | None -> None

let http_status_of_http_error = function
  | Some (Llm_provider.Http_client.HttpError { code; _ }) -> Some code
  | _ -> None

let sdk_error_of_exhausted last_err =
  Agent_sdk.Error.Internal (Runtime_attempt_fsm.to_user_message last_err)

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
  let http_status =
    let open Keeper_runtime_attempt in
    match result with
    | Ok _ -> None
    | Error err ->
      (match sdk_error_to_http_error err with
       | Some (Llm_provider.Http_client.HttpError { code; _ }) -> Some code
       | Some (Llm_provider.Http_client.AcceptRejected _) -> None
       | Some (Llm_provider.Http_client.Forbidden _) -> Some 403
       | Some (Llm_provider.Http_client.RateLimited) -> Some 429
       | Some (Llm_provider.Http_client.Overloaded _) -> Some 429
       | None -> None)
  in
  ctx.emit_runtime_manifest
    ~status
    ?http_status
    ~decision:
      (Keeper_turn_driver_provider_attempt.provider_attempt_finished_decision
         { finished_latency_ms = latency_ms
         ; finished_fatal = Option.is_none http_status
         })
    Keeper_runtime_manifest.Provider_attempt_finished;
  latency_ms

let on_success ctx =
  match ctx.base_path, String.trim ctx.keeper_name with
  | Some base_path, keeper_name when keeper_name <> "" ->
    Keeper_registry.mark_turn_provider_attempt_stopped ~base_path keeper_name
  | _ -> ()

let record_health_and_backpressure ctx candidate ?http_status http_err =
  ctx.record_provider_health_result candidate ~success:false ?http_status;
  match http_err with
  | Some err ->
    Backpressure_constraint_solver.record_unavailable_runtime_provider
      ~ctx:ctx.error_runtime_id_for_backpressure
      err
  | None -> ()

let run ~rvm:(type rvm) ~per_provider_timeout_s (ctx : rvm try_runtime_ctx)
  : (Runtime_agent.runtime_result * Runtime_agent.checkpoint option,
     Keeper_internal_error.t) result =
  let on_success = on_success ctx in
  let candidates =
    let candidates =
      List.filter
        (Keeper_turn_driver_provider_attempt.accept_when_not_alive)
        ctx.candidates
    in
    Keeper_turn_driver_helpers.fail_open_health_filtered_candidates
      ~health_tracker:Keeper_preflight_health_tracker.global
      ~provider_key_of:Runtime_candidate.health_key
      ~tool_filtered_candidates:candidates
      ~health_filtered_candidates:
        (ctx.filter_provider_health_fail_open candidates)
  in
  let rec loop resume_checkpoint last_err lrf_attempted = function
    | [] ->
      (* Track A: retry once with LRF fallback before giving up *)
      (match ctx.lrf_fallback_candidates, lrf_attempted with
       | Some (fallback :: _), false ->
         loop resume_checkpoint last_err true [fallback]
       | _ ->
         Error (sdk_error_of_exhausted last_err))
    | candidate :: rest ->
      let is_last =
        match rest, ctx.lrf_fallback_candidates, lrf_attempted with
        | [], None, _ | [], _, true -> true
        | [] , Some _, false -> false
        | _ -> false
      in
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
         on_success ();
         Ok run_result
       | Ok run_result ->
         let reason = "accept predicate rejected runtime response" in
         Keeper_turn_driver_provider_attempt.record_candidate_health_rejected
           ~keeper_name:ctx.keeper_name
           candidate
           ~reason;
         let last_err =
           Some (Llm_provider.Http_client.AcceptRejected { reason })
         in
         if is_last
         then
           (match ctx.lrf_fallback_candidates, lrf_attempted with
            | Some (fallback :: _), false ->
              loop checkpoint_after (Some (sdk_error_of_exhausted (Some last_err))) true [fallback]
            | _ ->
              Error (sdk_error_of_exhausted (Some last_err)))
         else loop checkpoint_after (Some last_err) lrf_attempted rest
       | Error err ->
         Keeper_turn_driver_provider_attempt.record_candidate_health_error
           ~keeper_name:ctx.keeper_name
           candidate
           err;
         let http_err = sdk_error_to_http_error err in
         ctx.record_provider_health_result candidate ~success:false
           ~http_status:(http_status_of_http_error http_err);
         record_health_and_backpressure ctx candidate ?http_status:(http_status_of_http_error http_err) http_err;
         if is_last
         then
           (match ctx.lrf_fallback_candidates, lrf_attempted with
            | Some (fallback :: _), false ->
              loop checkpoint_after (Some (Keeper_internal_error.of_sdk_error err)) true [fallback]
            | _ ->
              Error (Keeper_internal_error.of_sdk_error err))
         else loop checkpoint_after (Some (Keeper_internal_error.of_sdk_error err)) lrf_attempted rest)
  in
  loop None None false candidates