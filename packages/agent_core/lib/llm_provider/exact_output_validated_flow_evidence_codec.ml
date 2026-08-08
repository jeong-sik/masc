open Exact_output_validated_flow_evidence_types
module Json = Exact_output_validated_flow_evidence_canonical_json

type parsed =
  { flow_id : string
  ; declared_candidates : candidate list
  ; steps : step list
  ; integrity_sha256 : string
  }

let ( let* ) = Result.bind
let invalid_fields path detail = Error (Invalid_fields { path; detail })

let exact_assoc ~path expected = function
  | `Assoc fields ->
    (match Json.duplicate_key fields with
     | Some key -> invalid_fields path ("duplicate field: " ^ key)
     | None ->
       let actual = List.map fst fields |> List.sort String.compare in
       let expected = List.sort String.compare expected in
       if actual = expected
       then Ok fields
       else invalid_fields path "fields do not match current schema")
  | _ -> invalid_fields path "expected object"
;;

let field ~path fields name =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> invalid_fields (path ^ "." ^ name) "missing field"
;;

let string_field ~path fields name =
  let* value = field ~path fields name in
  match value with
  | `String value -> Ok value
  | _ -> invalid_fields (path ^ "." ^ name) "expected string"
;;

let int_field ~path fields name =
  let* value = field ~path fields name in
  match value with
  | `Int value -> Ok value
  | _ -> invalid_fields (path ^ "." ^ name) "expected integer"
;;

let optional_string_field ~path fields name =
  let* value = field ~path fields name in
  match value with
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ -> invalid_fields (path ^ "." ^ name) "expected string or null"
;;

let optional_int_field ~path fields name =
  let* value = field ~path fields name in
  match value with
  | `Null -> Ok None
  | `Int value -> Ok (Some value)
  | _ -> invalid_fields (path ^ "." ^ name) "expected integer or null"
;;

let list_field ~path fields name =
  let* value = field ~path fields name in
  match value with
  | `List values -> Ok values
  | _ -> invalid_fields (path ^ "." ^ name) "expected array"
;;

let parse_candidate ~path json =
  let* fields =
    exact_assoc
      ~path
      [ "candidate_id"
      ; "candidate_binding_sha256"
      ; "catalog_generation_sha256"
      ; "catalog_evidence_sha256"
      ]
      json
  in
  let* candidate_id = string_field ~path fields "candidate_id" in
  let* candidate_binding_sha256 = string_field ~path fields "candidate_binding_sha256" in
  let* catalog_generation_sha256 =
    string_field ~path fields "catalog_generation_sha256"
  in
  let* catalog_evidence_sha256 = string_field ~path fields "catalog_evidence_sha256" in
  Ok
    { candidate_id
    ; candidate_binding_sha256
    ; catalog_generation_sha256
    ; catalog_evidence_sha256
    }
;;

let assurance_of_string ~path = function
  | "json_syntax_only" -> Ok Json_syntax_only
  | "provider_schema_requested" -> Ok Provider_schema_requested
  | _ -> invalid_fields path "unknown assurance"
;;

let parse_provenance ~path json =
  let* fields =
    exact_assoc
      ~path
      [ "source_schema_sha256"
      ; "effective_schema_sha256"
      ; "assurance"
      ; "candidate_binding_sha256"
      ; "catalog_generation_sha256"
      ; "catalog_evidence_sha256"
      ]
      json
  in
  let* source_schema_sha256 = string_field ~path fields "source_schema_sha256" in
  let* effective_schema_sha256 =
    optional_string_field ~path fields "effective_schema_sha256"
  in
  let* assurance_value = string_field ~path fields "assurance" in
  let* assurance = assurance_of_string ~path:(path ^ ".assurance") assurance_value in
  let* candidate_binding_sha256 = string_field ~path fields "candidate_binding_sha256" in
  let* catalog_generation_sha256 =
    string_field ~path fields "catalog_generation_sha256"
  in
  let* catalog_evidence_sha256 = string_field ~path fields "catalog_evidence_sha256" in
  Ok
    { source_schema_sha256
    ; effective_schema_sha256
    ; assurance
    ; candidate_binding_sha256
    ; catalog_generation_sha256
    ; catalog_evidence_sha256
    }
;;

let measurement_dispatch_of_string ~path = function
  | "no_dispatch" -> Ok No_measurement_dispatch
  | "dispatch_started" -> Ok Measurement_dispatch_started
  | _ -> invalid_fields path "unknown measurement dispatch"
;;

let measurement_outcome_of_string ~path = function
  | "not_required" -> Ok Measurement_not_required
  | "succeeded" -> Ok Measurement_succeeded
  | "unsupported" -> Ok Measurement_unsupported
  | "local_invalid" -> Ok Measurement_local_invalid
  | "transport_failed" -> Ok Measurement_transport_failed
  | "invalid_response" -> Ok Measurement_invalid_response
  | "fence_rejected" -> Ok Measurement_fence_rejected
  | "cancelled" -> Ok Measurement_cancelled
  | _ -> invalid_fields path "unknown measurement outcome"
;;

