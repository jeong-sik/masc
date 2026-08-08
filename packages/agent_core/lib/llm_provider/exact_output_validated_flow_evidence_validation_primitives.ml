open Exact_output_validated_flow_evidence_types
module Json = Exact_output_validated_flow_evidence_canonical_json

let ( let* ) = Result.bind

let check_identifier ?ordinal field value =
  if Json.is_canonical_identifier value
  then Ok ()
  else Error (Non_canonical_identifier { field; ordinal })
;;

let check_sha256 ?ordinal field value =
  if Json.is_sha256 value then Ok () else Error (Invalid_sha256 { field; ordinal })
;;

let check_optional_sha256 ~ordinal field = function
  | None -> Ok ()
  | Some value -> check_sha256 ~ordinal field value
;;

let check_candidate ?ordinal (candidate : candidate) =
  let* () = check_identifier ?ordinal "candidate_id" candidate.candidate_id in
  let* () =
    check_sha256 ?ordinal "candidate_binding_sha256" candidate.candidate_binding_sha256
  in
  let* () =
    check_sha256 ?ordinal "catalog_generation_sha256" candidate.catalog_generation_sha256
  in
  check_sha256 ?ordinal "catalog_evidence_sha256" candidate.catalog_evidence_sha256
;;

let check_provenance ~ordinal (candidate : candidate) (provenance : provenance) =
  let* () =
    check_sha256 ~ordinal "source_schema_sha256" provenance.source_schema_sha256
  in
  let* () =
    check_optional_sha256
      ~ordinal
      "effective_schema_sha256"
      provenance.effective_schema_sha256
  in
  let* () =
    check_sha256
      ~ordinal
      "provenance.candidate_binding_sha256"
      provenance.candidate_binding_sha256
  in
  let* () =
    check_sha256
      ~ordinal
      "provenance.catalog_generation_sha256"
      provenance.catalog_generation_sha256
  in
  let* () =
    check_sha256
      ~ordinal
      "provenance.catalog_evidence_sha256"
      provenance.catalog_evidence_sha256
  in
  if
    String.equal candidate.candidate_binding_sha256 provenance.candidate_binding_sha256
    && String.equal
         candidate.catalog_generation_sha256
         provenance.catalog_generation_sha256
    && String.equal candidate.catalog_evidence_sha256 provenance.catalog_evidence_sha256
  then Ok ()
  else Error (Attempt_binding_mismatch { ordinal })
;;

let rejected_measurement_state_is_valid (evidence : measurement_evidence) =
  evidence.dispatch = No_measurement_dispatch
;;

let admitted_measurement_state_is_valid (evidence : measurement_evidence) =
  match evidence.dispatch, evidence.outcome with
  | No_measurement_dispatch, Measurement_not_required
  | Measurement_dispatch_started, Measurement_succeeded -> true
  | No_measurement_dispatch, Measurement_succeeded
  | Measurement_dispatch_started, Measurement_not_required
  | ( (No_measurement_dispatch | Measurement_dispatch_started)
    , ( Measurement_unsupported
      | Measurement_local_invalid
      | Measurement_transport_failed
      | Measurement_invalid_response
      | Measurement_fence_rejected
      | Measurement_cancelled ) ) -> false
;;

let measurement_state_is_valid (measurement : measurement) =
  measurement.dispatch = Measurement_dispatch_started
  && measurement.outcome = Measurement_succeeded
;;

let rejected_measurement_receipt_state_is_valid (measurement : measurement) =
  measurement.dispatch = No_measurement_dispatch
  && measurement.outcome <> Measurement_not_required
;;

let successful_http_status = function
  | Some status -> status >= 200 && status <= 299
  | None -> false
;;

let attempt_success_state_is_valid (attempt : attempt) =
  match attempt.phase with
  | Terminal ->
    attempt.dispatch_count = 1
    && successful_http_status attempt.http_status
    && Option.is_some attempt.provider_trace_sha256
    && Option.is_some attempt.raw_response_sha256
  | Before_dispatch | Response_received -> false
;;

let attempt_advance_state_is_valid (attempt : attempt) (failure : transport_failure) =
  match failure, attempt.phase with
  | Completion_failed_before_dispatch, Before_dispatch ->
    attempt.dispatch_count = 0
    && Option.is_none attempt.http_status
    && Option.is_none attempt.provider_trace_sha256
    && Option.is_none attempt.raw_response_sha256
  | Serialized_request_refused { http_status }, Response_received ->
    http_status = 413
    && attempt.dispatch_count = 1
    && attempt.http_status = Some http_status
    && Option.is_some attempt.provider_trace_sha256
    && Option.is_some attempt.raw_response_sha256
  | Invalid_json_output, (Response_received | Terminal) ->
    attempt.dispatch_count = 1
    && successful_http_status attempt.http_status
    && Option.is_some attempt.provider_trace_sha256
    && Option.is_some attempt.raw_response_sha256
  | Candidate_rejected, _
  | Completion_failed_before_dispatch, (Response_received | Terminal)
  | Serialized_request_refused _, (Before_dispatch | Terminal)
  | Invalid_json_output, Before_dispatch -> false
