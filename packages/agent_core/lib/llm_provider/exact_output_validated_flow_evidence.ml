include Exact_output_validated_flow_evidence_types
module Json = Exact_output_validated_flow_evidence_canonical_json
module Validation = Exact_output_validated_flow_evidence_validation
module Codec = Exact_output_validated_flow_evidence_codec

let ( let* ) = Result.bind

let create ~flow_id ~declared_candidates ~steps =
  let* () = if Json.is_canonical_identifier flow_id then Ok () else Error Empty_flow_id in
  let* declared_candidates, steps, accepted_sha256 =
    Validation.normalize ~declared_candidates ~steps
  in
  let integrity_sha256 =
    Json.payload_string ~flow_id ~declared_candidates ~steps |> Json.digest
  in
  Ok { flow_id; declared_candidates; steps; integrity_sha256; accepted_sha256 }
;;

let to_string transcript = Json.document_json transcript |> Yojson.Safe.to_string
let sha256 transcript = transcript.integrity_sha256
let accepted_domain_sha256 transcript = transcript.accepted_sha256

let of_string encoded =
  try
    match Codec.parse encoded with
    | Error error -> Error error
    | Ok parsed ->
      (match
         create
           ~flow_id:parsed.flow_id
           ~declared_candidates:parsed.declared_candidates
           ~steps:parsed.steps
       with
       | Error error -> Error (Invalid_transcript error)
       | Ok transcript ->
         if not (String.equal parsed.integrity_sha256 transcript.integrity_sha256)
         then Error Integrity_mismatch
         else if not (String.equal encoded (to_string transcript))
         then Error Non_canonical_encoding
         else Ok transcript)
  with
  | Yojson.Json_error detail -> Error (Malformed_json detail)
  | Stack_overflow -> Error (Malformed_json "JSON nesting exhausted the parser stack")
;;

let invariant_error_to_string = function
  | Empty_flow_id -> "flow_id must be nonempty and canonical"
  | Empty_declared_candidates -> "declared candidate snapshot must be nonempty"
  | Empty_steps -> "successful transcript must contain at least one step"
  | Non_canonical_identifier { field; ordinal } ->
    Printf.sprintf
      "%s%s must be nonempty and canonical"
      (Option.fold
         ~none:""
         ~some:(fun ordinal -> Printf.sprintf "step %d " ordinal)
         ordinal)
      field
  | Invalid_sha256 { field; ordinal } ->
    Printf.sprintf
      "%s%s must be a lowercase SHA-256"
      (Option.fold
         ~none:""
         ~some:(fun ordinal -> Printf.sprintf "step %d " ordinal)
         ordinal)
      field
  | Invalid_http_status { field; ordinal } ->
    Printf.sprintf "step %d %s must be a valid HTTP status" ordinal field
  | Duplicate_candidate_id { candidate_id; first_position; duplicate_position } ->
    Printf.sprintf
      "candidate_id %s is duplicated at positions %d and %d"
      candidate_id
      first_position
      duplicate_position
  | Duplicate_call_id { call_id; first_ordinal; duplicate_ordinal } ->
    Printf.sprintf
      "call_id %s is duplicated at steps %d and %d"
      call_id
      first_ordinal
      duplicate_ordinal
  | Duplicate_measurement_operation_id { operation_id; first_ordinal; duplicate_ordinal }
    ->
    Printf.sprintf
      "measurement operation_id %s is duplicated at steps %d and %d"
      operation_id
      first_ordinal
      duplicate_ordinal
  | More_steps_than_declared_candidates ->
    "visited steps exceed the declared candidate snapshot"
  | Non_contiguous_step_ordinal { expected; actual } ->
    Printf.sprintf "step ordinal is not contiguous: expected %d, got %d" expected actual
  | Invalid_measurement_state { ordinal } ->
    Printf.sprintf "step %d measurement dispatch/outcome state is invalid" ordinal
  | Measurement_binding_mismatch { ordinal } ->
    Printf.sprintf "step %d measurement binding does not match its candidate" ordinal
  | Rejected_admission_has_attempt { ordinal } ->
    Printf.sprintf "step %d rejected admission has a generation attempt" ordinal
  | Rejected_admission_did_not_advance { ordinal } ->
    Printf.sprintf "step %d rejected admission did not advance as rejected" ordinal
  | Admitted_candidate_missing_attempt { ordinal } ->
    Printf.sprintf "step %d admitted candidate has no generation attempt" ordinal
  | Attempt_binding_mismatch { ordinal } ->
    Printf.sprintf "step %d attempt/provenance binding is inconsistent" ordinal
  | Invalid_attempt_state { ordinal } ->
    Printf.sprintf "step %d attempt phase/dispatch/status state is invalid" ordinal
  | Non_adjacent_advance { ordinal; next_ordinal } ->
    Printf.sprintf "step %d advances to nonadjacent ordinal %d" ordinal next_ordinal
  | Advance_failure_mismatch { ordinal } ->
    Printf.sprintf "step %d advance failure contradicts its admission" ordinal
  | Nonfinal_step_accepted { ordinal } ->
    Printf.sprintf "nonfinal step %d is accepted" ordinal
  | Final_step_not_accepted { ordinal } ->
    Printf.sprintf "final step %d is not accepted" ordinal
  | Invalid_projector_json { ordinal; location } ->
    Printf.sprintf "step %d %s is not canonicalizable JSON" ordinal location
;;

let decode_error_to_string = function
  | Malformed_json detail -> "validated flow evidence malformed JSON: " ^ detail
  | Invalid_fields { path; detail } ->
    Printf.sprintf "validated flow evidence invalid at %s: %s" path detail
  | Invalid_transcript error ->
    "validated flow evidence violates an invariant: " ^ invariant_error_to_string error
  | Integrity_mismatch -> "validated flow evidence integrity mismatch"
  | Non_canonical_encoding -> "validated flow evidence is not canonical current JSON"
;;
