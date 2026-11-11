module Exact = Agent_core.Exact_output
module Failure = Keeper_exact_walk_failure
open Result.Syntax

type binding =
  | Http of { provider_id:string option; model_id:string; provider_kind:string; endpoint:string }
  | Http_unobserved
  | Official_client
[@@deriving yojson]
type phase = Prepared | Before_dispatch | Dispatch_started | Response_received | Terminal
[@@deriving yojson]
type outcome = Unresolved | Accepted | Semantic_rejected
  | Admission_rejected of Failure.local_rejection
  | Execution_failed of Failure.api_observation
  | Cli_failed of Failure.cli_observation
[@@deriving yojson]
type t =
  { slot_id:string; lane_key:string option; binding:binding; call_id:string option; flow_id:string option;
    visit_ordinal:int option; plan_fingerprint:string option; request_body_sha256:string option;
    catalog_generation:string option; catalog_evidence:string option; target_identity:string option;
    phase:phase; generation_dispatched:bool;
    started_at:float option; finished_at:float option; outcome:outcome }
[@@deriving yojson]

let valid_time = Option.fold ~none:true ~some:(fun value -> Float.is_finite value && value >= 0.)
let of_yojson json =
  let* value = of_yojson json in
  let* original = Lane_addon_action.canonical json in
  let* encoded = Lane_addon_action.canonical (to_yojson value) in
  let valid_binding = match value.binding with
    | Http {endpoint;_} ->
      let uri = Uri.of_string endpoint in
      (match Uri.scheme uri,Uri.host uri with
       | Some ("https"|"http"),Some host -> host<>""
       | _ -> false)
      && Uri.userinfo uri=None && Uri.query uri=[] && Uri.fragment uri=None
    | Http_unobserved | Official_client -> true in
  let valid_owner = match value.lane_key with None -> true
    | Some key -> Option.is_some (Runtime_schema.exact_lane_owner_of_key key) in
  if original=encoded && String.trim value.slot_id<>"" && valid_binding && valid_owner
     && valid_time value.started_at && valid_time value.finished_at
     && (value.finished_at=None || value.started_at<>None)
  then Ok value else Error "invalid exact slot observation"

let with_owner owner observation =
  { observation with lane_key=Some (Runtime_schema.exact_lane_key owner) }

let phase = function
  | Exact.Not_started -> Prepared | Before_dispatch -> Before_dispatch
  | Dispatch_started -> Dispatch_started | Response_received -> Response_received | Terminal -> Terminal
let visit_of_admission = function
  | Exact.Candidate_admitted candidate -> candidate.visit
  | Candidate_rejected rejection -> Exact.candidate_rejection_visit rejection
let rejection_outcome rejection = Admission_rejected
  (Failure.local_rejection (Exact.candidate_rejection_disposition rejection))
let failed_snapshot = function
  | Exact.Flow_advance_candidate_rejected rejection ->
    (Exact.candidate_rejection_visit rejection).ordinal,rejection_outcome rejection
  | Flow_advance_execution_failed {candidate;cause;_} ->
    candidate.visit.ordinal,Execution_failed (Failure.api_observation cause)
let failed_candidate = function
  | Exact.Flow_candidate_rejected rejection ->
    (Exact.candidate_rejection_visit rejection).ordinal,rejection_outcome rejection
  | Flow_candidate_execution_failed {candidate;cause} ->
    candidate.visit.ordinal,Execution_failed (Failure.api_observation cause.cause)