;;

let check_http_status ~ordinal field = function
  | None -> Ok ()
  | Some status ->
    if status >= 100 && status <= 599
    then Ok ()
    else Error (Invalid_http_status { field; ordinal })
;;

let check_measurement
      ~ordinal
      ~(candidate : candidate)
      ~request_body_sha256
      ~measurement_ids
      ~state_is_valid
      (measurement : measurement)
  =
  let* () =
    check_identifier ~ordinal "measurement.operation_id" measurement.operation_id
  in
  let* () =
    check_sha256
      ~ordinal
      "measurement.request_body_sha256"
      measurement.request_body_sha256
  in
  let* () =
    check_sha256
      ~ordinal
      "measurement.candidate_binding_sha256"
      measurement.candidate_binding_sha256
  in
  let* () =
    check_sha256
      ~ordinal
      "measurement.catalog_generation_sha256"
      measurement.catalog_generation_sha256
  in
  let* () =
    check_sha256
      ~ordinal
      "measurement.catalog_evidence_sha256"
      measurement.catalog_evidence_sha256
  in
  let* () =
    match Hashtbl.find_opt measurement_ids measurement.operation_id with
    | None ->
      Hashtbl.add measurement_ids measurement.operation_id ordinal;
      Ok ()
    | Some first_ordinal ->
      Error
        (Duplicate_measurement_operation_id
           { operation_id = measurement.operation_id
           ; first_ordinal
           ; duplicate_ordinal = ordinal
           })
  in
  if
    (not (state_is_valid measurement))
    || not
         (Option.fold
            ~none:true
            ~some:(String.equal measurement.request_body_sha256)
            request_body_sha256
          && String.equal
               measurement.candidate_binding_sha256
               candidate.candidate_binding_sha256
          && String.equal
               measurement.catalog_generation_sha256
               candidate.catalog_generation_sha256
          && String.equal
               measurement.catalog_evidence_sha256
               candidate.catalog_evidence_sha256)
  then
    if state_is_valid measurement
    then Error (Measurement_binding_mismatch { ordinal })
    else Error (Invalid_measurement_state { ordinal })
  else Ok ()
;;

let check_attempt
      ~ordinal
      ~(candidate : candidate)
      ~(admitted : admitted)
      ~call_ids
      ~(outcome : normalized_outcome)
      (attempt : attempt)
  =
  let* () = check_identifier ~ordinal "attempt.call_id" attempt.call_id in
  let* () = check_sha256 ~ordinal "attempt.plan_sha256" attempt.plan_sha256 in
  let* () =
    check_sha256 ~ordinal "attempt.request_body_sha256" attempt.request_body_sha256
  in
  let* () =
    check_sha256
      ~ordinal
      "attempt.candidate_binding_sha256"
      attempt.candidate_binding_sha256
  in
  let* () =
    check_sha256
      ~ordinal
      "attempt.catalog_generation_sha256"
      attempt.catalog_generation_sha256
  in
  let* () =
    check_sha256
      ~ordinal
      "attempt.catalog_evidence_sha256"
      attempt.catalog_evidence_sha256
  in
  let* () =
    check_optional_sha256
      ~ordinal
      "attempt.provider_trace_sha256"
      attempt.provider_trace_sha256
  in
  let* () =
    check_optional_sha256
      ~ordinal
      "attempt.raw_response_sha256"
      attempt.raw_response_sha256
  in
  let* () = check_http_status ~ordinal "attempt.http_status" attempt.http_status in
  let* () =
    match Hashtbl.find_opt call_ids attempt.call_id with
    | None ->
      Hashtbl.add call_ids attempt.call_id ordinal;
      Ok ()
    | Some first_ordinal ->
      Error
        (Duplicate_call_id
           { call_id = attempt.call_id; first_ordinal; duplicate_ordinal = ordinal })
  in
  let provenance = admitted.provenance in
  let binding_matches =
    String.equal attempt.plan_sha256 admitted.plan_sha256
    && String.equal attempt.request_body_sha256 admitted.request_body_sha256
    && String.equal attempt.candidate_binding_sha256 candidate.candidate_binding_sha256
    && String.equal attempt.catalog_generation_sha256 candidate.catalog_generation_sha256
    && String.equal attempt.catalog_evidence_sha256 candidate.catalog_evidence_sha256
    && String.equal provenance.candidate_binding_sha256 candidate.candidate_binding_sha256
    && String.equal
         provenance.catalog_generation_sha256
         candidate.catalog_generation_sha256
    && String.equal provenance.catalog_evidence_sha256 candidate.catalog_evidence_sha256
  in
  if not binding_matches
  then Error (Attempt_binding_mismatch { ordinal })
  else (
    match outcome with
    | Normalized_accepted _ | Normalized_semantic_rejected _ ->
      if attempt_success_state_is_valid attempt
      then Ok ()
      else Error (Invalid_attempt_state { ordinal })
    | Normalized_advance { failure; _ } ->
      if attempt_advance_state_is_valid attempt failure
      then Ok ()
      else Error (Invalid_attempt_state { ordinal }))
;;
