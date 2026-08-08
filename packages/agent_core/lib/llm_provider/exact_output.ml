module Plan = Exact_output_plan
module Flow_admission = Exact_output_flow_admission
module Measurement_receipt = Exact_output_measurement_receipt
include Measurement_receipt
module Exec = Exact_output_execution
module Flow_state = Exact_output_flow
module Trace = Exact_output_provider_trace
module Generation_receipt = Exact_output_generation_receipt
module Validated_flow_evidence = Exact_output_validated_flow_evidence
include Exact_output_resolver
include Exact_output_ready_admission

let project_request_body ~target ~messages requirement =
  Exact_output_ready_admission.project_request_body
    ~target:(Exact_output_resolver.projection_target target)
    ~messages
    requirement
;;

let plan_provenance_source_schema_fingerprint (provenance : plan_provenance) =
  provenance.source_schema_fingerprint
;;

let plan_provenance_effective_schema_fingerprint (provenance : plan_provenance) =
  provenance.effective_schema_fingerprint
;;

let plan_provenance_actual_assurance (provenance : plan_provenance) =
  provenance.actual_assurance
;;

let plan_provenance_catalog_generation (provenance : plan_provenance) =
  provenance.catalog_generation
;;

let plan_provenance_catalog_evidence (provenance : plan_provenance) =
  provenance.catalog_evidence
;;

let plan_provenance_target_identity (provenance : plan_provenance) =
  provenance.target_identity
;;

type call_id = Generation_receipt.call_id = Call_id of string
type provider_trace = Trace.t
type receipt = Generation_receipt.t

type attempt =
  { ready : ready_plan
  ; receipt : receipt
  }

type input_capacity_disposition =
  | Token_measurement_required of
      { accepted_through_tokens : int
      ; rejected_from_tokens : int option
      }
  | Context_window_exceeded of
      { input_tokens : int
      ; reserved_output_tokens : int
      ; max_context_tokens : int
      }
  | Token_capacity_rejected of token_capacity_rejection
  | Serialized_request_body_too_large of
      { actual_bytes : int
      ; limit_bytes : int
      }

type candidate_rejection_disposition =
  | Runtime_slot_unavailable
  | Runtime_contract_rejected
  | Input_contract_rejected
  | Output_requirement_rejected
  | Input_capacity of input_capacity_disposition
  | Request_preparation_failed

type effect_phase = Generation_receipt.effect_phase =
  | Not_started
  | Before_dispatch
  | Dispatch_started
  | Response_received
  | Terminal

type generation_receipt_snapshot = Generation_receipt.snapshot

type raw_response = Trace.raw_response =
  { body : string
  ; body_sha256 : string
  }

type execution_error_cause =
  | Attempt_already_started
  | Clock_required_for_timeout
  | Frozen_request_mismatch
  | Completion_failed
  | Serialized_request_refused of { http_status : int }
  | Incomplete_output
  | Missing_output
  | Ambiguous_output of int
  | Unexpected_output_content
  | Invalid_json_output
  | Internal_non_json_output

type execution_error =
  { call_id : call_id
  ; receipt : receipt
  ; cause : execution_error_cause
  ; raw_response : raw_response option
  }

type success =
  { call_id : call_id
  ; receipt : receipt
  ; output : Yojson.Safe.t
  ; provenance : plan_provenance
  ; raw_response : raw_response
  }

type flow_candidate_identity =
  { candidate_id : string
  ; catalog_generation : catalog_generation
  ; catalog_evidence : catalog_evidence
  ; target_identity : target_identity
  }

type flow_candidate =
  { identity : flow_candidate_identity
  ; admitted_target : admitted_target
  }

type candidate_visit_count = Candidate_visit_count of int

type flow_candidate_visit =
  { flow_id : flow_id
  ; ordinal : flow_visit_ordinal
  ; identity : flow_candidate_identity
  }

type flow_measurement_receipt =
  { visit : flow_candidate_visit
  ; receipt : Flow_admission.measurement_receipt
  }

type flow_candidate_step =
  { visit : flow_candidate_visit
  ; admitted_target : admitted_target
  }

type candidate_rejection_cause =
  | Target_selection_rejected of target_selection_error
  | Request_admission_rejected of admission_error

type candidate_rejection_receipt =
  { visit : flow_candidate_visit
  ; cause : candidate_rejection_cause
  ; measurement : measurement_evidence
  }

type admitted_flow_candidate =
  { visit : flow_candidate_visit
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; provenance : plan_provenance
  ; measurement : measurement_evidence
  }

type candidate_admission =
  | Candidate_admitted of admitted_flow_candidate
  | Candidate_rejected of candidate_rejection_receipt

type flow_snapshot =
  { candidates : flow_candidate list
  ; messages : Types.message list
  ; requirement : output_requirement
  }

type flow_attempt_receipt =
  { visit : flow_candidate_visit
  ; receipt : receipt
  }

type flow_attempt_snapshot =
  { visit : flow_candidate_visit
  ; receipt : generation_receipt_snapshot
  }

type flow_advance_failure_snapshot =
  | Flow_advance_candidate_rejected of candidate_rejection_receipt
  | Flow_advance_execution_failed of
      { candidate : flow_attempt_snapshot
      ; cause : execution_error_cause
      ; raw_response_sha256 : string option
      }

type flow_advance_receipt =
  { failed : flow_advance_failure_snapshot
  ; next : flow_candidate_visit
  }

type flow_attempt_publication =
  { call_id : call_id
  ; snapshot : flow_attempt_snapshot
  }

type flow_attempt =
  { execution : Flow_state.t
  ; flow_id : flow_id
  ; declared_candidate_snapshot : flow_candidate_identity list
  ; candidates : flow_candidate_step list
  ; messages : Types.message list
  ; requirement : output_requirement
  ; progress :
      ( candidate_admission
        , flow_attempt_publication
        , measurement_receipt_snapshot
        , flow_advance_receipt )
        Flow_state.progress
  }

type flow_candidate_error = Blank_flow_candidate_id

type flow_snapshot_error =
  | Duplicate_flow_candidate_id of
      { candidate_id : string
      ; first_position : int
      ; duplicate_position : int
      }

type start_attempt_error = Call_id_generation_failed of string

type measurement_start_error =
  | Measurement_operation_id_generation_failed of string
  | Measurement_clock_required_for_timeout

type flow_start_error = Flow_id_generation_failed of string

type flow_evidence =
  { flow_id : flow_id
  ; declared_candidate_snapshot : flow_candidate_identity list
  ; candidate_visit_count : candidate_visit_count
  ; measurements : measurement_receipt_snapshot list
  ; admissions : candidate_admission list
  ; attempts : flow_attempt_snapshot list
  ; advances : flow_advance_receipt list
  }

type flow_success =
  { candidate : flow_attempt_receipt
  ; success : success
  ; evidence : flow_evidence
  }

type ('accepted, 'rejection) semantic_verdict =
  | Accept of 'accepted
  | Reject_and_advance of 'rejection

type 'rejection semantic_rejection_receipt =
  { transport_success : flow_success
  ; rejection : 'rejection
  }

type 'rejection semantic_rejection_trace =
  { first : 'rejection semantic_rejection_receipt
  ; rest : 'rejection semantic_rejection_receipt list
  }

type ('accepted, 'rejection) validated_flow_success =
  { accepted : 'accepted
  ; transport_success : flow_success
  ; prior_rejections : 'rejection semantic_rejection_receipt list
  }

type validated_flow_evidence_snapshot = Validated_flow_evidence.t

type validated_flow_evidence_source_error =
  | Evidence_ordinal_out_of_bounds of
      { collection : string
      ; ordinal : int
      ; visited_candidates : int
      }
  | Evidence_duplicate_ordinal of
      { collection : string
      ; ordinal : int
      }
  | Evidence_missing_entry of
      { collection : string
      ; ordinal : int
      }
  | Evidence_unexpected_entry of
      { collection : string
      ; ordinal : int
      }
  | Evidence_flow_identity_mismatch of
      { collection : string
      ; ordinal : int
      }
  | Evidence_unsupported_state of
      { collection : string
      ; ordinal : int
      ; detail : string
      }

type validated_flow_evidence_invariant_error = Validated_flow_evidence.invariant_error
type validated_flow_evidence_decode_error = Validated_flow_evidence.decode_error

type ('accepted_error, 'rejection_error) validated_flow_evidence_projection_error =
  | Accepted_evidence_projection_failed of 'accepted_error
  | Rejection_evidence_projection_failed of
      { ordinal : int
      ; cause : 'rejection_error
      }
  | Validated_flow_source_evidence_invalid of validated_flow_evidence_source_error
  | Validated_flow_evidence_invariant_failed of validated_flow_evidence_invariant_error