let parse_measurement_evidence ~path json =
  let* fields = exact_assoc ~path [ "dispatch"; "outcome" ] json in
  let* dispatch_value = string_field ~path fields "dispatch" in
  let* dispatch =
    measurement_dispatch_of_string ~path:(path ^ ".dispatch") dispatch_value
  in
  let* outcome_value = string_field ~path fields "outcome" in
  let* outcome = measurement_outcome_of_string ~path:(path ^ ".outcome") outcome_value in
  Ok { dispatch; outcome }
;;

let parse_admission ~path json =
  match json with
  | `Assoc raw_fields ->
    (match List.assoc_opt "kind" raw_fields with
     | Some (`String "rejected") ->
       let* fields = exact_assoc ~path [ "kind"; "rejection"; "measurement" ] json in
       let* rejection = field ~path fields "rejection" in
       let* measurement_json = field ~path fields "measurement" in
       let* measurement =
         parse_measurement_evidence ~path:(path ^ ".measurement") measurement_json
       in
       Ok (Rejected { rejection; measurement })
     | Some (`String "admitted") ->
       let* fields =
         exact_assoc
           ~path
           [ "kind"; "plan_sha256"; "request_body_sha256"; "provenance"; "measurement" ]
           json
       in
       let* plan_sha256 = string_field ~path fields "plan_sha256" in
       let* request_body_sha256 = string_field ~path fields "request_body_sha256" in
       let* provenance_json = field ~path fields "provenance" in
       let* provenance = parse_provenance ~path:(path ^ ".provenance") provenance_json in
       let* measurement_json = field ~path fields "measurement" in
       let* measurement =
         parse_measurement_evidence ~path:(path ^ ".measurement") measurement_json
       in
       Ok (Admitted { plan_sha256; request_body_sha256; provenance; measurement })
     | Some (`String _) -> invalid_fields (path ^ ".kind") "unknown admission kind"
     | Some _ -> invalid_fields (path ^ ".kind") "expected string"
     | None -> invalid_fields (path ^ ".kind") "missing field")
  | _ -> invalid_fields path "expected object"
;;

let parse_measurement ~path json =
  match json with
  | `Null -> Ok None
  | _ ->
    let* fields =
      exact_assoc
        ~path
        [ "operation_id"
        ; "request_body_sha256"
        ; "candidate_binding_sha256"
        ; "catalog_generation_sha256"
        ; "catalog_evidence_sha256"
        ; "dispatch"
        ; "outcome"
        ]
        json
    in
    let* operation_id = string_field ~path fields "operation_id" in
    let* request_body_sha256 = string_field ~path fields "request_body_sha256" in
    let* candidate_binding_sha256 =
      string_field ~path fields "candidate_binding_sha256"
    in
    let* catalog_generation_sha256 =
      string_field ~path fields "catalog_generation_sha256"
    in
    let* catalog_evidence_sha256 = string_field ~path fields "catalog_evidence_sha256" in
    let* dispatch_value = string_field ~path fields "dispatch" in
    let* dispatch =
      measurement_dispatch_of_string ~path:(path ^ ".dispatch") dispatch_value
    in
    let* outcome_value = string_field ~path fields "outcome" in
    let* outcome =
      measurement_outcome_of_string ~path:(path ^ ".outcome") outcome_value
    in
    Ok
      (Some
         { operation_id
         ; request_body_sha256
         ; candidate_binding_sha256
         ; catalog_generation_sha256
         ; catalog_evidence_sha256
         ; dispatch
         ; outcome
         })
;;

let attempt_phase_of_string ~path = function
  | "before_dispatch" -> Ok Before_dispatch
  | "response_received" -> Ok Response_received
  | "terminal" -> Ok Terminal
  | _ -> invalid_fields path "unknown attempt phase"
;;

let parse_attempt ~path json =
  match json with
  | `Null -> Ok None
  | _ ->
    let* fields =
      exact_assoc
        ~path
        [ "call_id"
        ; "plan_sha256"
        ; "request_body_sha256"
        ; "candidate_binding_sha256"
        ; "catalog_generation_sha256"
        ; "catalog_evidence_sha256"
        ; "phase"
        ; "dispatch_count"
        ; "http_status"
        ; "provider_trace_sha256"
        ; "raw_response_sha256"
        ]
        json
    in
    let* call_id = string_field ~path fields "call_id" in
    let* plan_sha256 = string_field ~path fields "plan_sha256" in
    let* request_body_sha256 = string_field ~path fields "request_body_sha256" in
    let* candidate_binding_sha256 =
      string_field ~path fields "candidate_binding_sha256"
    in
    let* catalog_generation_sha256 =
      string_field ~path fields "catalog_generation_sha256"
    in
    let* catalog_evidence_sha256 = string_field ~path fields "catalog_evidence_sha256" in
    let* phase_value = string_field ~path fields "phase" in
    let* phase = attempt_phase_of_string ~path:(path ^ ".phase") phase_value in
    let* dispatch_count = int_field ~path fields "dispatch_count" in
    let* http_status = optional_int_field ~path fields "http_status" in
    let* provider_trace_sha256 =
      optional_string_field ~path fields "provider_trace_sha256"
    in
    let* raw_response_sha256 = optional_string_field ~path fields "raw_response_sha256" in
    Ok
      (Some
         { call_id
         ; plan_sha256
         ; request_body_sha256
         ; candidate_binding_sha256
         ; catalog_generation_sha256
         ; catalog_evidence_sha256
         ; phase
         ; dispatch_count
         ; http_status
         ; provider_trace_sha256
         ; raw_response_sha256
         })
