module Exact = Agent_core.Exact_output
module Registry = Runtime_exact_output_registry
module Standing = Runtime_candidate_standing

let observation_of_slot (resolved : Registry.resolved_lane) slot_id =
  Option.bind
    (List.find_opt (fun (slot : Registry.selected_slot) -> slot.slot_id = slot_id)
       resolved.selected_slots)
    (fun slot -> slot.Registry.runtime_observation)
;;

let observe_slot ~resolved ~slot_id observation =
  Option.iter
    (fun (runtime : Registry.runtime_observation) ->
      Standing.observe ~candidate:(Some runtime.candidate)
        ~quota_scope:(Some runtime.quota_scope) observation)
    (observation_of_slot resolved slot_id)
;;

type held_slot =
  { slot_id : string
  ; until : float
  }

type ordered =
  { lane : Registry.resolved_lane
  ; held_http : held_slot list
  }

let order_at ~now (resolved : Registry.resolved_lane) =
  let split = Standing.order_exact ~now
    ~quota_scope_of:(fun (slot : Registry.selected_slot) ->
      Option.map (fun (observation : Registry.runtime_observation) -> observation.quota_scope)
        slot.runtime_observation)
    ~candidate_backpressure_of:(fun (slot : Registry.selected_slot) ->
      Option.map (fun (observation : Registry.runtime_observation) -> observation.candidate)
        slot.runtime_observation)
    resolved.selected_slots in
  { lane = { resolved with selected_slots = split.Standing.walk }
  ; held_http =
      List.map (fun ((slot : Registry.selected_slot), until) ->
        { slot_id = slot.Registry.slot_id; until })
        split.Standing.held
  }
;;

let order resolved =
  (* NDT-OK: the wall clock decides only whether a rest or a provider-stated
     time has passed. A slot it sets aside comes back in [held_http] with its
     time, so no slot leaves the lane unseen. *)
  order_at ~now:(Unix.gettimeofday ()) resolved
;;

let note_cause ~resolved ~slot_id (cause : Exact.execution_error_cause) =
  match cause with
  | Exact.Provider_response_refused { refusal = Exact.Rate_limited; retry_after_s; _ } ->
    observe_slot ~resolved ~slot_id (Standing.Rate_limited {retry_after=retry_after_s})
  | Exact.Provider_response_refused {refusal=Exact.Payment_required; retry_after_s; _} ->
    (* NDT-OK: convert the provider's relative reset at observation ingress. *)
    let resets_at = Option.map (fun seconds -> Unix.gettimeofday () +. seconds)
      (Keeper_runtime_failure_route.usable_retry_after retry_after_s) in
    observe_slot ~resolved ~slot_id
      (Standing.Hard_quota {source=Runtime_quota_window.Payment_refused; resets_at})
  | Exact.Completion_failed {error; dispatch=Exact.Generation_dispatch_started} ->
    Option.iter
      (fun (runtime : Registry.runtime_observation) ->
        (* NDT-OK: only the actual dispatched attempt's frozen identity owns
           this provider observation, including a relative quota reset. *)
        Standing.observe_http_error ~now:(Unix.gettimeofday ())
          ~candidate:runtime.candidate ~quota_scope:runtime.quota_scope error)
      (observation_of_slot resolved slot_id)
  | Exact.Provider_response_refused
      { refusal =
          ( Exact.Request_body_refused | Exact.Refusal_body_not_received | Exact.Overloaded
          | Exact.Server_error | Exact.Auth_failed | Exact.Authorization_refused
          | Exact.Invalid_request | Exact.Not_found
          | Exact.Context_overflow | Exact.Input_capacity | Exact.Network_error
          | Exact.Timeout )
      ; _
      }
  | Exact.Completion_failed {dispatch=Exact.No_generation_dispatch; _}
  | Exact.Response_body_deadline_exceeded
  | Exact.Output_limit_reached
  | Exact.Incomplete_output
  | Exact.Missing_output
  | Exact.Ambiguous_output _
  | Exact.Unexpected_output_content
  | Exact.Invalid_json_output -> ()
;;

let note_answered ~resolved (success : Exact.flow_success) =
  let answered = Exact.flow_success_candidate success in
  observe_slot ~resolved ~slot_id:answered.visit.identity.candidate_id Standing.Answered
;;

(* A refusal that advanced the flow is kept in its evidence; the one that
   ended it, or that a callback stopped before the advance, is not. *)
let note_advances ~resolved (evidence : Exact.flow_evidence) =
  List.iter
    (fun (advance : Exact.flow_advance_receipt) ->
       match advance.failed with
       | Exact.Flow_advance_execution_failed { candidate; cause; _ } ->
         note_cause ~resolved ~slot_id:candidate.visit.identity.candidate_id cause
       | Exact.Flow_advance_candidate_rejected _ -> ())
    evidence.advances
;;

let note_candidate_failure ~resolved = function
  | Exact.Flow_candidate_execution_failed { candidate; cause } ->
    note_cause ~resolved ~slot_id:candidate.visit.identity.candidate_id cause.cause
  | Exact.Flow_candidate_rejected _ -> ()
;;

let note_rejections ~resolved rejections =
  List.iter
    (fun (rejection : _ Exact.semantic_rejection_receipt) ->
       note_answered ~resolved rejection.transport_success)
    rejections
;;

let note_terminal ~resolved (cause : _ Exact.flow_execution_error) =
  match cause with
  | Exact.Flow_exact_execution_failed { candidate; cause; evidence } ->
    note_advances ~resolved evidence;
    note_cause ~resolved ~slot_id:candidate.visit.identity.candidate_id cause.cause
  | Exact.Flow_before_advance_callback_failed { failed; evidence; _ } ->
    note_advances ~resolved evidence;
    note_candidate_failure ~resolved failed
  | Exact.Flow_attempt_already_started evidence
  | Exact.Flow_attempt_start_failed { evidence; _ }
  | Exact.Flow_measurement_start_failed { evidence; _ }
  | Exact.Flow_before_measurement_dispatch_callback_failed { evidence; _ }
  | Exact.Flow_measurement_terminal_callback_failed { evidence; _ }
  | Exact.Flow_before_dispatch_callback_failed { evidence; _ }
  | Exact.Flow_candidates_exhausted { evidence; _ } -> note_advances ~resolved evidence
;;

let observe ~resolved = function
  | Ok (success : (_, _) Exact.validated_flow_success) ->
    note_advances ~resolved (Exact.flow_success_evidence success.transport_success);
    note_rejections ~resolved success.prior_rejections;
    note_answered ~resolved success.transport_success
  | Error (Exact.Flow_execution_terminal { cause; prior_rejections }) ->
    note_rejections ~resolved prior_rejections;
    note_terminal ~resolved cause
  | Error (Exact.Flow_semantic_candidates_exhausted { rejections; evidence }) ->
    note_advances ~resolved evidence;
    note_rejections ~resolved (rejections.first :: rejections.rest)
;;