type validated_flow_projected_success =
  { ordinal : int
  ; projector : Yojson.Safe.t
  ; output_sha256 : string
  ; raw_response_sha256 : string
  ; call_id : string
  }

type flow_candidate_failure =
  | Flow_candidate_rejected of candidate_rejection_receipt
  | Flow_candidate_execution_failed of
      { candidate : flow_attempt_receipt
      ; cause : execution_error
      }

type generation_dispatch_fact =
  | No_generation_dispatch
  | Generation_dispatch_started

type 'callback_error flow_execution_error =
  | Flow_attempt_already_started of flow_evidence
  | Flow_attempt_start_failed of
      { candidate : flow_candidate_visit
      ; cause : start_attempt_error
      ; evidence : flow_evidence
      }
  | Flow_measurement_start_failed of
      { candidate : flow_candidate_visit
      ; cause : measurement_start_error
      ; evidence : flow_evidence
      }
  | Flow_before_measurement_dispatch_callback_failed of
      { measurement : flow_measurement_receipt
      ; cause : 'callback_error
      ; evidence : flow_evidence
      }
  | Flow_measurement_terminal_callback_failed of
      { measurement : flow_measurement_receipt
      ; cause : 'callback_error
      ; evidence : flow_evidence
      }
  | Flow_before_dispatch_callback_failed of
      { candidate : flow_attempt_receipt
      ; cause : 'callback_error
      ; evidence : flow_evidence
      }
  | Flow_before_advance_callback_failed of
      { failed : flow_candidate_failure
      ; next : flow_candidate_visit
      ; cause : 'callback_error
      ; evidence : flow_evidence
      }
  | Flow_candidates_exhausted of
      { rejection : candidate_rejection_receipt
      ; evidence : flow_evidence
      }
  | Flow_exact_execution_failed of
      { candidate : flow_attempt_receipt
      ; cause : execution_error
      ; evidence : flow_evidence
      }

type ('callback_error, 'rejection) validated_flow_error =
  | Flow_execution_terminal of
      { cause : 'callback_error flow_execution_error
      ; prior_rejections : 'rejection semantic_rejection_receipt list
      }
  | Flow_semantic_candidates_exhausted of
      { rejections : 'rejection semantic_rejection_trace
      ; evidence : flow_evidence
      }

type 'callback_error flow_step_failure =
  | Flow_step_candidate_rejected of candidate_rejection_receipt
  | Flow_step_attempt_start_failed of flow_candidate_visit * start_attempt_error
  | Flow_step_measurement_start_failed of flow_candidate_visit * measurement_start_error
  | Flow_step_before_measurement_dispatch_callback_failed of
      flow_measurement_receipt * 'callback_error
  | Flow_step_measurement_terminal_callback_failed of
      flow_measurement_receipt * 'callback_error
  | Flow_step_before_dispatch_callback_failed of flow_attempt_receipt * 'callback_error
  | Flow_step_execution_failed of
      { candidate : flow_attempt_receipt
      ; cause : execution_error
      }

let ( let* ) = Result.bind

let make_flow_candidate ~id ~admitted_target =
  let id = String.trim id in
  if String.equal id ""
  then Error Blank_flow_candidate_id
  else
    Ok
      { identity =
          { candidate_id = id
          ; catalog_generation = admitted_target_catalog_generation admitted_target
          ; catalog_evidence = admitted_target_catalog_evidence admitted_target
          ; target_identity = admitted_target_identity admitted_target
          }
      ; admitted_target
      }
;;

let flow_candidate_identity (candidate : flow_candidate) = candidate.identity

let snapshot_flow ~first ~rest ~messages requirement =
  let candidates = first :: rest in
  match
    Flow_state.duplicate_key
      ~equal:String.equal
      ~key:(fun (candidate : flow_candidate) -> candidate.identity.candidate_id)
      candidates
  with
  | Some (candidate_id, first_position, duplicate_position) ->
    Error
      (Duplicate_flow_candidate_id { candidate_id; first_position; duplicate_position })
  | None -> Ok { candidates; messages; requirement }
;;

let start_attempt (ready : ready_plan) =
  match Random_id.create () with
  | Error detail -> Error (Call_id_generation_failed detail)
  | Ok id ->
    let receipt =
      Generation_receipt.create
        ~call_id:(Call_id id)
        ~plan_fingerprint:ready.plan_fingerprint
        ~request_body_sha256:ready.request_body_sha256
        ~catalog_generation:ready.catalog_generation
        ~catalog_evidence:ready.catalog_evidence
        ~target_identity:ready.target_identity
    in
    Ok { ready; receipt }
;;

let start_flow (ready : flow_snapshot) =
  match Random_id.create () with
  | Error detail -> Error (Flow_id_generation_failed detail)
  | Ok raw_flow_id ->
    let flow_id = Flow_id raw_flow_id in
    let candidates =
      List.mapi
        (fun index (candidate : flow_candidate) ->
           { visit =
               { flow_id
               ; ordinal = Flow_visit_ordinal (index + 1)
               ; identity = candidate.identity
               }
           ; admitted_target = candidate.admitted_target
           })
        ready.candidates
    in
    Ok
      { execution = Flow_state.create ()
      ; flow_id
      ; declared_candidate_snapshot = List.map flow_candidate_identity ready.candidates
      ; candidates
      ; messages = ready.messages
      ; requirement = ready.requirement
      ; progress = Flow_state.create_progress ()
      }
;;

let flow_success_candidate success = success.candidate
let flow_success_output success = success.success
let flow_success_evidence success = success.evidence
let call_id_to_string (Call_id id) = id
let flow_attempt_id (flow : flow_attempt) = flow.flow_id
let attempt_receipt (attempt : attempt) = attempt.receipt
let receipt_call_id = Generation_receipt.call_id

let flow_measurement_receipt_snapshot (measurement : flow_measurement_receipt) =
  let snapshot = Flow_admission.receipt_snapshot measurement.receipt in
  create_measurement_receipt_snapshot
    ~operation_id:(Flow_admission.operation_id_to_string snapshot.operation_id)
    ~flow_id:measurement.visit.flow_id
    ~visit_ordinal:measurement.visit.ordinal
    ~candidate_id:measurement.visit.identity.candidate_id
    ~candidate_binding_sha256:
      (target_identity_fingerprint measurement.visit.identity.target_identity)
    ~catalog_generation_fingerprint:
      (catalog_generation_fingerprint measurement.visit.identity.catalog_generation)
    ~catalog_evidence_sha256:
      (catalog_evidence_sha256 measurement.visit.identity.catalog_evidence)
    ~request_body_sha256:snapshot.request_body_sha256
    ~phase:snapshot.phase
    ~dispatch:snapshot.dispatch
    ~outcome:snapshot.outcome
;;

let same_measurement = measurement_receipt_same_operation

let publish_measurement (flow : flow_attempt) (measurement : flow_measurement_receipt) =
  Flow_state.publish_measurement
    flow.progress
    ~same:same_measurement
    (flow_measurement_receipt_snapshot measurement)
;;

let same_attempt (left : flow_attempt_publication) (right : flow_attempt_publication) =
  String.equal (call_id_to_string left.call_id) (call_id_to_string right.call_id)
;;

let publish_attempt_snapshot (flow : flow_attempt) (live : flow_attempt_receipt) =
  let publication : flow_attempt_publication =
    { call_id = receipt_call_id live.receipt
    ; snapshot =
        { visit = live.visit; receipt = Generation_receipt.snapshot live.receipt }
    }
  in
  Flow_state.publish_attempt flow.progress ~same:same_attempt publication
;;

let receipt_phase = Generation_receipt.phase
let receipt_dispatch_count = Generation_receipt.dispatch_count

let generation_dispatch_fact_of_receipt receipt =
  if Generation_receipt.generation_dispatched receipt
  then Generation_dispatch_started
  else No_generation_dispatch
;;

let flow_execution_error_generation_dispatch = function
  | Flow_attempt_already_started _
  | Flow_attempt_start_failed _
  | Flow_measurement_start_failed _
  | Flow_before_measurement_dispatch_callback_failed _
  | Flow_measurement_terminal_callback_failed _
  | Flow_before_dispatch_callback_failed _
  | Flow_before_advance_callback_failed _
  | Flow_candidates_exhausted _ -> No_generation_dispatch
  | Flow_exact_execution_failed { cause; _ } ->
    generation_dispatch_fact_of_receipt cause.receipt
