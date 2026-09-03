(* Keeper_turn_runtime_budget — runtime execution types, fail-open rotation,
   context overflow observation, Keeper lifecycle
   sync, and context budget resolution.

   Extracted from keeper_unified_turn.ml (L501-1079) during the god-file split. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_context_runtime
module EC = Keeper_error_classify
module StringMap = Set_util.StringMap

type runtime_execution = {
  runtime_id : string;
  max_context_resolution : Keeper_context_runtime.max_context_resolution;
  max_context : int;
  temperature : float;
}

let next_fail_open_runtime_for_turn =
  Keeper_turn_runtime_budget_routing.next_fail_open_runtime_for_turn

type degraded_retry_decision =
  | No_degraded_retry
  | Degraded_retry_allowed of EC.degraded_retry

type 'a degraded_retry_prepare_result =
  | Degraded_retry_prepared of {
      retry : EC.degraded_retry;
      reason : string;
      next : 'a;
    }
  | Degraded_retry_setup_failed of {
      retry : EC.degraded_retry;
      reason : string;
      fail_open_err : Agent_core.Error.t;
    }

type 'a degraded_retry_step =
  | Degraded_retry_step_not_allowed
  | Degraded_retry_step_setup_failed of {
      retry : EC.degraded_retry;
      reason : string;
      fail_open_err : Agent_core.Error.t;
    }
  | Degraded_retry_step_prepared of {
      retry : EC.degraded_retry;
      reason : string;
      next : 'a;
    }

let empty_degraded_retry_runtime_error =
  Agent_core.Error.Internal "degraded retry selected empty next_runtime"

let prepare_degraded_retry_allowed
      ~current_runtime_id
      ~attempt
      ~err
      ~(retry : EC.degraded_retry)
      ~publish_cascade_resolution
      ~emit_runtime_selected
      ~emit_runtime_rotation
      ~setup_runtime
  =
  let reason = EC.degraded_retry_reason_to_string retry.fallback_reason in
  match String.trim retry.next_runtime with
  | "" ->
    publish_cascade_resolution
      ~runtime_id:current_runtime_id
      ~decision:Keeper_unified_turn_cascade_resolution.No_degraded_retry
      ~reason:"empty_degraded_retry_runtime"
      ~next_runtime:None
      ~attempt
      err;
    Degraded_retry_setup_failed {
      retry;
      reason;
      fail_open_err = empty_degraded_retry_runtime_error;
    }
  | next_runtime ->
    let retry = { retry with next_runtime } in
    publish_cascade_resolution
      ~runtime_id:current_runtime_id
      ~decision:Keeper_unified_turn_cascade_resolution.Degraded_retry_allowed
      ~reason
      ~next_runtime:(Some retry.next_runtime)
      ~attempt
      err;
    (match setup_runtime retry.next_runtime with
     | Ok next ->
       emit_runtime_selected ~runtime_id:retry.next_runtime ~fallback_reason:reason;
       emit_runtime_rotation
         ~from_runtime:current_runtime_id
         ~to_runtime:retry.next_runtime
         ~reason;
       Degraded_retry_prepared { retry; reason; next }
     | Error fail_open_err ->
       Degraded_retry_setup_failed { retry; reason; fail_open_err })

let decide_degraded_retry
    ~(base_runtime : string)
    ~(effective_runtime : string)
    ~(attempted_runtimes : string list)
    (err : Agent_core.Error.t) : degraded_retry_decision =
  match
    next_fail_open_runtime_for_turn
      ~base_runtime ~effective_runtime
      ~attempted_runtimes err
  with
  | None -> No_degraded_retry
  | Some retry -> Degraded_retry_allowed retry

let plan_degraded_retry_step
      ~base_runtime
      ~current_runtime_id
      ~attempted_runtimes
      ~attempt
      ~err
      ~allow_retry
      ~publish_cascade_resolution
      ~emit_runtime_selected
      ~emit_runtime_rotation
      ~setup_runtime
  =
  match
    decide_degraded_retry
      ~base_runtime
      ~effective_runtime:current_runtime_id
      ~attempted_runtimes
      err
  with
  | No_degraded_retry -> Degraded_retry_step_not_allowed
  | Degraded_retry_allowed retry when allow_retry retry ->
    (match
       prepare_degraded_retry_allowed
         ~current_runtime_id
         ~attempt
         ~err
         ~retry
         ~publish_cascade_resolution
         ~emit_runtime_selected
         ~emit_runtime_rotation
         ~setup_runtime
     with
     | Degraded_retry_prepared { retry; reason; next } ->
       Degraded_retry_step_prepared { retry; reason; next }
     | Degraded_retry_setup_failed { retry; reason; fail_open_err } ->
       Degraded_retry_step_setup_failed { retry; reason; fail_open_err })
  | Degraded_retry_allowed _ -> Degraded_retry_step_not_allowed

let yield_before_direct_no_progress_retry () = Eio.Fiber.yield ()

let direct_no_progress_retry_reason err =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some internal_error ->
    (match Keeper_turn_driver.accept_no_progress_retry_kind internal_error with
     | Some `Empty_no_progress -> Some EC.Empty_no_progress
     | Some `Thinking_only_no_progress -> Some EC.Thinking_only_no_progress
     | Some `Truncated_no_progress -> None
     | None -> None)
  | None -> None

let retry_reason_is_direct_no_progress (retry : EC.degraded_retry) =
  match retry.fallback_reason with
  | EC.Empty_no_progress | EC.Thinking_only_no_progress -> true
  | _ -> false

let direct_no_progress_retry_decision
    ~base_runtime
    ~effective_runtime
    ~attempted_runtimes
    err =
  match direct_no_progress_retry_reason err with
  | None -> No_degraded_retry
  | Some (EC.Empty_no_progress | EC.Thinking_only_no_progress) ->
    (match
       decide_degraded_retry
         ~base_runtime
         ~effective_runtime
         ~attempted_runtimes
         err
     with
     | Degraded_retry_allowed retry when retry_reason_is_direct_no_progress retry
       -> Degraded_retry_allowed retry
     | _ -> No_degraded_retry)
  | Some _ -> No_degraded_retry

let run_direct_no_progress_retry_loop
      ~keeper_name
      ~base_runtime
      ~(initial_execution : runtime_execution)
      ~current_turn_phase_elapsed_ms
      ~now_s
      ~(setup_retry_runtime :
         string -> (runtime_execution, Agent_core.Error.t) result)
      ~publish_cascade_resolution
      ~emit_runtime_selected
      ~emit_runtime_rotation
      ~record_retry_setup_failure
      ~before_retry
      ~run_once
      ()
  =
  let rec run_attempt
      ~runtime_id
      ~(runtime_execution : runtime_execution)
      ~attempted_runtimes
      ?degraded_retry
      ~runtime_rotation_attempts
      ~attempt
      ~retry_phase_started_at
      ~is_retry
      ()
    =
    let degraded_retry_runtime =
      Option.map (fun (retry : EC.degraded_retry) -> retry.next_runtime)
        degraded_retry
    in
    let fallback_reason =
      Option.map (fun (retry : EC.degraded_retry) -> retry.fallback_reason)
        degraded_retry
    in
    let attempt_max_context = runtime_execution.max_context in
    match
      run_once
        ~runtime_id
        ~max_context:attempt_max_context
        ~is_retry
        ~degraded_retry_runtime
        ~fallback_reason
        ~runtime_rotation_attempts:(List.rev runtime_rotation_attempts)
    with
    | Ok result -> Ok (result, attempt_max_context)
    | Error err as error ->
      (match
         plan_degraded_retry_step
           ~base_runtime
           ~current_runtime_id:runtime_id
           ~attempted_runtimes
           ~attempt
           ~err
           ~allow_retry:retry_reason_is_direct_no_progress
           ~publish_cascade_resolution
           ~emit_runtime_selected
           ~emit_runtime_rotation
           ~setup_runtime:setup_retry_runtime
       with
       | Degraded_retry_step_not_allowed ->
         let reason =
           match direct_no_progress_retry_reason err with
           | Some retry_reason ->
             Printf.sprintf
               "terminal_%s_no_degraded_retry"
               (EC.degraded_retry_reason_to_string retry_reason)
           | None -> "terminal_error_not_degraded_retry_eligible"
         in
         publish_cascade_resolution
           ~runtime_id
           ~decision:Keeper_unified_turn_cascade_resolution.No_degraded_retry
           ~reason
           ~next_runtime:None
           ~attempt
           err;
         error
       | Degraded_retry_step_setup_failed { retry; fail_open_err; _ } ->
         let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
           current_turn_phase_elapsed_ms retry_phase_started_at
         in
         let rotation_attempt =
           Keeper_unified_turn_rotation_attempt.build
             ~recorded_at:(now_iso ())
             ~productive_phase_elapsed_ms
             ?retry_phase_elapsed_ms
             ~from_runtime:runtime_id
             ~retry
             ~outcome:Keeper_execution_receipt.Rotation_setup_failed
             fail_open_err
         in
         record_retry_setup_failure
           ~from_runtime:runtime_id
           ~retry
           ~rotation_attempt
           ~fail_open_err;
         Error fail_open_err
       | Degraded_retry_step_prepared { retry; reason; next = next_execution }
         ->
         let retry_phase_started_at =
           match retry_phase_started_at with
           | Some _ -> retry_phase_started_at
           | None -> Some (now_s ())
         in
         let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
           current_turn_phase_elapsed_ms retry_phase_started_at
         in
         let rotation_attempt =
           Keeper_unified_turn_rotation_attempt.build
             ~recorded_at:(now_iso ())
             ~productive_phase_elapsed_ms
             ?retry_phase_elapsed_ms
             ~from_runtime:runtime_id
             ~retry
             ~outcome:Keeper_execution_receipt.Rotation_retry_scheduled
             err
         in
         let retry_resolution = next_execution.max_context_resolution in
         Log.Keeper.warn
           "%s: direct keeper_msg no-progress response from runtime=%s; retrying \
            runtime=%s reason=%s max_context=%d context_budget=%d \
            primary_budget=%d requested_override=%s"
           keeper_name
           runtime_id
           next_execution.runtime_id
           reason
           next_execution.max_context
           retry_resolution.effective_budget
           retry_resolution.primary_budget
           (match retry_resolution.requested_override with
            | Some requested -> string_of_int requested
            | None -> "none");
         before_retry ();
        run_attempt
          ~runtime_id:next_execution.runtime_id
          ~runtime_execution:next_execution
           ~attempted_runtimes:(next_execution.runtime_id :: attempted_runtimes)
           ~degraded_retry:retry
           ~runtime_rotation_attempts:(rotation_attempt :: runtime_rotation_attempts)
           ~attempt:1
           ~retry_phase_started_at
           ~is_retry:true
           ())
  in
  run_attempt
    ~runtime_id:initial_execution.runtime_id
    ~runtime_execution:initial_execution
    ~attempted_runtimes:[ initial_execution.runtime_id ]
    ~runtime_rotation_attempts:[]
    ~attempt:1
    ~retry_phase_started_at:None
    ~is_retry:false
    ()

type turn_event_bus_summary =
  Keeper_turn_runtime_budget_event_bus.turn_event_bus_summary = {
  correlation_id : string option;
  run_id : string option;
  caused_by : string option;
  event_count : int;
  payload_kinds : string list;
}

let empty_turn_event_bus_summary =
  Keeper_turn_runtime_budget_event_bus.empty_turn_event_bus_summary

let merge_turn_event_bus_summary =
  Keeper_turn_runtime_budget_event_bus.merge_turn_event_bus_summary

let add_payload_kind =
  Keeper_turn_runtime_budget_event_bus.add_payload_kind

let summarize_turn_event_bus
    (events : Agent_core.Event_bus.event list) : turn_event_bus_summary =
  List.fold_left
    (fun acc (evt : Agent_core.Event_bus.event) ->
      let correlation_id =
        match acc.correlation_id with
        | Some _ -> acc.correlation_id
        | None -> Some evt.meta.correlation_id
      in
      let run_id =
        match acc.run_id with
        | Some _ -> acc.run_id
        | None -> Some evt.meta.run_id
      in
      let caused_by =
        match acc.caused_by with
        | Some _ -> acc.caused_by
        | None -> evt.meta.caused_by
      in
      { correlation_id;
        run_id;
        caused_by;
        event_count = acc.event_count + 1;
        payload_kinds =
          add_payload_kind acc.payload_kinds
            (Agent_core.Event_bus.payload_kind evt.payload);
      })
    empty_turn_event_bus_summary
    events

let turn_event_bus_evidence_detail
    (summary : turn_event_bus_summary) : string =
  Printf.sprintf
    "agent_core_event_evidence(events=%d,payload_kinds=[%s])"
    summary.event_count
    (String.concat "," summary.payload_kinds)

type capacity_refusal =
  | Provider_context_window of { limit_tokens : int option }
  | Serialized_request_body of
      { actual_bytes : int
      ; limit_bytes : int
      }
  | Provider_request_body_refusal of { status : int }

(* Two-axis refusal view over the AGENT_CORE error type. The error is matched
   once, directly. Non-capacity errors and the serving-constraint facts
   (evidence validity, unmeasurable tokens) stay [None]: they are not a
   capacity limit and must never be guessed into one. *)
let capacity_refusal_of_error
    (err : Agent_core.Error.t) : capacity_refusal option =
  match err with
  | Agent_core.Error.Api (ContextOverflow { limit; _ }) ->
    Some (Provider_context_window { limit_tokens = limit })
  | Agent_core.Error.Api
      (InvalidRequest
         { reason = Request_body_too_large { actual_bytes; limit_bytes }; _ })
    ->
    Some (Serialized_request_body { actual_bytes; limit_bytes })
  | Agent_core.Error.Api
      (InvalidRequest
         { reason = Request_body_refused_by_provider { status }; _ })
    ->
    Some (Provider_request_body_refusal { status })
  | Agent_core.Error.Api (InputCapacity _)
  | Agent_core.Error.Api
      (InvalidRequest
         { reason = Json_parse_error | Attempt_rejected | Unknown_invalid_request; _ })
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
  | Agent_core.Error.Orchestration _
  | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } ->
    None
;;

let current_keeper_meta ~(config : Workspace.config) ~(fallback_meta : keeper_meta) =
  match Keeper_registry.get ~base_path:config.base_path fallback_meta.name with
  | Some entry -> entry.meta
  | None -> fallback_meta

let runtime_budget_logged : unit StringMap.t Atomic.t =
  Atomic.make StringMap.empty

let runtime_budget_log_key ~keeper_name ~primary_budget ~runtime_budget =
  Printf.sprintf "%s|%d|%d" keeper_name primary_budget runtime_budget

let resolved_max_context_for_turn
      ~(meta : keeper_meta)
      (resolution : Keeper_context_runtime.max_context_resolution)
  : int
  =
  if resolution.primary_budget < resolution.runtime_budget then begin
    let key =
      runtime_budget_log_key
        ~keeper_name:meta.name
        ~primary_budget:resolution.primary_budget
        ~runtime_budget:resolution.runtime_budget
    in
    let rec log_once () =
      let old = Atomic.get runtime_budget_logged in
      if StringMap.mem key old
      then ()
      else
        let new_map = StringMap.add key () old in
        if Atomic.compare_and_set runtime_budget_logged old new_map
        then
          Log.Keeper.info
            "%s: mixed runtime context window primary=%d runtime_max=%d; using primary for initial context window"
            meta.name resolution.primary_budget resolution.runtime_budget
        else log_once ()
    in
    log_once ()
  end;
   (match resolution.requested_override with
    | Some requested ->
     Log.Keeper.debug
       "%s: using max_context_override=%d context_budget=%d primary_budget=%d effective_budget=%d"
       meta.name requested resolution.requested_context_window resolution.primary_budget
       resolution.effective_budget
   | None -> ());
  resolution.effective_budget
