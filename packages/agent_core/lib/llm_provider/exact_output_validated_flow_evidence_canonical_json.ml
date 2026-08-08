open Exact_output_validated_flow_evidence_types

let ( let* ) = Result.bind
let digest value = Digestif.SHA256.(to_hex (digest_string value))

let is_sha256 value =
  String.length value = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       value
;;

let is_canonical_identifier value =
  (not (String.equal value "")) && String.equal value (String.trim value)
;;

let duplicate_key fields =
  let seen = Hashtbl.create (List.length fields) in
  List.find_map
    (fun (key, _) ->
       if Hashtbl.mem seen key
       then Some key
       else (
         Hashtbl.add seen key ();
         None))
    fields
;;

let rec canonicalize_projector_json (json : Yojson.Safe.t) : (Yojson.Safe.t, unit) result =
  match json with
  | `Assoc fields ->
    (match duplicate_key fields with
     | Some _ -> Error ()
     | None ->
       let rec loop acc = function
         | [] ->
           Ok
             (`Assoc
                 (List.sort (fun (left, _) (right, _) -> String.compare left right) acc))
         | (key, value) :: rest ->
           let* value = canonicalize_projector_json value in
           loop ((key, value) :: acc) rest
       in
       loop [] fields)
  | `List values ->
    let rec loop acc = function
      | [] -> Ok (`List (List.rev acc))
      | value :: rest ->
        let* value = canonicalize_projector_json value in
        loop (value :: acc) rest
    in
    loop [] values
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `String _) as scalar -> Ok scalar
  | `Float value when Float.is_finite value -> Ok (`Float value)
  | `Float _ -> Error ()
;;

let projector ~ordinal ~location json =
  try
    match canonicalize_projector_json json with
    | Error () -> Error (Invalid_projector_json { ordinal; location })
    | Ok json ->
      let canonical = Yojson.Safe.to_string json in
      (match Yojson.Safe.from_string canonical with
       | reparsed when String.equal canonical (Yojson.Safe.to_string reparsed) ->
         Ok { json; digest = digest canonical }
       | _ -> Error (Invalid_projector_json { ordinal; location })
       | exception Yojson.Json_error _ ->
         Error (Invalid_projector_json { ordinal; location }))
  with
  | Stack_overflow -> Error (Invalid_projector_json { ordinal; location })
;;

let assurance_to_string = function
  | Json_syntax_only -> "json_syntax_only"
  | Provider_schema_requested -> "provider_schema_requested"
;;

let measurement_dispatch_to_string = function
  | No_measurement_dispatch -> "no_dispatch"
  | Measurement_dispatch_started -> "dispatch_started"
;;

let measurement_outcome_to_string = function
  | Measurement_not_required -> "not_required"
  | Measurement_succeeded -> "succeeded"
  | Measurement_unsupported -> "unsupported"
  | Measurement_local_invalid -> "local_invalid"
  | Measurement_transport_failed -> "transport_failed"
  | Measurement_invalid_response -> "invalid_response"
  | Measurement_fence_rejected -> "fence_rejected"
  | Measurement_cancelled -> "cancelled"
;;

let attempt_phase_to_string = function
  | Before_dispatch -> "before_dispatch"
  | Response_received -> "response_received"
  | Terminal -> "terminal"
;;

let candidate_json (candidate : candidate) =
  `Assoc
    [ "candidate_id", `String candidate.candidate_id
    ; "candidate_binding_sha256", `String candidate.candidate_binding_sha256
    ; "catalog_generation_sha256", `String candidate.catalog_generation_sha256
    ; "catalog_evidence_sha256", `String candidate.catalog_evidence_sha256
    ]
;;

let provenance_json (provenance : provenance) =
  `Assoc
    [ "source_schema_sha256", `String provenance.source_schema_sha256
    ; ( "effective_schema_sha256"
      , Option.fold
          ~none:`Null
          ~some:(fun value -> `String value)
          provenance.effective_schema_sha256 )
    ; "assurance", `String (assurance_to_string provenance.assurance)
    ; "candidate_binding_sha256", `String provenance.candidate_binding_sha256
    ; "catalog_generation_sha256", `String provenance.catalog_generation_sha256
    ; "catalog_evidence_sha256", `String provenance.catalog_evidence_sha256
    ]
;;

let measurement_evidence_json (measurement : measurement_evidence) =
  `Assoc
    [ "dispatch", `String (measurement_dispatch_to_string measurement.dispatch)
    ; "outcome", `String (measurement_outcome_to_string measurement.outcome)
    ]
;;

let admission_json (admission : normalized_admission) =
  match admission with
  | Normalized_rejected rejected ->
    `Assoc
      [ "kind", `String "rejected"
      ; "rejection", rejected.rejection.json
      ; "measurement", measurement_evidence_json rejected.measurement
      ]
  | Normalized_admitted admitted ->
    `Assoc
      [ "kind", `String "admitted"
      ; "plan_sha256", `String admitted.plan_sha256
      ; "request_body_sha256", `String admitted.request_body_sha256
      ; "provenance", provenance_json admitted.provenance
      ; "measurement", measurement_evidence_json admitted.measurement
      ]
;;

let measurement_json (measurement : measurement) =
  `Assoc
    [ "operation_id", `String measurement.operation_id
    ; "request_body_sha256", `String measurement.request_body_sha256
    ; "candidate_binding_sha256", `String measurement.candidate_binding_sha256
    ; "catalog_generation_sha256", `String measurement.catalog_generation_sha256
    ; "catalog_evidence_sha256", `String measurement.catalog_evidence_sha256
    ; "dispatch", `String (measurement_dispatch_to_string measurement.dispatch)
    ; "outcome", `String (measurement_outcome_to_string measurement.outcome)
    ]