;;

let receipt_http_status = Generation_receipt.http_status
let receipt_provider_trace = Generation_receipt.provider_trace
let provider_trace_fingerprint = Trace.fingerprint
let receipt_plan_fingerprint = Generation_receipt.plan_fingerprint
let receipt_request_body_sha256 = Generation_receipt.request_body_sha256
let receipt_catalog_generation = Generation_receipt.catalog_generation
let receipt_catalog_evidence = Generation_receipt.catalog_evidence
let receipt_target_identity = Generation_receipt.target_identity
let candidate_visit_count_to_int (Candidate_visit_count count) = count
let generation_receipt_snapshot = Generation_receipt.snapshot
let generation_receipt_snapshot_phase = Generation_receipt.snapshot_phase

let generation_receipt_snapshot_dispatch_count =
  Generation_receipt.snapshot_dispatch_count
;;

let generation_receipt_snapshot_http_status = Generation_receipt.snapshot_http_status

let generation_receipt_snapshot_provider_trace =
  Generation_receipt.snapshot_provider_trace
;;

let generation_receipt_snapshot_call_id = Generation_receipt.snapshot_call_id

let generation_receipt_snapshot_plan_fingerprint =
  Generation_receipt.snapshot_plan_fingerprint
;;

let generation_receipt_snapshot_request_body_sha256 =
  Generation_receipt.snapshot_request_body_sha256
;;

let generation_receipt_snapshot_catalog_generation =
  Generation_receipt.snapshot_catalog_generation
;;

let generation_receipt_snapshot_catalog_evidence =
  Generation_receipt.snapshot_catalog_evidence
;;

let generation_receipt_snapshot_target_identity =
  Generation_receipt.snapshot_target_identity
;;

let candidate_rejection_identity (receipt : candidate_rejection_receipt) =
  receipt.visit.identity
;;

let candidate_rejection_visit (receipt : candidate_rejection_receipt) = receipt.visit

let candidate_rejection_measurement_dispatch_fact (receipt : candidate_rejection_receipt) =
  receipt.measurement.dispatch
;;

let candidate_rejection_measurement_outcome (receipt : candidate_rejection_receipt) =
  receipt.measurement.outcome
;;

let target_selection_error_disposition = function
  | Missing_target_credential _
  | Target_credential_invalid _
  | Target_credential_read_failed _ -> Runtime_slot_unavailable
;;

let wire_admission_error_disposition = function
  | Capability_snapshot_missing
  | Global_admission_not_allowed
  | Invalid_connect_timeout
  | Invalid_body_timeout
  | Context_limit_unavailable
  | Invalid_context_limit
  | Unsupported_target_model _ -> Runtime_contract_rejected
  | Output_contract_unavailable -> Output_requirement_rejected
  | Cross_feature_not_allowed
  | Caller_supplied_header_not_allowed
  | Unsupported_image_input
  | Unsupported_document_input
  | Unsupported_audio_input
  | Unsupported_system_prompt -> Input_contract_rejected
  | Token_measurement_required constraint_ ->
    Input_capacity
      (Token_measurement_required
         { accepted_through_tokens = constraint_.accepted_through_tokens
         ; rejected_from_tokens = constraint_.rejected_from_tokens
         })
  | Measured_context_window_exceeded
      { input_tokens; reserved_output_tokens; max_context_tokens } ->
    Input_capacity
      (Context_window_exceeded
         { input_tokens; reserved_output_tokens; max_context_tokens })
  | Measured_serving_constraint_rejected reason ->
    Input_capacity (Token_capacity_rejected reason)
  | Request_body_too_large { actual_bytes; limit_bytes } ->
    Input_capacity (Serialized_request_body_too_large { actual_bytes; limit_bytes })
  | Output_reservation_unavailable
  | Token_measurement_failed
  | Target_request_rejected
  | Request_serialization_rejected -> Request_preparation_failed
;;

let admission_error_disposition = function
  | Provider_schema_unavailable
  | Unsupported_schema_keyword _
  | Unsupported_schema_type _
  | Invalid_schema -> Output_requirement_rejected
  | Wire_admission_rejected cause -> wire_admission_error_disposition cause
;;

let candidate_rejection_disposition (receipt : candidate_rejection_receipt) =
  match receipt.cause with
  | Target_selection_rejected cause -> target_selection_error_disposition cause
  | Request_admission_rejected cause -> admission_error_disposition cause
;;

let validated_flow_evidence_source_error_to_string = function
  | Evidence_ordinal_out_of_bounds { collection; ordinal; visited_candidates } ->
    Printf.sprintf
      "%s evidence ordinal %d is outside visited range 1..%d"
      collection
      ordinal
      visited_candidates
  | Evidence_duplicate_ordinal { collection; ordinal } ->
    Printf.sprintf "%s evidence repeats ordinal %d" collection ordinal
  | Evidence_missing_entry { collection; ordinal } ->
    Printf.sprintf "%s evidence is missing ordinal %d" collection ordinal
  | Evidence_unexpected_entry { collection; ordinal } ->
    Printf.sprintf "%s evidence is unexpected at ordinal %d" collection ordinal
  | Evidence_flow_identity_mismatch { collection; ordinal } ->
    Printf.sprintf
      "%s evidence has a different flow identity at ordinal %d"
      collection
      ordinal
  | Evidence_unsupported_state { collection; ordinal; detail } ->
    Printf.sprintf
      "%s evidence at ordinal %d has unsupported state: %s"
      collection
      ordinal
      detail
;;

let validated_flow_evidence_invariant_error_to_string =
  Validated_flow_evidence.invariant_error_to_string
;;

let validated_flow_evidence_decode_error_to_string =
  Validated_flow_evidence.decode_error_to_string
;;

let validated_flow_evidence_to_string = Validated_flow_evidence.to_string
let validated_flow_evidence_of_string = Validated_flow_evidence.of_string
let validated_flow_evidence_sha256 = Validated_flow_evidence.sha256

let validated_flow_evidence_accepted_domain_sha256 =
  Validated_flow_evidence.accepted_domain_sha256
;;

let evidence_sha256 value = Digestif.SHA256.(to_hex (digest_string value))

