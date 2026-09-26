module Exact = Agent_core.Exact_output
module Registry = Runtime_exact_output_registry
module Backpressure = Runtime_candidate_backpressure

let candidate_of_slot slot_id =
  Option.map
    (fun (runtime : Runtime.t) -> runtime.candidate_backpressure)
    (Runtime.get_runtime_by_id slot_id)
;;

(* The same two stores the Keeper walk reads to demote a path
   ([Keeper_turn_driver.demote_unavailable_candidates]): a quota window the
   provider reported exhausted, and a rate limit this process observed. A
   failed attempt that is not a rate limit carries no rest and does not move a
   slot here.

   A rate limit rests the slot for the Keeper walk's own path rest
   ([Keeper_runtime_failure_route.path_rest_sec]): the provider's Retry-After
   when it sent one, the configured floor when it did not, never past the
   configured cap. The Keeper walk keeps an unhinted rate limit demoted until
   the path answers, because a later rotation still reaches it; an Exact lane
   whose siblings keep answering never would, so here the rest ends and the
   slot is tried in its declared place again. *)
let resting ~now slot_id =
  match Runtime.get_runtime_by_id slot_id with
  | None -> false
  | Some (runtime : Runtime.t) ->
    let quota_exhausted =
      Runtime_quota_window.is_exhausted
        ~scope:(Runtime.quota_scope_of_runtime runtime)
        ~now
    in
    let rate_limited =
      match
        Backpressure.candidate_backpressure ~now ~candidate:runtime.candidate_backpressure
      with
      | Some
          { Backpressure.rate_limit =
              Some (Backpressure.Unknown_scope_rate_limit { noted_at; retry_after })
          ; failed_attempt = _
          } ->
        let rest_sec =
          Keeper_runtime_failure_route.path_rest_sec
            ~cap_sec:Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec
            ~retry_class:Keeper_runtime_failure_route.Rate_limited
            ~retry_after_hint:retry_after
        in
        Float.compare now (noted_at +. rest_sec) < 0
      | Some { Backpressure.rate_limit = None; failed_attempt = _ } | None -> false
    in
    quota_exhausted || rate_limited
;;

let order_at ~now (resolved : Registry.resolved_lane) =
  let serving, resting =
    List.partition
      (fun (slot : Registry.selected_slot) -> not (resting ~now slot.slot_id))
      resolved.selected_slots
  in
  { resolved with selected_slots = serving @ resting }
;;

let order resolved =
  (* NDT-OK: the wall clock only decides whether a slot's rest has run out; it
     reorders candidates and never changes which ones a lane walks. *)
  order_at ~now:(Unix.gettimeofday ()) resolved
;;

let note_cause ~slot_id (cause : Exact.execution_error_cause) =
  match cause with
  | Exact.Provider_response_refused { refusal = Exact.Rate_limited; retry_after_s; _ } ->
    Option.iter
      (fun candidate -> Backpressure.note_rate_limit ~candidate ~retry_after:retry_after_s)
      (candidate_of_slot slot_id)
  | Exact.Provider_response_refused _
  | Exact.Attempt_already_started
  | Exact.Clock_required_for_timeout
  | Exact.Frozen_request_mismatch
  | Exact.Completion_failed _
  | Exact.Response_body_deadline_exceeded
  | Exact.Incomplete_output
  | Exact.Missing_output
  | Exact.Ambiguous_output _
  | Exact.Unexpected_output_content
  | Exact.Invalid_json_output
  | Exact.Internal_non_json_output -> ()
;;

let note_answered (success : Exact.flow_success) =
  let answered = Exact.flow_success_candidate success in
  Option.iter
    (fun candidate -> Backpressure.note_candidate_success ~candidate)
    (candidate_of_slot answered.visit.identity.candidate_id)
;;

(* A refusal that advanced the flow is kept in its evidence; the one that
   ended it, or that a callback stopped before the advance, is not. *)
let note_advances (evidence : Exact.flow_evidence) =
  List.iter
    (fun (advance : Exact.flow_advance_receipt) ->
       match advance.failed with
       | Exact.Flow_advance_execution_failed { candidate; cause; _ } ->
         note_cause ~slot_id:candidate.visit.identity.candidate_id cause
       | Exact.Flow_advance_candidate_rejected _ -> ())
    evidence.advances
;;

let note_candidate_failure = function
  | Exact.Flow_candidate_execution_failed { candidate; cause } ->
    note_cause ~slot_id:candidate.visit.identity.candidate_id cause.cause
  | Exact.Flow_candidate_rejected _ -> ()
;;

let note_rejections rejections =
  List.iter
    (fun (rejection : _ Exact.semantic_rejection_receipt) ->
       note_answered rejection.transport_success)
    rejections
;;

let note_terminal (cause : _ Exact.flow_execution_error) =
  match cause with
  | Exact.Flow_exact_execution_failed { candidate; cause; evidence } ->
    note_advances evidence;
    note_cause ~slot_id:candidate.visit.identity.candidate_id cause.cause
  | Exact.Flow_before_advance_callback_failed { failed; evidence; _ } ->
    note_advances evidence;
    note_candidate_failure failed
  | Exact.Flow_attempt_already_started evidence
  | Exact.Flow_attempt_start_failed { evidence; _ }
  | Exact.Flow_measurement_start_failed { evidence; _ }
  | Exact.Flow_before_measurement_dispatch_callback_failed { evidence; _ }
  | Exact.Flow_measurement_terminal_callback_failed { evidence; _ }
  | Exact.Flow_before_dispatch_callback_failed { evidence; _ }
  | Exact.Flow_candidates_exhausted { evidence; _ } -> note_advances evidence
;;

let observe = function
  | Ok (success : (_, _) Exact.validated_flow_success) ->
    note_advances (Exact.flow_success_evidence success.transport_success);
    note_rejections success.prior_rejections;
    note_answered success.transport_success
  | Error (Exact.Flow_execution_terminal { cause; prior_rejections }) ->
    note_rejections prior_rejections;
    note_terminal cause
  | Error (Exact.Flow_semantic_candidates_exhausted { rejections; evidence }) ->
    note_advances evidence;
    note_rejections (rejections.first :: rejections.rest)
;;