;;

let attempt_json (attempt : attempt) =
  let optional_string = Option.fold ~none:`Null ~some:(fun value -> `String value) in
  `Assoc
    [ "call_id", `String attempt.call_id
    ; "plan_sha256", `String attempt.plan_sha256
    ; "request_body_sha256", `String attempt.request_body_sha256
    ; "candidate_binding_sha256", `String attempt.candidate_binding_sha256
    ; "catalog_generation_sha256", `String attempt.catalog_generation_sha256
    ; "catalog_evidence_sha256", `String attempt.catalog_evidence_sha256
    ; "phase", `String (attempt_phase_to_string attempt.phase)
    ; "dispatch_count", `Int attempt.dispatch_count
    ; ( "http_status"
      , Option.fold ~none:`Null ~some:(fun status -> `Int status) attempt.http_status )
    ; "provider_trace_sha256", optional_string attempt.provider_trace_sha256
    ; "raw_response_sha256", optional_string attempt.raw_response_sha256
    ]
;;

let failure_json = function
  | Candidate_rejected -> `Assoc [ "kind", `String "candidate_rejected" ]
  | Completion_failed_before_dispatch ->
    `Assoc [ "kind", `String "completion_failed_before_dispatch" ]
  | Serialized_request_refused { http_status } ->
    `Assoc
      [ "kind", `String "serialized_request_refused"; "http_status", `Int http_status ]
  | Invalid_json_output -> `Assoc [ "kind", `String "invalid_json_output" ]
;;

let outcome_json = function
  | Normalized_advance advance ->
    `Assoc
      [ "kind", `String "advance"
      ; "next_ordinal", `Int advance.next_ordinal
      ; "failure", failure_json advance.failure
      ]
  | Normalized_semantic_rejected { projector; output_sha256 } ->
    `Assoc
      [ "kind", `String "semantic_rejected"
      ; "projector", projector.json
      ; "output_sha256", `String output_sha256
      ]
  | Normalized_accepted { projector; output_sha256 } ->
    `Assoc
      [ "kind", `String "accepted"
      ; "projector", projector.json
      ; "output_sha256", `String output_sha256
      ]
;;

let step_json (step : normalized_step) =
  `Assoc
    [ "ordinal", `Int step.ordinal
    ; "admission", admission_json step.admission
    ; "measurement", Option.fold ~none:`Null ~some:measurement_json step.measurement
    ; "attempt", Option.fold ~none:`Null ~some:attempt_json step.attempt
    ; "outcome", outcome_json step.outcome
    ]
;;

let payload_json ~flow_id ~declared_candidates ~steps =
  `Assoc
    [ "flow_id", `String flow_id
    ; ( "declared_candidates"
      , `List (Array.to_list declared_candidates |> List.map candidate_json) )
    ; "steps", `List (Array.to_list steps |> List.map step_json)
    ]
;;

let payload_string ~flow_id ~declared_candidates ~steps =
  payload_json ~flow_id ~declared_candidates ~steps |> Yojson.Safe.to_string
;;

let document_json transcript =
  `Assoc
    [ "flow_id", `String transcript.flow_id
    ; ( "declared_candidates"
      , `List (Array.to_list transcript.declared_candidates |> List.map candidate_json) )
    ; "steps", `List (Array.to_list transcript.steps |> List.map step_json)
    ; "integrity_sha256", `String transcript.integrity_sha256
    ]
;;