;;

let parse_failure ~path json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "candidate_rejected") ->
       let* _ = exact_assoc ~path [ "kind" ] json in
       Ok Candidate_rejected
     | Some (`String "completion_failed_before_dispatch") ->
       let* _ = exact_assoc ~path [ "kind" ] json in
       Ok Completion_failed_before_dispatch
     | Some (`String "serialized_request_refused") ->
       let* fields = exact_assoc ~path [ "kind"; "http_status" ] json in
       let* http_status = int_field ~path fields "http_status" in
       Ok (Serialized_request_refused { http_status })
     | Some (`String "invalid_json_output") ->
       let* _ = exact_assoc ~path [ "kind" ] json in
       Ok Invalid_json_output
     | Some (`String _) -> invalid_fields (path ^ ".kind") "unknown failure kind"
     | Some _ -> invalid_fields (path ^ ".kind") "expected string"
     | None -> invalid_fields (path ^ ".kind") "missing field")
  | _ -> invalid_fields path "expected object"
;;

let parse_outcome ~path json =
  match json with
  | `Assoc raw_fields ->
    (match List.assoc_opt "kind" raw_fields with
     | Some (`String "advance") ->
       let* fields = exact_assoc ~path [ "kind"; "next_ordinal"; "failure" ] json in
       let* next_ordinal = int_field ~path fields "next_ordinal" in
       let* failure_json = field ~path fields "failure" in
       let* failure = parse_failure ~path:(path ^ ".failure") failure_json in
       Ok (Advance { next_ordinal; failure })
     | Some (`String "semantic_rejected") ->
       let* fields = exact_assoc ~path [ "kind"; "projector"; "output_sha256" ] json in
       let* projector = field ~path fields "projector" in
       let* output_sha256 = string_field ~path fields "output_sha256" in
       Ok (Semantic_rejected { projector; output_sha256 })
     | Some (`String "accepted") ->
       let* fields = exact_assoc ~path [ "kind"; "projector"; "output_sha256" ] json in
       let* projector = field ~path fields "projector" in
       let* output_sha256 = string_field ~path fields "output_sha256" in
       Ok (Accepted { projector; output_sha256 })
     | Some (`String _) -> invalid_fields (path ^ ".kind") "unknown outcome kind"
     | Some _ -> invalid_fields (path ^ ".kind") "expected string"
     | None -> invalid_fields (path ^ ".kind") "missing field")
  | _ -> invalid_fields path "expected object"
;;

let parse_step ~index json : (step, decode_error) result =
  let path = Printf.sprintf "$.steps[%d]" index in
  let* fields =
    exact_assoc ~path [ "ordinal"; "admission"; "measurement"; "attempt"; "outcome" ] json
  in
  let* ordinal = int_field ~path fields "ordinal" in
  let* admission_json = field ~path fields "admission" in
  let* admission = parse_admission ~path:(path ^ ".admission") admission_json in
  let* measurement_json = field ~path fields "measurement" in
  let* measurement = parse_measurement ~path:(path ^ ".measurement") measurement_json in
  let* attempt_json = field ~path fields "attempt" in
  let* attempt = parse_attempt ~path:(path ^ ".attempt") attempt_json in
  let* outcome_json = field ~path fields "outcome" in
  let* outcome = parse_outcome ~path:(path ^ ".outcome") outcome_json in
  Ok ({ ordinal; admission; measurement; attempt; outcome } : step)
;;

let rec parse_list_indexed parse index acc = function
  | [] -> Ok (List.rev acc)
  | value :: rest ->
    let* value = parse ~index value in
    parse_list_indexed parse (index + 1) (value :: acc) rest
;;

let parse encoded =
  let json = Yojson.Safe.from_string encoded in
  let* fields =
    exact_assoc
      ~path:"$"
      [ "flow_id"; "declared_candidates"; "steps"; "integrity_sha256" ]
      json
  in
  let* flow_id = string_field ~path:"$" fields "flow_id" in
  let* declared_json = list_field ~path:"$" fields "declared_candidates" in
  let* declared_candidates =
    parse_list_indexed
      (fun ~index value ->
         parse_candidate ~path:(Printf.sprintf "$.declared_candidates[%d]" index) value)
      0
      []
      declared_json
  in
  let* steps_json = list_field ~path:"$" fields "steps" in
  let* steps = parse_list_indexed parse_step 0 [] steps_json in
  let* integrity_sha256 = string_field ~path:"$" fields "integrity_sha256" in
  if not (Json.is_sha256 integrity_sha256)
  then invalid_fields "$.integrity_sha256" "expected lowercase SHA-256"
  else Ok { flow_id; declared_candidates; steps; integrity_sha256 }
;;