let semantic (rejection:'a Exact.semantic_rejection_receipt) =
  (Exact.flow_success_candidate rejection.Exact.transport_success).visit.ordinal,Semantic_rejected

let capture (evidence:Exact.flow_evidence) outcomes =
  let outcomes = outcomes @ List.map (fun (advance:Exact.flow_advance_receipt) ->
    failed_snapshot advance.failed) evidence.advances in
  List.map (fun admission ->
    let visit = visit_of_admission admission in
    let identity = visit.identity in
    let attempt = List.find_opt (fun (attempt:Exact.flow_attempt_snapshot) ->
      attempt.visit.ordinal=visit.ordinal) evidence.attempts in
    let outcome = match List.assoc_opt visit.ordinal outcomes,admission with
      | Some outcome,_ -> outcome
      | None,Exact.Candidate_rejected rejection -> rejection_outcome rejection
      | None,Exact.Candidate_admitted _ -> Unresolved in
    let binding,call_id,plan_fingerprint,request_body_sha256,phase,generation_dispatched,started_at,finished_at =
      match attempt with
      | None -> Http_unobserved,None,None,None,Prepared,false,None,None
      | Some attempt ->
        let receipt=attempt.receipt in
        let binding=Exact.generation_receipt_snapshot_binding receipt in
        (Http {provider_id=binding.provider_id;model_id=binding.model_id;
           provider_kind=Llm_provider.Provider_config.string_of_provider_kind binding.provider_kind;
           endpoint=binding.endpoint},
         Some (Exact.call_id_to_string (Exact.generation_receipt_snapshot_call_id receipt)),
         Some (Exact.generation_receipt_snapshot_plan_fingerprint receipt),
         Some (Exact.generation_receipt_snapshot_request_body_sha256 receipt),
         phase (Exact.generation_receipt_snapshot_phase receipt),
         Exact.generation_receipt_snapshot_generation_dispatched receipt,
         Exact.generation_receipt_snapshot_execution_started_at receipt,
         Exact.generation_receipt_snapshot_execution_finished_at receipt) in
    {slot_id=identity.candidate_id;lane_key=None;binding;call_id;flow_id=Some (Exact.flow_id_to_string visit.flow_id);
     visit_ordinal=Some (Exact.flow_visit_ordinal_to_int visit.ordinal);plan_fingerprint;request_body_sha256;
     catalog_generation=Some (Exact.catalog_generation_fingerprint identity.catalog_generation);
     catalog_evidence=Some (Exact.catalog_evidence_sha256 identity.catalog_evidence);
     target_identity=Some (Exact.target_identity_fingerprint identity.target_identity);
     phase;generation_dispatched;started_at;finished_at;outcome}) evidence.admissions

let of_evidence evidence = capture evidence []
let terminal_evidence = function
  | Exact.Flow_attempt_already_started evidence -> evidence,[]
  | Flow_attempt_start_failed {evidence;_} | Flow_measurement_start_failed {evidence;_}
  | Flow_before_measurement_dispatch_callback_failed {evidence;_}
  | Flow_measurement_terminal_callback_failed {evidence;_}
  | Flow_before_dispatch_callback_failed {evidence;_} -> evidence,[]
  | Flow_before_advance_callback_failed {evidence;failed;_} -> evidence,[failed_candidate failed]
  | Flow_candidates_exhausted {evidence;rejection} ->
    evidence,[(Exact.candidate_rejection_visit rejection).ordinal,rejection_outcome rejection]
  | Flow_exact_execution_failed {evidence;candidate;cause} ->
    evidence,[candidate.visit.ordinal,Execution_failed (Failure.api_observation cause.cause)]
let of_result = function
  | Ok (success:('a,'b) Exact.validated_flow_success) ->
    let accepted=Exact.flow_success_candidate success.Exact.transport_success in
    capture (Exact.flow_success_evidence success.transport_success)
      ((accepted.visit.ordinal,Accepted)::List.map semantic success.prior_rejections)
  | Error (Exact.Flow_semantic_candidates_exhausted {evidence;rejections}) ->
    capture evidence (List.map semantic (rejections.first::rejections.rest))
  | Error (Exact.Flow_execution_terminal {cause;prior_rejections}) ->
    let evidence,terminal=terminal_evidence cause in
    capture evidence (terminal @ List.map semantic prior_rejections)

let cli ~slot_id ~started_at ~finished_at ~generation_dispatched ~outcome =
  {slot_id;lane_key=None;binding=Official_client;call_id=None;flow_id=None;visit_ordinal=None;
   plan_fingerprint=None;request_body_sha256=None;catalog_generation=None;catalog_evidence=None;
   target_identity=None;phase=(if generation_dispatched then Dispatch_started else Prepared);
   generation_dispatched;started_at;finished_at;outcome}