let rec canonical_evidence_json (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (name, value) -> name, canonical_evidence_json value)
       |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List values -> `List (List.map canonical_evidence_json values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value -> value
;;

let output_evidence_sha256 (value : Yojson.Safe.t) =
  value |> canonical_evidence_json |> Yojson.Safe.to_string |> evidence_sha256
;;

let evidence_candidate (identity : flow_candidate_identity)
  : Validated_flow_evidence.candidate
  =
  { candidate_id = identity.candidate_id
  ; candidate_binding_sha256 = target_identity_fingerprint identity.target_identity
  ; catalog_generation_sha256 = catalog_generation_fingerprint identity.catalog_generation
  ; catalog_evidence_sha256 = catalog_evidence_sha256 identity.catalog_evidence
  }
;;

let evidence_assurance = function
  | Json_syntax_only -> Validated_flow_evidence.Json_syntax_only
  | Provider_schema_requested -> Validated_flow_evidence.Provider_schema_requested
;;

let evidence_provenance (provenance : plan_provenance)
  : Validated_flow_evidence.provenance
  =
  { source_schema_sha256 =
      schema_fingerprint_to_string provenance.source_schema_fingerprint
  ; effective_schema_sha256 =
      Option.map schema_fingerprint_to_string provenance.effective_schema_fingerprint
  ; assurance = evidence_assurance provenance.actual_assurance
  ; candidate_binding_sha256 = target_identity_fingerprint provenance.target_identity
  ; catalog_generation_sha256 =
      catalog_generation_fingerprint provenance.catalog_generation
  ; catalog_evidence_sha256 = catalog_evidence_sha256 provenance.catalog_evidence
  }
;;

let evidence_measurement_dispatch = function
  | No_measurement_dispatch -> Ok Validated_flow_evidence.No_measurement_dispatch
  | Measurement_dispatch_started ->
    Ok Validated_flow_evidence.Measurement_dispatch_started
  | Measurement_dispatch_unknown -> Error "terminal measurement dispatch remains unknown"
;;

let evidence_measurement_outcome = function
  | Measurement_not_required -> Validated_flow_evidence.Measurement_not_required
  | Measurement_succeeded -> Validated_flow_evidence.Measurement_succeeded
  | Measurement_unsupported -> Validated_flow_evidence.Measurement_unsupported
  | Measurement_local_invalid -> Validated_flow_evidence.Measurement_local_invalid
  | Measurement_transport_failed -> Validated_flow_evidence.Measurement_transport_failed
  | Measurement_invalid_response -> Validated_flow_evidence.Measurement_invalid_response
  | Measurement_fence_rejected -> Validated_flow_evidence.Measurement_fence_rejected
  | Measurement_cancelled -> Validated_flow_evidence.Measurement_cancelled
;;

let evidence_measurement_state ~collection ~ordinal (measurement : measurement_evidence) =
  match evidence_measurement_dispatch measurement.dispatch with
  | Error detail -> Error (Evidence_unsupported_state { collection; ordinal; detail })
  | Ok dispatch ->
    Ok
      Validated_flow_evidence.
        { dispatch; outcome = evidence_measurement_outcome measurement.outcome }
;;

let input_capacity_evidence_json = function
  | Token_measurement_required { accepted_through_tokens; rejected_from_tokens } ->
    `Assoc
      [ "kind", `String "token_measurement_required"
      ; "accepted_through_tokens", `Int accepted_through_tokens
      ; ( "rejected_from_tokens"
        , Option.fold ~none:`Null ~some:(fun value -> `Int value) rejected_from_tokens )
      ]
  | Context_window_exceeded { input_tokens; reserved_output_tokens; max_context_tokens }
    ->
    `Assoc
      [ "kind", `String "context_window_exceeded"
      ; "input_tokens", `Int input_tokens
      ; "reserved_output_tokens", `Int reserved_output_tokens
      ; "max_context_tokens", `Int max_context_tokens
      ]
  | Token_capacity_rejected
      (Capacity_evidence_not_yet_valid { now_unix_s; checked_at_unix_s }) ->
    `Assoc
      [ "kind", `String "capacity_evidence_not_yet_valid"
      ; "now_unix_s", `Int now_unix_s
      ; "checked_at_unix_s", `Int checked_at_unix_s
      ]
  | Token_capacity_rejected (Capacity_evidence_expired { now_unix_s; expires_at_unix_s })
    ->
    `Assoc
      [ "kind", `String "capacity_evidence_expired"
      ; "now_unix_s", `Int now_unix_s
      ; "expires_at_unix_s", `Int expires_at_unix_s
      ]
  | Token_capacity_rejected
      (Capacity_boundary_unknown
         { input_tokens; accepted_through_tokens; rejected_from_tokens }) ->
    `Assoc
      [ "kind", `String "capacity_boundary_unknown"
      ; "input_tokens", `Int input_tokens
      ; "accepted_through_tokens", `Int accepted_through_tokens
      ; ( "rejected_from_tokens"
        , Option.fold ~none:`Null ~some:(fun value -> `Int value) rejected_from_tokens )
      ]
  | Token_capacity_rejected
      (Capacity_input_rejected
         { input_tokens; accepted_through_tokens; rejected_from_tokens }) ->
    `Assoc
      [ "kind", `String "capacity_input_rejected"
      ; "input_tokens", `Int input_tokens
      ; "accepted_through_tokens", `Int accepted_through_tokens
      ; "rejected_from_tokens", `Int rejected_from_tokens
      ]
  | Serialized_request_body_too_large { actual_bytes; limit_bytes } ->
    `Assoc
      [ "kind", `String "serialized_request_body_too_large"
      ; "actual_bytes", `Int actual_bytes
      ; "limit_bytes", `Int limit_bytes
      ]
;;

let wire_admission_error_evidence_json = function
  | Capability_snapshot_missing ->
    `Assoc [ "kind", `String "capability_snapshot_missing" ]
  | Output_contract_unavailable ->
    `Assoc [ "kind", `String "output_contract_unavailable" ]
  | Cross_feature_not_allowed -> `Assoc [ "kind", `String "cross_feature_not_allowed" ]
  | Global_admission_not_allowed ->
    `Assoc [ "kind", `String "global_admission_not_allowed" ]
  | Invalid_connect_timeout -> `Assoc [ "kind", `String "invalid_connect_timeout" ]
  | Invalid_body_timeout -> `Assoc [ "kind", `String "invalid_body_timeout" ]
  | Caller_supplied_header_not_allowed ->
    `Assoc [ "kind", `String "caller_supplied_header_not_allowed" ]
  | Unsupported_image_input -> `Assoc [ "kind", `String "unsupported_image_input" ]
  | Unsupported_document_input -> `Assoc [ "kind", `String "unsupported_document_input" ]
  | Unsupported_audio_input -> `Assoc [ "kind", `String "unsupported_audio_input" ]
  | Unsupported_system_prompt -> `Assoc [ "kind", `String "unsupported_system_prompt" ]
  | Token_measurement_required observation ->
    `Assoc
      [ "kind", `String "token_measurement_required"
      ; "accepted_through_tokens", `Int observation.accepted_through_tokens
      ; ( "rejected_from_tokens"
        , Option.fold
            ~none:`Null
            ~some:(fun value -> `Int value)
            observation.rejected_from_tokens )
      ]
  | Context_limit_unavailable -> `Assoc [ "kind", `String "context_limit_unavailable" ]
  | Invalid_context_limit -> `Assoc [ "kind", `String "invalid_context_limit" ]
  | Output_reservation_unavailable ->
    `Assoc [ "kind", `String "output_reservation_unavailable" ]
  | Measured_context_window_exceeded fit ->
    `Assoc
      [ "kind", `String "measured_context_window_exceeded"
      ; "input_tokens", `Int fit.input_tokens
      ; "reserved_output_tokens", `Int fit.reserved_output_tokens
      ; "max_context_tokens", `Int fit.max_context_tokens
      ]
  | Measured_serving_constraint_rejected reason ->
    `Assoc
      [ "kind", `String "measured_serving_constraint_rejected"
      ; "evidence", input_capacity_evidence_json (Token_capacity_rejected reason)
      ]
  | Token_measurement_failed -> `Assoc [ "kind", `String "token_measurement_failed" ]
  | Unsupported_target_model { model_id } ->
    `Assoc [ "kind", `String "unsupported_target_model"; "model_id", `String model_id ]
  | Target_request_rejected -> `Assoc [ "kind", `String "target_request_rejected" ]
  | Request_body_too_large { actual_bytes; limit_bytes } ->
    `Assoc
      [ "kind", `String "request_body_too_large"
      ; "actual_bytes", `Int actual_bytes
      ; "limit_bytes", `Int limit_bytes
      ]
  | Request_serialization_rejected ->
    `Assoc [ "kind", `String "request_serialization_rejected" ]
;;

let admission_error_evidence_json = function
  | Provider_schema_unavailable ->
    `Assoc [ "kind", `String "provider_schema_unavailable" ]
  | Unsupported_schema_keyword keyword ->
    `Assoc [ "kind", `String "unsupported_schema_keyword"; "keyword", `String keyword ]
  | Unsupported_schema_type schema_type ->
    `Assoc
      [ "kind", `String "unsupported_schema_type"; "schema_type", `String schema_type ]
  | Invalid_schema -> `Assoc [ "kind", `String "invalid_schema" ]
  | Wire_admission_rejected cause ->
    `Assoc
      [ "kind", `String "wire_admission_rejected"
      ; "cause", wire_admission_error_evidence_json cause
      ]
;;

let target_selection_error_evidence_json = function
  | Missing_target_credential { target_ref; environment_variable } ->
    `Assoc
      [ "kind", `String "missing_target_credential"
      ; "target_ref", `String target_ref
      ; "environment_variable", `String environment_variable
      ]
  | Target_credential_invalid { target_ref; environment_variable } ->
    `Assoc
      [ "kind", `String "target_credential_invalid"
      ; "target_ref", `String target_ref
      ; "environment_variable", `String environment_variable
      ]
  | Target_credential_read_failed { target_ref; environment_variable } ->
    `Assoc
      [ "kind", `String "target_credential_read_failed"
      ; "target_ref", `String target_ref
      ; "environment_variable", `String environment_variable
      ]
;;

let candidate_rejection_evidence_json (receipt : candidate_rejection_receipt) =
  match receipt.cause with
  | Target_selection_rejected cause ->
    `Assoc
      [ "kind", `String "target_selection_rejected"
      ; "cause", target_selection_error_evidence_json cause
      ]
  | Request_admission_rejected cause ->
    `Assoc
      [ "kind", `String "request_admission_rejected"
      ; "cause", admission_error_evidence_json cause
      ]
;;

let index_evidence_by_ordinal ~collection ~visited_candidates ~ordinal values =
  let slots = Array.make (visited_candidates + 1) None in
  let rec fill = function
    | [] -> Ok slots
    | value :: rest ->
      let position = ordinal value in
      if position < 1 || position > visited_candidates
      then
        Error
          (Evidence_ordinal_out_of_bounds
             { collection; ordinal = position; visited_candidates })
      else (
        match slots.(position) with
        | Some _ -> Error (Evidence_duplicate_ordinal { collection; ordinal = position })
        | None ->
          slots.(position) <- Some value;
          fill rest)
  in
  fill values
;;

let same_flow_id expected actual =
  String.equal (flow_id_to_string expected) (flow_id_to_string actual)
;;

let same_candidate_identity
      (left : flow_candidate_identity)
      (right : flow_candidate_identity)
  =
  String.equal left.candidate_id right.candidate_id
  && String.equal
       (target_identity_fingerprint left.target_identity)
       (target_identity_fingerprint right.target_identity)
  && String.equal
       (catalog_generation_fingerprint left.catalog_generation)
       (catalog_generation_fingerprint right.catalog_generation)
  && String.equal
       (catalog_evidence_sha256 left.catalog_evidence)
       (catalog_evidence_sha256 right.catalog_evidence)
;;

let evidence_measurement ~flow_id ~ordinal (snapshot : measurement_receipt_snapshot) =
  if not (same_flow_id flow_id snapshot.flow_id)
  then Error (Evidence_flow_identity_mismatch { collection = "measurement"; ordinal })
  else (
    match snapshot.phase, snapshot.outcome with
    | Measurement_terminal, Some outcome ->
      (match evidence_measurement_dispatch snapshot.dispatch with
       | Error detail ->
         Error
           (Evidence_unsupported_state { collection = "measurement"; ordinal; detail })
       | Ok dispatch ->
         Ok
           Validated_flow_evidence.
             { operation_id = measurement_operation_id_to_string snapshot.operation_id
             ; request_body_sha256 = snapshot.request_body_sha256
             ; candidate_binding_sha256 = snapshot.candidate_binding_sha256
             ; catalog_generation_sha256 = snapshot.catalog_generation_fingerprint
             ; catalog_evidence_sha256 = snapshot.catalog_evidence_sha256
             ; dispatch
             ; outcome = evidence_measurement_outcome outcome
             })
    | (Measurement_fence_committed | Measurement_wire_started | Measurement_terminal), _
      ->
      Error
        (Evidence_unsupported_state
           { collection = "measurement"
           ; ordinal
           ; detail = "snapshot is not terminal with an outcome"
           }))
;;

let evidence_attempt_phase ~ordinal = function
  | Before_dispatch -> Ok Validated_flow_evidence.Before_dispatch
  | Response_received -> Ok Validated_flow_evidence.Response_received
  | Terminal -> Ok Validated_flow_evidence.Terminal
  | Not_started | Dispatch_started ->
    Error
      (Evidence_unsupported_state
         { collection = "attempt"
         ; ordinal
         ; detail = "snapshot is not at a durable transcript boundary"
         })
;;

let evidence_attempt
      ~flow_id
      ~ordinal
      ~raw_response_sha256
      (snapshot : flow_attempt_snapshot)
  =
  if not (same_flow_id flow_id snapshot.visit.flow_id)
  then Error (Evidence_flow_identity_mismatch { collection = "attempt"; ordinal })
  else (
    let receipt = snapshot.receipt in
    match evidence_attempt_phase ~ordinal (generation_receipt_snapshot_phase receipt) with
    | Error _ as error -> error
    | Ok phase ->
      Ok
        Validated_flow_evidence.
          { call_id = call_id_to_string (generation_receipt_snapshot_call_id receipt)
          ; plan_sha256 = generation_receipt_snapshot_plan_fingerprint receipt
          ; request_body_sha256 = generation_receipt_snapshot_request_body_sha256 receipt
          ; candidate_binding_sha256 =
              generation_receipt_snapshot_target_identity receipt
              |> target_identity_fingerprint
          ; catalog_generation_sha256 =
              generation_receipt_snapshot_catalog_generation receipt
              |> catalog_generation_fingerprint
          ; catalog_evidence_sha256 =
              generation_receipt_snapshot_catalog_evidence receipt
              |> catalog_evidence_sha256
          ; phase
          ; dispatch_count = generation_receipt_snapshot_dispatch_count receipt
          ; http_status = generation_receipt_snapshot_http_status receipt
          ; provider_trace_sha256 =
              generation_receipt_snapshot_provider_trace receipt
              |> Option.map provider_trace_fingerprint
          ; raw_response_sha256
          })
;;

let evidence_transport_failure ~ordinal = function
  | Flow_advance_candidate_rejected _ ->
    Ok (Validated_flow_evidence.Candidate_rejected, None)
  | Flow_advance_execution_failed { cause = Completion_failed; raw_response_sha256; _ } ->
    Ok (Validated_flow_evidence.Completion_failed_before_dispatch, raw_response_sha256)
  | Flow_advance_execution_failed
      { cause = Serialized_request_refused { http_status }; raw_response_sha256; _ } ->
    Ok
      ( Validated_flow_evidence.Serialized_request_refused { http_status }
      , raw_response_sha256 )
  | Flow_advance_execution_failed { cause = Invalid_json_output; raw_response_sha256; _ }
    -> Ok (Validated_flow_evidence.Invalid_json_output, raw_response_sha256)
  | Flow_advance_execution_failed { cause; _ } ->
    let detail =
      match cause with
      | Attempt_already_started -> "attempt_already_started"
      | Clock_required_for_timeout -> "clock_required_for_timeout"
      | Frozen_request_mismatch -> "frozen_request_mismatch"
      | Completion_failed -> "completion_failed"
      | Serialized_request_refused _ -> "serialized_request_refused"
      | Incomplete_output -> "incomplete_output"
      | Missing_output -> "missing_output"
      | Ambiguous_output _ -> "ambiguous_output"
      | Unexpected_output_content -> "unexpected_output_content"
      | Invalid_json_output -> "invalid_json_output"
      | Internal_non_json_output -> "internal_non_json_output"
    in
    Error (Evidence_unsupported_state { collection = "advance"; ordinal; detail })
;;

let evidence_admission ~flow_id ~ordinal ~expected_identity = function
  | Candidate_rejected receipt ->
    if not (same_flow_id flow_id receipt.visit.flow_id)
    then Error (Evidence_flow_identity_mismatch { collection = "admission"; ordinal })
    else if not (same_candidate_identity expected_identity receipt.visit.identity)
    then
      Error
        (Evidence_unsupported_state
           { collection = "admission"
           ; ordinal
           ; detail = "candidate identity differs from declared snapshot"
           })
    else (
      match
        evidence_measurement_state ~collection:"admission" ~ordinal receipt.measurement
      with
      | Error _ as error -> error
      | Ok measurement ->
        Ok
          (Validated_flow_evidence.Rejected
             { rejection = candidate_rejection_evidence_json receipt; measurement }))
  | Candidate_admitted admitted ->
    if not (same_flow_id flow_id admitted.visit.flow_id)
    then Error (Evidence_flow_identity_mismatch { collection = "admission"; ordinal })
    else if not (same_candidate_identity expected_identity admitted.visit.identity)
    then
      Error
        (Evidence_unsupported_state
           { collection = "admission"
           ; ordinal
           ; detail = "candidate identity differs from declared snapshot"
           })
    else (
      match
        evidence_measurement_state ~collection:"admission" ~ordinal admitted.measurement
      with
      | Error _ as error -> error
      | Ok measurement ->
        Ok
          (Validated_flow_evidence.Admitted
             { plan_sha256 = admitted.plan_fingerprint
             ; request_body_sha256 = admitted.request_body_sha256
             ; provenance = evidence_provenance admitted.provenance
             ; measurement
             }))
;;

let visit_ordinal (visit : flow_candidate_visit) = flow_visit_ordinal_to_int visit.ordinal

let advance_failed_visit = function
  | Flow_advance_candidate_rejected receipt -> receipt.visit
  | Flow_advance_execution_failed { candidate; _ } -> candidate.visit
;;

let attempt_snapshot_call_id snapshot =
  generation_receipt_snapshot_call_id snapshot.receipt |> call_id_to_string
;;

let projected_flow_success ~ordinal ~projector (transport : flow_success) =
  let success = transport.success in
  { ordinal
  ; projector
  ; output_sha256 = output_evidence_sha256 success.output
  ; raw_response_sha256 = success.raw_response.body_sha256
  ; call_id = call_id_to_string success.call_id
  }
;;

let snapshot_validated_flow_evidence
      ~project_accepted
      ~project_rejection
      (validated : ('accepted, 'rejection) validated_flow_success)
  =
  let source_result = function
    | Ok value -> Ok value
    | Error error -> Error (Validated_flow_source_evidence_invalid error)
  in
  let final_transport = validated.transport_success in
  let evidence = final_transport.evidence in
  let visited_candidates = candidate_visit_count_to_int evidence.candidate_visit_count in
  let admissions_count = List.length evidence.admissions in
  let declared_count = List.length evidence.declared_candidate_snapshot in
  let* () =
    if visited_candidates < 1 || visited_candidates > declared_count
    then
      Error
        (Validated_flow_source_evidence_invalid
           (Evidence_unsupported_state
              { collection = "flow"
              ; ordinal = visited_candidates
              ; detail =
                  Printf.sprintf
                    "visited candidate count is outside declared count %d"
                    declared_count
              }))
    else if visited_candidates = admissions_count
    then Ok ()
    else
      Error
        (Validated_flow_source_evidence_invalid
           (Evidence_unsupported_state
              { collection = "admission"
              ; ordinal = admissions_count
              ; detail =
                  Printf.sprintf
                    "candidate visit count is %d but admission count is %d"
                    visited_candidates
                    admissions_count
              }))
  in
  let declared_source = Array.of_list evidence.declared_candidate_snapshot in
  let admission_ordinal = function
    | Candidate_admitted admitted -> visit_ordinal admitted.visit
    | Candidate_rejected receipt -> visit_ordinal receipt.visit
  in
  let* admissions =
    index_evidence_by_ordinal
      ~collection:"admission"
      ~visited_candidates
      ~ordinal:admission_ordinal
      evidence.admissions
    |> source_result
  in
  let* attempts =
    index_evidence_by_ordinal
      ~collection:"attempt"
      ~visited_candidates
      ~ordinal:(fun snapshot -> visit_ordinal snapshot.visit)
      evidence.attempts
    |> source_result
  in
  let* measurements =
    index_evidence_by_ordinal
      ~collection:"measurement"
      ~visited_candidates
      ~ordinal:(fun snapshot -> flow_visit_ordinal_to_int snapshot.visit_ordinal)
      evidence.measurements
    |> source_result
  in
  let* advances =
    index_evidence_by_ordinal
      ~collection:"advance"
      ~visited_candidates
      ~ordinal:(fun receipt -> visit_ordinal (advance_failed_visit receipt.failed))
      evidence.advances
    |> source_result
  in
  let rec project_rejections projected_rev = function
    | [] -> Ok (List.rev projected_rev)
    | (receipt : _ semantic_rejection_receipt) :: rest ->
      let ordinal = visit_ordinal receipt.transport_success.candidate.visit in
      if ordinal < 1 || ordinal > visited_candidates
      then
        Error
          (Validated_flow_source_evidence_invalid
             (Evidence_ordinal_out_of_bounds
                { collection = "semantic_rejection"; ordinal; visited_candidates }))
      else if
        not (same_flow_id evidence.flow_id receipt.transport_success.evidence.flow_id)
      then
        Error
          (Validated_flow_source_evidence_invalid
             (Evidence_flow_identity_mismatch
                { collection = "semantic_rejection"; ordinal }))
      else if
        not
          (same_candidate_identity
             declared_source.(ordinal - 1)
             receipt.transport_success.candidate.visit.identity)
      then
        Error
          (Validated_flow_source_evidence_invalid
             (Evidence_unsupported_state
                { collection = "semantic_rejection"
                ; ordinal
                ; detail = "candidate identity differs from declared snapshot"
                }))
      else (
        match project_rejection receipt.rejection with
        | Error cause -> Error (Rejection_evidence_projection_failed { ordinal; cause })
        | Ok projector ->
          project_rejections
            (projected_flow_success ~ordinal ~projector receipt.transport_success
             :: projected_rev)
            rest)
  in
  let* projected_rejections = project_rejections [] validated.prior_rejections in
  let* semantic_rejections =
    index_evidence_by_ordinal
      ~collection:"semantic_rejection"
      ~visited_candidates
      ~ordinal:(fun projected -> projected.ordinal)
      projected_rejections
    |> source_result
  in
  let accepted_ordinal = visit_ordinal final_transport.candidate.visit in
  let* () =
    if accepted_ordinal < 1 || accepted_ordinal > visited_candidates
    then
      Error
        (Validated_flow_source_evidence_invalid
           (Evidence_ordinal_out_of_bounds
              { collection = "accepted"; ordinal = accepted_ordinal; visited_candidates }))
    else if not (same_flow_id evidence.flow_id final_transport.candidate.visit.flow_id)
    then
      Error
        (Validated_flow_source_evidence_invalid
           (Evidence_flow_identity_mismatch
              { collection = "accepted"; ordinal = accepted_ordinal }))
    else if
      not
        (same_candidate_identity
           declared_source.(accepted_ordinal - 1)
           final_transport.candidate.visit.identity)
    then
      Error
        (Validated_flow_source_evidence_invalid
           (Evidence_unsupported_state
              { collection = "accepted"
              ; ordinal = accepted_ordinal
              ; detail = "candidate identity differs from declared snapshot"
              }))
    else Ok ()
  in
  let* accepted_projector =
    match project_accepted validated.accepted with
    | Ok value -> Ok value
    | Error cause -> Error (Accepted_evidence_projection_failed cause)
  in
  let accepted =
    projected_flow_success
      ~ordinal:accepted_ordinal
      ~projector:accepted_projector
      final_transport
  in
  let declared_candidates =
    Array.to_list declared_source |> List.map evidence_candidate
  in
  let rec build_steps ordinal steps_rev =
    if ordinal > visited_candidates
    then Ok (List.rev steps_rev)
    else (
      match admissions.(ordinal) with
      | None ->
        Error
          (Validated_flow_source_evidence_invalid
             (Evidence_missing_entry { collection = "admission"; ordinal }))
      | Some source_admission ->
        let expected_identity = declared_source.(ordinal - 1) in
        let* admission =
          evidence_admission
            ~flow_id:evidence.flow_id
            ~ordinal
            ~expected_identity
            source_admission
          |> source_result
        in
        let* measurement =
          match measurements.(ordinal) with
          | None -> Ok None
          | Some snapshot ->
            let* value =
              evidence_measurement ~flow_id:evidence.flow_id ~ordinal snapshot
              |> source_result
            in
            Ok (Some value)
        in
        let advance = advances.(ordinal) in
        let semantic = semantic_rejections.(ordinal) in
        let is_accepted = ordinal = accepted.ordinal in
        let outcome_count =
          (if Option.is_some advance then 1 else 0)
          + (if Option.is_some semantic then 1 else 0)
          + if is_accepted then 1 else 0
        in
        if outcome_count <> 1
        then
          Error
            (Validated_flow_source_evidence_invalid
               (if outcome_count = 0
                then Evidence_missing_entry { collection = "outcome"; ordinal }
                else Evidence_unexpected_entry { collection = "outcome"; ordinal }))
        else
          let* outcome, raw_response_sha256, expected_call_id =
            match advance, semantic, is_accepted with
            | Some receipt, None, false ->
              let failed_visit = advance_failed_visit receipt.failed in
              let next_ordinal = visit_ordinal receipt.next in
              if not (same_flow_id evidence.flow_id failed_visit.flow_id)
              then
                Error
                  (Validated_flow_source_evidence_invalid
                     (Evidence_flow_identity_mismatch
                        { collection = "advance.failed"; ordinal }))
              else if
                not (same_candidate_identity expected_identity failed_visit.identity)
              then
                Error
                  (Validated_flow_source_evidence_invalid
                     (Evidence_unsupported_state
                        { collection = "advance.failed"
                        ; ordinal
                        ; detail = "candidate identity differs from declared snapshot"
                        }))
              else if not (same_flow_id evidence.flow_id receipt.next.flow_id)
              then
                Error
                  (Validated_flow_source_evidence_invalid
                     (Evidence_flow_identity_mismatch { collection = "advance"; ordinal }))
              else if
                next_ordinal < 1
                || next_ordinal > Array.length declared_source
                || not
                     (same_candidate_identity
                        declared_source.(next_ordinal - 1)
                        receipt.next.identity)
              then
                Error
                  (Validated_flow_source_evidence_invalid
                     (Evidence_unsupported_state
                        { collection = "advance.next"
                        ; ordinal
                        ; detail = "candidate identity differs from declared snapshot"
                        }))
              else
                let* failure, raw_response_sha256 =
                  evidence_transport_failure ~ordinal receipt.failed |> source_result
                in
                let expected_call_id =
                  match receipt.failed with
                  | Flow_advance_candidate_rejected _ -> None
                  | Flow_advance_execution_failed { candidate; _ } ->
                    Some (attempt_snapshot_call_id candidate)
                in
                Ok
                  ( Validated_flow_evidence.Advance { next_ordinal; failure }
                  , raw_response_sha256
                  , expected_call_id )
            | None, Some projected, false ->
              Ok
                ( Validated_flow_evidence.Semantic_rejected
                    { projector = projected.projector
                    ; output_sha256 = projected.output_sha256
                    }
                , Some projected.raw_response_sha256
                , Some projected.call_id )
            | None, None, true ->
              Ok
                ( Validated_flow_evidence.Accepted
                    { projector = accepted.projector
                    ; output_sha256 = accepted.output_sha256
                    }
                , Some accepted.raw_response_sha256
                , Some accepted.call_id )
            | Some _, Some _, _
            | Some _, None, true
            | None, Some _, true
            | None, None, false ->
              Error
                (Validated_flow_source_evidence_invalid
                   (Evidence_unexpected_entry { collection = "outcome"; ordinal }))
          in
          let* attempt =
            match attempts.(ordinal), expected_call_id with
            | None, None -> Ok None
            | None, Some _ ->
              Error
                (Validated_flow_source_evidence_invalid
                   (Evidence_missing_entry { collection = "attempt"; ordinal }))
            | Some _, None ->
              Error
                (Validated_flow_source_evidence_invalid
                   (Evidence_unexpected_entry { collection = "attempt"; ordinal }))
            | Some snapshot, Some expected_call_id ->
              let actual_call_id = attempt_snapshot_call_id snapshot in
              if not (String.equal expected_call_id actual_call_id)
              then
                Error
                  (Validated_flow_source_evidence_invalid
                     (Evidence_unsupported_state
                        { collection = "attempt"
                        ; ordinal
                        ; detail = "call identity differs from outcome evidence"
                        }))
              else
                let* value =
                  evidence_attempt
                    ~flow_id:evidence.flow_id
                    ~ordinal
                    ~raw_response_sha256
                    snapshot
                  |> source_result
                in
                Ok (Some value)
          in
          build_steps
            (ordinal + 1)
            (Validated_flow_evidence.{ ordinal; admission; measurement; attempt; outcome }
             :: steps_rev))
  in
  let* steps = build_steps 1 [] in
  match
    Validated_flow_evidence.create
      ~flow_id:(flow_id_to_string evidence.flow_id)
      ~declared_candidates
      ~steps
  with
  | Ok snapshot -> Ok snapshot
  | Error error -> Error (Validated_flow_evidence_invariant_failed error)
;;

let flow_attempt_evidence (flow : flow_attempt) =
  let progress = Flow_state.progress_snapshot flow.progress in
  { flow_id = flow.flow_id
  ; declared_candidate_snapshot = flow.declared_candidate_snapshot
  ; candidate_visit_count = Candidate_visit_count progress.candidate_visit_count
  ; measurements = progress.measurements
  ; admissions = progress.admissions
  ; attempts = List.map (fun publication -> publication.snapshot) progress.attempts
  ; advances = progress.advances
  }
;;

let flow_advance_failure_snapshot = function
  | Flow_candidate_rejected receipt -> Flow_advance_candidate_rejected receipt
  | Flow_candidate_execution_failed { candidate; cause } ->
    Flow_advance_execution_failed
      { candidate =
          { visit = candidate.visit
          ; receipt = Generation_receipt.snapshot candidate.receipt
          }
      ; cause = cause.cause
      ; raw_response_sha256 =
          Option.map (fun response -> response.body_sha256) cause.raw_response
      }
;;

let observe_phase = Generation_receipt.observe_phase
let synchronize_receipt = Generation_receipt.synchronize
let raw_response = Trace.raw_response
let record_provider_trace = Generation_receipt.record_provider_trace

let serialized_request_refusal_of_http_error ~code ~body ~retry_after_header =
  match Retry.classify_error ~retry_after_header ~status:code ~body with
  | Retry.InvalidRequest { reason = Retry.Request_body_refused_by_provider { status }; _ }
    -> Some status
  | Retry.RateLimited _
  | Retry.Overloaded _
  | Retry.ServerError _
  | Retry.AuthError _
  | Retry.AuthorizationError _
  | Retry.PaymentRequired _
  | Retry.InvalidRequest _
  | Retry.NotFound _
  | Retry.ContextOverflow _
  | Retry.InputCapacity _
  | Retry.NetworkError _
  | Retry.Timeout _ -> None
;;

let execution_error_cause = function
  | Exec.Clock_required_for_timeout -> Clock_required_for_timeout
  | Exec.Frozen_request_mismatch -> Frozen_request_mismatch
  | Exec.Provider_error (Http_client.HttpError { code; body; retry_after_header }) ->
    (match serialized_request_refusal_of_http_error ~code ~body ~retry_after_header with
     | Some http_status -> Serialized_request_refused { http_status }
     | None -> Completion_failed)
  | Exec.Provider_error _ -> Completion_failed
  | Exec.Output_normalization_failed (Exec.Incomplete_structured_response _) ->
    Incomplete_output
  | Exec.Output_normalization_failed Exec.Missing_structured_text -> Missing_output
  | Exec.Output_normalization_failed (Exec.Ambiguous_structured_text count) ->
    Ambiguous_output count
  | Exec.Output_normalization_failed Exec.Unexpected_structured_content ->
    Unexpected_output_content
  | Exec.Output_normalization_failed (Exec.Invalid_json _) -> Invalid_json_output
;;

let execute_once_with_publication ~publish ~net ?clock (attempt : attempt) =
  let ready = attempt.ready in
  let receipt = attempt.receipt in
  if not (Generation_receipt.try_start receipt)
  then
    Error
      { call_id = receipt_call_id receipt
      ; receipt
      ; cause = Attempt_already_started
      ; raw_response = None
      }
  else (
    publish ();
    match
      Exec.execute_once_with_evidence
        ~net
        ?clock
        ~on_phase:(fun phase ->
          observe_phase receipt phase;
          publish ())
        ready.plan
    with
    | Error
        ({ receipt = complete_receipt; cause; raw_response = evidence } :
          Exec.execute_once_error_with_evidence) ->
      synchronize_receipt receipt complete_receipt;
      publish ();
      Option.iter
        (fun response_evidence ->
           response_evidence
           |> Trace.of_evidence complete_receipt
           |> record_provider_trace receipt)
        evidence;
      publish ();
      Error
        { call_id = receipt_call_id receipt
        ; receipt
        ; cause = execution_error_cause cause
        ; raw_response = Option.map raw_response evidence
        }
    | Ok { outcome; raw_response = evidence } ->
      synchronize_receipt receipt outcome.receipt;
      publish ();
      let provider_trace =
        Trace.of_evidence ~response:outcome.response outcome.receipt evidence
      in
      record_provider_trace receipt provider_trace;
      publish ();
      (match outcome.output with
       | Exec.Json_output { value; _ } ->
         Ok
           { call_id = receipt_call_id receipt
           ; receipt
           ; output = value
           ; provenance = ready.provenance
           ; raw_response = raw_response evidence
           }
       | Exec.Text_output text ->
         (match ready.provenance.actual_assurance, Plan.response_format ready.plan with
          | Json_syntax_only, Types.Off ->
            (try
               let value = Yojson.Safe.from_string text in
               Ok
                 { call_id = receipt_call_id receipt
                 ; receipt
                 ; output = value
                 ; provenance = ready.provenance
                 ; raw_response = raw_response evidence
                 }
             with
             | Yojson.Json_error _ ->
               Error
                 { call_id = receipt_call_id receipt
                 ; receipt
                 ; cause = Invalid_json_output
                 ; raw_response = Some (raw_response evidence)
                 })
          | (Json_syntax_only | Provider_schema_requested), _ ->
            Error
              { call_id = receipt_call_id receipt
              ; receipt
              ; cause = Internal_non_json_output
              ; raw_response = Some (raw_response evidence)
              })))
;;

let execute_once ~net ?clock attempt =
  execute_once_with_publication ~publish:ignore ~net ?clock attempt
;;

let execution_failure_may_advance (error : execution_error) =
  match error.cause, receipt_phase error.receipt with
  | Completion_failed, Before_dispatch -> receipt_dispatch_count error.receipt = 0
  | Serialized_request_refused _, Response_received ->
    (* The response contract proves that the provider rejected this input before
       generation. Keep the honest one-dispatch receipt, but allow the frozen
       lane to try its predetermined successor. *)
    receipt_dispatch_count error.receipt = 1
  | Invalid_json_output, (Response_received | Terminal) ->
    receipt_dispatch_count error.receipt = 1
  | Completion_failed, (Not_started | Dispatch_started | Response_received | Terminal)
  | ( Serialized_request_refused _
    , (Not_started | Before_dispatch | Dispatch_started | Terminal) )
  | Invalid_json_output, (Not_started | Before_dispatch | Dispatch_started)
  | ( ( Attempt_already_started
      | Clock_required_for_timeout
      | Frozen_request_mismatch
      | Incomplete_output
      | Missing_output
      | Ambiguous_output _
      | Unexpected_output_content
      | Internal_non_json_output )
    , _ ) -> false
;;

let admitted_flow_candidate visit (plan : ready_plan) =
  { visit
  ; plan_fingerprint = plan.plan_fingerprint
  ; request_body_sha256 = plan.request_body_sha256
  ; provenance = plan.provenance
  ; measurement = plan.measurement
  }
;;

let record_candidate_rejection (flow : flow_attempt) visit cause measurement =
  let rejection = { visit; cause; measurement } in
  Flow_state.record_admission flow.progress (Candidate_rejected rejection);
  rejection
;;

let execute_flow_candidate
      ~net
      ?clock
      ~before_measurement_dispatch
      ~on_measurement_terminal
      ~before_dispatch
      flow
      (candidate : flow_candidate_step)
  =
  let reject
        ?(measurement =
          { dispatch = No_measurement_dispatch; outcome = Measurement_not_required })
        cause
    =
    let rejection = record_candidate_rejection flow candidate.visit cause measurement in
    Error (Flow_step_candidate_rejected rejection)
  in
  match resolve_target candidate.admitted_target with
  | Error cause -> reject (Target_selection_rejected cause)
  | Ok target ->
    let flow_measurement receipt : flow_measurement_receipt =
      { visit = candidate.visit; receipt }
    in
    (match
       admit_candidate_request
         ~net
         ?clock
         ~on_measurement_receipt:(fun receipt ->
           let measurement = flow_measurement receipt in
           publish_measurement flow measurement)
         ~before_measurement_dispatch:(fun receipt ->
           before_measurement_dispatch (flow_measurement receipt))
         ~on_measurement_terminal:(fun receipt ->
           on_measurement_terminal (flow_measurement receipt))
         ~target
         ~messages:flow.messages
         flow.requirement
     with
     | Error (Flow_request_admission_failed (cause, measurement)) ->
       reject ~measurement (Request_admission_rejected cause)
     | Error (Flow_request_measurement_start_failed detail) ->
       Error
         (Flow_step_measurement_start_failed
            (candidate.visit, Measurement_operation_id_generation_failed detail))
     | Error Flow_request_measurement_clock_required_for_timeout ->
       Error
         (Flow_step_measurement_start_failed
            (candidate.visit, Measurement_clock_required_for_timeout))
     | Error (Flow_request_before_measurement_dispatch_failed (receipt, cause)) ->
       Error
         (Flow_step_before_measurement_dispatch_callback_failed
            (flow_measurement receipt, cause))
     | Error (Flow_request_measurement_terminal_callback_failed (receipt, cause)) ->
       Error
         (Flow_step_measurement_terminal_callback_failed (flow_measurement receipt, cause))
     | Ok plan ->
       let admitted = admitted_flow_candidate candidate.visit plan in
       Flow_state.record_admission flow.progress (Candidate_admitted admitted);
       (match start_attempt plan with
        | Error cause -> Error (Flow_step_attempt_start_failed (candidate.visit, cause))
        | Ok attempt ->
          let candidate_receipt : flow_attempt_receipt =
            { visit = candidate.visit; receipt = attempt_receipt attempt }
          in
          publish_attempt_snapshot flow candidate_receipt;
          (match before_dispatch candidate_receipt with
           | Error cause ->
             Error (Flow_step_before_dispatch_callback_failed (candidate_receipt, cause))
           | Ok () ->
             (match
                execute_once_with_publication
                  ~publish:(fun () -> publish_attempt_snapshot flow candidate_receipt)
                  ~net
                  ?clock
                  attempt
              with
              | Ok success -> Ok (candidate_receipt, success)
              | Error cause ->
                Error
                  (Flow_step_execution_failed { candidate = candidate_receipt; cause })))))
;;

let advanceable_flow_failure = function
  | Flow_step_candidate_rejected receipt
    when receipt.measurement.dispatch = No_measurement_dispatch ->
    Some (Flow_candidate_rejected receipt)
  | Flow_step_candidate_rejected _ -> None
  | Flow_step_execution_failed ({ cause; _ } as failure)
    when execution_failure_may_advance cause ->
    Some
      (Flow_candidate_execution_failed
         { candidate = failure.candidate; cause = failure.cause })
  | Flow_step_execution_failed _
  | Flow_step_attempt_start_failed _
  | Flow_step_measurement_start_failed _
  | Flow_step_before_measurement_dispatch_callback_failed _
  | Flow_step_measurement_terminal_callback_failed _
  | Flow_step_before_dispatch_callback_failed _ -> None
;;

let execute_flow_once
      ~net
      ?clock
      ~before_measurement_dispatch
      ~on_measurement_terminal
      ~before_dispatch
      ~before_advance
      ~validate
      flow
  =
  let outcome =
    Flow_state.execute_once
      flow.execution
      ~candidates:flow.candidates
      ~execute:
        (execute_flow_candidate
           ~net
           ?clock
           ~before_measurement_dispatch
           ~on_measurement_terminal
           ~before_dispatch
           flow)
      ~validate:(fun _candidate (candidate, success) ->
        let transport_success =
          { candidate; success; evidence = flow_attempt_evidence flow }
        in
        match validate transport_success with
        | Accept accepted -> Flow_state.Accept (accepted, transport_success)
        | Reject_and_advance rejection ->
          Flow_state.Reject_and_advance { transport_success; rejection })
      ~advanceable:advanceable_flow_failure
      ~before_advance:(fun ~failed:_ ~failure ~next ->
        match before_advance ~failed:failure ~next:next.visit with
        | Error _ as error -> error
        | Ok () ->
          Flow_state.record_advance
            flow.progress
            { failed = flow_advance_failure_snapshot failure; next = next.visit };
          Ok ())
  in
  let evidence = flow_attempt_evidence flow in
  let terminal prior_rejections cause =
    Error (Flow_execution_terminal { cause; prior_rejections })
  in
  match outcome with
  | Flow_state.Succeeded { accepted = accepted, transport_success; prior_rejections } ->
    Ok { accepted; transport_success; prior_rejections }
  | Flow_state.Semantic_candidates_exhausted { first_rejection; rest_rejections } ->
    Error
      (Flow_semantic_candidates_exhausted
         { rejections = { first = first_rejection; rest = rest_rejections }; evidence })
  | Flow_state.Attempt_already_started ->
    terminal [] (Flow_attempt_already_started evidence)
  | Flow_state.Before_advance_callback_failed
      { failure; next_candidate; cause; prior_rejections; _ } ->
    terminal
      prior_rejections
      (Flow_before_advance_callback_failed
         { failed = failure; next = next_candidate.visit; cause; evidence })
  | Flow_state.Execution_failed { cause; prior_rejections; _ } ->
    let cause =
      match cause with
      | Flow_step_candidate_rejected rejection ->
        Flow_candidates_exhausted { rejection; evidence }
      | Flow_step_attempt_start_failed (candidate, cause) ->
        Flow_attempt_start_failed { candidate; cause; evidence }
      | Flow_step_measurement_start_failed (candidate, cause) ->
        Flow_measurement_start_failed { candidate; cause; evidence }
      | Flow_step_before_measurement_dispatch_callback_failed (measurement, cause) ->
        Flow_before_measurement_dispatch_callback_failed { measurement; cause; evidence }
      | Flow_step_measurement_terminal_callback_failed (measurement, cause) ->
        Flow_measurement_terminal_callback_failed { measurement; cause; evidence }
      | Flow_step_before_dispatch_callback_failed (candidate, cause) ->
        Flow_before_dispatch_callback_failed { candidate; cause; evidence }
      | Flow_step_execution_failed { candidate; cause; _ } ->
        Flow_exact_execution_failed { candidate; cause; evidence }
    in
    terminal prior_rejections cause
;;
