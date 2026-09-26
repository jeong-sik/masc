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

type provider_refusal =
  | Request_body_refused
  | Refusal_body_not_received
  | Rate_limited
  | Overloaded
  | Server_error
  | Auth_failed
  | Authorization_refused
  | Payment_required
  | Invalid_request
  | Not_found
  | Context_overflow
  | Input_capacity
  | Network_error
  | Timeout

let provider_refusal_to_string = function
  | Request_body_refused -> "request_body_refused"
  | Refusal_body_not_received -> "refusal_body_not_received"
  | Rate_limited -> "rate_limited"
  | Overloaded -> "overloaded"
  | Server_error -> "server_error"
  | Auth_failed -> "auth_failed"
  | Authorization_refused -> "authorization_refused"
  | Payment_required -> "payment_required"
  | Invalid_request -> "invalid_request"
  | Not_found -> "not_found"
  | Context_overflow -> "context_overflow"
  | Input_capacity -> "input_capacity"
  | Network_error -> "network_error"
  | Timeout -> "timeout"
;;

type generation_dispatch_fact =
  | No_generation_dispatch
  | Generation_dispatch_started

type execution_error_cause =
  | Attempt_already_started
  | Clock_required_for_timeout
  | Frozen_request_mismatch
  | Completion_failed of
      { error : Http_client.http_error
      ; dispatch : generation_dispatch_fact
      }
  | Response_body_deadline_exceeded
  | Provider_response_refused of
      { http_status : int
      ; refusal : provider_refusal
      ; retry_after_s : float option
      }
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
  ; usage : Types.api_usage option
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

type flow_execution_terminal_kind =
  | Advanceable_candidates_exhausted
  | Non_advanceable_terminal

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

let flow_evidence_generation_dispatch (evidence : flow_evidence) =
  if
    List.exists
      (fun (attempt : flow_attempt_snapshot) ->
         Generation_receipt.snapshot_generation_dispatched attempt.receipt)
      evidence.attempts
  then Generation_dispatch_started
  else No_generation_dispatch
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
let generation_receipt_snapshot_phase = Generation_receipt.snapshot_phase

let generation_receipt_snapshot_http_status = Generation_receipt.snapshot_http_status

let generation_receipt_snapshot_provider_trace =
  Generation_receipt.snapshot_provider_trace
;;

let generation_receipt_snapshot_dispatch_count =
  Generation_receipt.snapshot_dispatch_count
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
  | Missing_deadline _
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
  | Output_reservation_unavailable
  | Token_measurement_failed
  | Target_request_rejected _
  | Request_serialization_rejected _
  | Measured_request_mismatch -> Request_preparation_failed
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
;;

(* A refusal the transport or the provider config produced, said once for both
   the evidence record and the operator-facing line: the sentence inside the
   typed error, and only that. The provider-error rendering was tried first
   and opened every line with "Provider '' ..." -- this renderer has no
   provider name, and the slot id already stands beside the reason in the
   line that carries it. Exhaustive on purpose: a new transport error must
   say here what its sentence is. *)
let refusal_reason = function
  | Http_client.AcceptRejected { reason } -> reason
  | Http_client.HttpError { code; body; retry_after_header = _ } ->
    Printf.sprintf "http %d: %s" code (Http_client.refusal_body_text body)
  | Http_client.NetworkError { message; kind = _ } -> message
  | Http_client.TimeoutError { message; phase } ->
    Printf.sprintf "%s timeout: %s" (Http_client.timeout_phase_to_label phase) message
  | Http_client.ProviderTerminal { kind = Http_client.Session_conflict; message } ->
    "session conflict: " ^ message
  | Http_client.ProviderTerminal { kind = Http_client.Other reason; message } ->
    reason ^ ": " ^ message
  | Http_client.ProviderFailure { kind; message } ->
    Http_client.provider_failure_to_string ~kind ~message

(* The provider a deadline refusal names, rendered for a line a person
   reads. [None] is said as such rather than left blank: a config with no
   provider id is a fact about that config, not a missing word. The whole
   detail is quoted where it lands in a reason line, so the id is not. *)
let missing_deadline_provider_label = function
  | Some provider_id -> provider_id
  | None -> "(config names no provider)"
;;

(* What a deadline refusal tells an operator to do. The target's body
   deadline has two spellings, one per surface that declares targets: a
   runtime.toml provider's [exact-body-timeout-s], and a replacement
   catalog's [[targets]] row [body_timeout_s]. Which one built this target
   is not known here, so both are named. The connect deadline is named
   because it is what an operator who set one expects to have been enough. *)
let missing_deadline_detail provider_id =
  Printf.sprintf
    "provider %s declares no whole-request deadline: set exact-body-timeout-s \
     on that provider in runtime.toml, or body_timeout_s on its \
     AGENT_CORE_MODEL_CATALOG [[targets]] row. connect-timeout-s ends when the \
     response headers arrive and does not bound the response body"
    (missing_deadline_provider_label provider_id)
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
  | Missing_deadline { provider_id } ->
    `Assoc
      [ "kind", `String "missing_deadline"
      ; ( "provider_id"
        , Option.fold ~none:`Null ~some:(fun value -> `String value) provider_id )
      ; "detail", `String (missing_deadline_detail provider_id)
      ]
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
  | Target_request_rejected refusal ->
    `Assoc
      [ "kind", `String "target_request_rejected"
      ; "detail", `String (refusal_reason refusal)
      ]
  | Request_serialization_rejected refusal ->
    `Assoc
      [ "kind", `String "request_serialization_rejected"
      ; "detail", `String (refusal_reason refusal)
      ]
  | Measured_request_mismatch -> `Assoc [ "kind", `String "measured_request_mismatch" ]
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

(* One readable line naming the refusing condition, for log and failure
   records. The evidence JSON serves registries; a person reading a WARN
   needs the reason in the line itself. Kind names match the evidence kinds
   so a grep finds both spellings. The match is exhaustive on purpose: a
   new wire error variant must be named here to compile, not fall into an
   unnamed bucket. *)
let quoted_dynamic value = Printf.sprintf "%S" value

let wire_admission_error_reason = function
  | Capability_snapshot_missing -> "capability_snapshot_missing"
  | Output_contract_unavailable -> "output_contract_unavailable"
  | Cross_feature_not_allowed -> "cross_feature_not_allowed"
  | Global_admission_not_allowed -> "global_admission_not_allowed"
  | Invalid_connect_timeout -> "invalid_connect_timeout"
  | Invalid_body_timeout -> "invalid_body_timeout"
  | Missing_deadline { provider_id } ->
    Printf.sprintf
      "missing_deadline(%s)"
      (quoted_dynamic (missing_deadline_detail provider_id))
  | Caller_supplied_header_not_allowed ->
    "caller_supplied_header_not_allowed"
  | Unsupported_image_input -> "unsupported_image_input"
  | Unsupported_document_input -> "unsupported_document_input"
  | Unsupported_audio_input -> "unsupported_audio_input"
  | Unsupported_system_prompt -> "unsupported_system_prompt"
  | Token_measurement_required _ -> "token_measurement_required"
  | Context_limit_unavailable -> "context_limit_unavailable"
  | Invalid_context_limit -> "invalid_context_limit"
  | Output_reservation_unavailable -> "output_reservation_unavailable"
  | Measured_context_window_exceeded _ -> "measured_context_window_exceeded"
  | Measured_serving_constraint_rejected _ ->
    "measured_serving_constraint_rejected"
  | Token_measurement_failed -> "token_measurement_failed"
  | Unsupported_target_model { model_id } ->
    Printf.sprintf "unsupported_target_model(%s)" (quoted_dynamic model_id)
  | Target_request_rejected refusal ->
    Printf.sprintf "target_request_rejected(%s)" (quoted_dynamic (refusal_reason refusal))
  | Request_serialization_rejected refusal ->
    Printf.sprintf
      "request_serialization_rejected(%s)"
      (quoted_dynamic (refusal_reason refusal))
  | Measured_request_mismatch -> "measured_request_mismatch"
;;

let admission_error_reason = function
  | Provider_schema_unavailable -> "provider_schema_unavailable"
  | Unsupported_schema_keyword keyword ->
    Printf.sprintf "unsupported_schema_keyword(%s)" (quoted_dynamic keyword)
  | Unsupported_schema_type schema_type ->
    Printf.sprintf "unsupported_schema_type(%s)" (quoted_dynamic schema_type)
  | Invalid_schema -> "invalid_schema"
  | Wire_admission_rejected cause ->
    "wire_admission_rejected:" ^ wire_admission_error_reason cause
;;

let target_selection_error_reason = function
  | Missing_target_credential { target_ref; environment_variable } ->
    Printf.sprintf
      "missing_target_credential(target_ref=%s environment_variable=%s)"
      (quoted_dynamic target_ref)
      (quoted_dynamic environment_variable)
  | Target_credential_invalid { target_ref; environment_variable } ->
    Printf.sprintf
      "target_credential_invalid(target_ref=%s environment_variable=%s)"
      (quoted_dynamic target_ref)
      (quoted_dynamic environment_variable)
  | Target_credential_read_failed { target_ref; environment_variable } ->
    Printf.sprintf
      "target_credential_read_failed(target_ref=%s environment_variable=%s)"
      (quoted_dynamic target_ref)
      (quoted_dynamic environment_variable)
;;

let candidate_rejection_reason (receipt : candidate_rejection_receipt) =
  match receipt.cause with
  | Target_selection_rejected cause -> target_selection_error_reason cause
  | Request_admission_rejected cause -> admission_error_reason cause
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
  | Flow_advance_execution_failed { cause = Completion_failed _; raw_response_sha256; _ } ->
    Ok (Validated_flow_evidence.Completion_failed_before_dispatch, raw_response_sha256)
  | Flow_advance_execution_failed
      { cause = Response_body_deadline_exceeded; raw_response_sha256; _ } ->
    Ok (Validated_flow_evidence.Response_body_deadline_exceeded, raw_response_sha256)
  | Flow_advance_execution_failed
      { cause = Provider_response_refused { http_status; refusal = Request_body_refused; _ }
      ; raw_response_sha256
      ; _
      } ->
    Ok
      ( Validated_flow_evidence.Serialized_request_refused { http_status }
      , raw_response_sha256 )
  | Flow_advance_execution_failed
      { cause = Provider_response_refused { http_status; refusal = Rate_limited; _ }
      ; raw_response_sha256
      ; _
      } ->
    Ok (Validated_flow_evidence.Rate_limited { http_status }, raw_response_sha256)
  | Flow_advance_execution_failed
      { cause = Provider_response_refused { http_status; refusal = Overloaded; _ }
      ; raw_response_sha256; _ } ->
    Ok (Validated_flow_evidence.Overloaded { http_status }, raw_response_sha256)
  | Flow_advance_execution_failed
      { cause = Provider_response_refused { http_status; refusal = Server_error; _ }
      ; raw_response_sha256; _ } ->
    Ok (Validated_flow_evidence.Server_error { http_status }, raw_response_sha256)
  | Flow_advance_execution_failed { cause = Invalid_json_output; raw_response_sha256; _ }
    -> Ok (Validated_flow_evidence.Invalid_json_output, raw_response_sha256)
  | Flow_advance_execution_failed { cause; _ } ->
    let detail =
      match cause with
      | Attempt_already_started -> "attempt_already_started"
      | Clock_required_for_timeout -> "clock_required_for_timeout"
      | Frozen_request_mismatch -> "frozen_request_mismatch"
      | Completion_failed _ -> "completion_failed"
      | Response_body_deadline_exceeded -> "response_body_deadline_exceeded"
      | Provider_response_refused { http_status; refusal; _ } ->
        Printf.sprintf
          "provider_response_refused:%s:%d"
          (provider_refusal_to_string refusal)
          http_status
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

(* [Retry] already classifies a provider response; this projects that verdict
   onto the flow's vocabulary WITHOUT collapsing it. The previous form answered
   one question ("was this a body refusal?") and returned [None] for the other
   twelve, and the caller read that [None] as "no status to report" — which is
   how a 429 reached the keeper log as a bare "completion failed" with neither
   its status nor its kind, and why the lane could not advance off it. *)
let provider_refusal_of_api_error : Retry.api_error -> provider_refusal = function
  | Retry.InvalidRequest { reason = Retry.Request_body_refused_by_provider _; _ } ->
    Request_body_refused
  | Retry.InvalidRequest { reason = Retry.Refusal_body_not_received; _ } ->
    Refusal_body_not_received
  | Retry.InvalidRequest _ -> Invalid_request
  | Retry.RateLimited _ -> Rate_limited
  | Retry.Overloaded _ -> Overloaded
  | Retry.ServerError _ -> Server_error
  | Retry.AuthError _ -> Auth_failed
  | Retry.AuthorizationError _ -> Authorization_refused
  | Retry.PaymentRequired _ -> Payment_required
  | Retry.NotFound _ -> Not_found
  | Retry.ContextOverflow _ -> Context_overflow
  | Retry.InputCapacity _ -> Input_capacity
  | Retry.NetworkError _ -> Network_error
  | Retry.Timeout _ -> Timeout
;;

(* The one wait a refusal names, kept beside the collapsed refusal so a caller
   that holds per-binding rate-limit evidence can honour the provider's own
   Retry-After instead of guessing one. Only a rate limit carries it. *)
let retry_after_of_api_error : Retry.api_error -> float option = function
  | Retry.RateLimited { retry_after; _ } -> retry_after
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

(* The candidate-fault judgment projects onto the flow's collapsed refusal
   vocabulary. [provider_refusal] folds [Retry.InvalidRequest]'s five reasons
   to one [Invalid_request]; that collapsed refusal is the un-attributed one,
   and [Refusal_body_not_received] is the unread one. A new [provider_refusal]
   constructor stops compilation here, so the two walks stay on one judgment
   (RFC-one-slot-fault-judgment-for-every-walk.md, #38472). *)
let candidate_fault_of_provider_refusal : provider_refusal -> Candidate_fault.t = function
  | Request_body_refused -> Binding Body_limit
  | Refusal_body_not_received -> Binding Refusal_unread
  | Rate_limited -> Binding Rate_limit
  | Overloaded -> Binding Capacity
  | Server_error -> Binding Server
  | Auth_failed -> Binding Credential
  | Authorization_refused -> Binding Credential
  | Payment_required -> Binding Account
  | Invalid_request -> Unattributed
  | Not_found -> Binding Model_absent
  | Context_overflow -> Binding Window
  | Input_capacity -> Binding Admission
  | Network_error -> Unknown_after_dispatch
  | Timeout -> Binding Deadline
;;

let execution_error_cause ~http_status ~dispatch = function
  | Exec.Clock_required_for_timeout -> Clock_required_for_timeout
  | Exec.Frozen_request_mismatch -> Frozen_request_mismatch
  | Exec.Response_body_deadline_exceeded -> Response_body_deadline_exceeded
  | Exec.Provider_error (Http_client.HttpError { code; body; retry_after_header }) ->
    let api_error = Retry.classify_refusal ~retry_after_header ~status:code ~body in
    Provider_response_refused
      { http_status = code
      ; refusal = provider_refusal_of_api_error api_error
      ; retry_after_s = retry_after_of_api_error api_error
      }
  | Exec.Provider_error
      (Http_client.ProviderFailure { kind = Http_client.Context_overflow _; _ } as error) ->
    (match http_status with
     | Some http_status ->
       Provider_response_refused
         { http_status; refusal = Context_overflow; retry_after_s = None }
     | None -> Completion_failed { error; dispatch })
  (* An empty answer the provider stopped at its window is the same refusal in
     another shape. [Retry.overflow_of_empty_completion] is the one rule for
     which empty answers those are. *)
  | Exec.Provider_error
      (Http_client.ProviderFailure
         { kind = Http_client.Empty_completion { stop_reason }; message } as error) ->
    (match Retry.overflow_of_empty_completion ~stop_reason ~message, http_status with
     | Some overflow, Some http_status ->
       Provider_response_refused
         { http_status
         ; refusal = provider_refusal_of_api_error overflow
         ; retry_after_s = None
         }
     | Some _, None | None, (Some _ | None) -> Completion_failed { error; dispatch })
  (* Other transport, provider parsing or observer failures remain distinct
     from an owned body deadline, even when their receipt has headers. The
     typed transport error travels with the cause so a consumer can tell a
     dropped connection from a hard quota or an empty completion. *)
  | Exec.Provider_error
      (( Http_client.NetworkError _ | Http_client.TimeoutError _
       | Http_client.AcceptRejected _ | Http_client.ProviderTerminal _
       | Http_client.ProviderFailure _ ) as error) -> Completion_failed { error; dispatch }
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
        ; cause =
            execution_error_cause
              ~http_status:(receipt_http_status receipt)
              ~dispatch:(generation_dispatch_fact_of_receipt receipt)
              cause
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
      (* The wire's response parser already read the usage report when it
         built [outcome.response], from the same parse that produced the
         output; the body is not read a second time for it. *)
      let usage = Types.usage_of_response outcome.response in
      (match outcome.output with
       | Exec.Json_output { value; _ } ->
         Ok
           { call_id = receipt_call_id receipt
           ; receipt
           ; output = value
           ; provenance = ready.provenance
           ; raw_response = raw_response evidence
           ; usage
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
                 ; usage
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

let execution_failure_may_advance (error : execution_error) =
  match error.cause, receipt_phase error.receipt with
  | Completion_failed _, Before_dispatch -> receipt_dispatch_count error.receipt = 0
  (* The request went out and this binding did not answer within its own
     deadline. How long a binding takes is a property of the binding, as its
     quota is: the successor carries its own deadline and may serve the same
     input. Exact requests have no tools and no domain validator ran, so the
     one unanswered dispatch is the only thing left behind, and the receipt
     keeps it as a fact. On the Librarian lane (2026-09-23) 51 of 85 failed
     runs ended this way at the first slot, and their successors were never
     tried. *)
  | Completion_failed { error = Http_client.TimeoutError { phase; _ }; _ }, Dispatch_started ->
    (match phase with
     (* [post_sync_once] ends a sent request that has no response headers
        with one of these two: the header deadline ([connect_timeout_s]) or
        the total deadline ([body_timeout_s]) when it is the earlier one. *)
     | Http_client.Http_operation | Http_client.Wall_clock ->
       receipt_dispatch_count error.receipt = 1
     (* The exact transport does not produce these after dispatch. One that
        starts to needs its own argument that the successor may serve the
        same input. *)
     | Http_client.Queue
     | Http_client.First_token
     | Http_client.Capacity_backpressure
     | Http_client.Non_streaming_body
     | Http_client.Stream_body
     | Http_client.Stream_idle _
     | Http_client.Provider_step
     | Http_client.Cli_stdout_idle
     | Http_client.Unknown_timeout -> false)
  (* The provider answered that this binding's account is out of quota: a
     quota code the glm codec reads as [Hard_quota], the fact a 402 states.
     The successor bills its own account, so the lane walks it as it walks a
     402 or a 429. *)
  | ( Completion_failed
        { error = Http_client.ProviderFailure { kind = Http_client.Hard_quota _; _ }; _ }
    , Response_received ) -> receipt_dispatch_count error.receipt = 1
  | Response_body_deadline_exceeded, Response_received ->
    (* No domain validator ran for this incomplete response. Advance through
       the caller's existing settlement callback, retaining the dispatched
       request and missing body as facts rather than claiming no effect. *)
    receipt_dispatch_count error.receipt = 1
    && Option.fold ~none:false ~some:Cohttp.Code.is_success
         (receipt_http_status error.receipt)
    && Option.is_none error.raw_response
    && Option.is_none (receipt_provider_trace error.receipt)
  (* A refusal admits the successor only when the response proves the refusal
     belongs to THIS binding and not to the input itself — otherwise the
     successor replays a request that is already known to fail. *)
  | Provider_response_refused { refusal = Request_body_refused; _ }, Response_received ->
    (* The response contract proves that the provider rejected this input before
       generation. Keep the honest one-dispatch receipt, but allow the frozen
       lane to try its predetermined successor. *)
    receipt_dispatch_count error.receipt = 1
  | Provider_response_refused { refusal = Rate_limited; _ }, Response_received ->
    (* Quota is a property of the binding, not of the request: the successor
       carries its own. This is what an ordered lane of candidates is for, and
       until the refusal kind survived classification the lane could not reach
       it — a 429 arrived here as [Completion_failed] and ended the flow. *)
    receipt_dispatch_count error.receipt = 1
  | Provider_response_refused { refusal = Payment_required; _ }, Response_received ->
    (* A 402 is a refusal before any generation ran, and the successor bills a
       different account, so the frozen lane walks its next candidate instead
       of ending. It is not always the account alone: OpenRouter compares
       [max_tokens] times price against the balance, so a smaller request
       could pass on the same account — either way the successor is a fresh
       chance. The one-dispatch receipt stays as
       evidence. Same shape as [Rate_limited] — this promotion is what lets a
       lane whose last HTTP slot is out of paid quota fall through to its CLI
       tail instead of recording a permanent failure. *)
    receipt_dispatch_count error.receipt = 1
  | Provider_response_refused
      { refusal = Overloaded | Server_error; _ }, Response_received ->
    (* The provider returned a complete failure response. Exact requests have
       no tools and this failure has not entered the domain validator, so the
       declared successor may serve the same input. Keep the failed dispatch
       and response as evidence; an interrupted/unknown dispatch is not this
       case, and neither is a status whose refusal body was not received. *)
    receipt_dispatch_count error.receipt = 1
  | Provider_response_refused { refusal = Context_overflow; _ }, Response_received ->
    (* The provider refused this input as larger than its window, before
       generating: a typed overflow, or an empty answer stopped at the window.
       A window is a property of the binding, as its quota and its deadline
       are: the successor carries its own and may take the same input. When every candidate refuses, the walk ends on the last refusal
       and the caller still reads the size from every advance it made. On the
       Librarian lane (2026-09-22) 105 passes ended here at glm-5.3-flash
       ("Prompt exceeds max length") and never reached the lane's declared
       Claude CLI slot. *)
    receipt_dispatch_count error.receipt = 1
  | Invalid_json_output, (Response_received | Terminal) ->
    receipt_dispatch_count error.receipt = 1
  (* The response arrived and terminated, but this binding routed the whole
     answer into a non-content field and left content empty. Where the answer
     lands is a property of the binding's output dialect, the same way a quota
     is a property of the binding: the successor carries its own dialect, so
     the lane tries it instead of terminating. Measured on json_object-only
     providers where thinking cannot be disabled on every dialect: 54 turns
     on ollama.com and 36 on glm with the schema-complete answer sitting in
     the reasoning field (2026-08-16/08-27). *)
  | Missing_output, (Response_received | Terminal) ->
    receipt_dispatch_count error.receipt = 1
  (* One closed judgment decides whose affair a refusal is (Candidate_fault,
     RFC-one-slot-fault-judgment-for-every-walk.md, #38472). §3.3: 401·403·404
     are this binding's affair — the key, permission, or model is missing
     here, not in the request — so the successor carries its own and may serve
     the same input. §3.4: an un-attributed refusal (the collapsed
     Invalid_request) is advanced too, since no response yet proves the input
     itself is what failed. §2.1: Refusal_body_not_received is the unread
     refusal. Exact requests have no tools, so advancing cannot double an
     effect. *)
  | Provider_response_refused { refusal; _ }, Response_received
    when (match candidate_fault_of_provider_refusal refusal with
          | Candidate_fault.Binding _ | Candidate_fault.Unattributed -> true
          | Candidate_fault.Unknown_after_dispatch -> false) ->
    receipt_dispatch_count error.receipt = 1
  (* The remaining transport and non-advance refusals do not advance. *)
  | ( Provider_response_refused
        { refusal =
            ( Auth_failed
            | Authorization_refused
            | Invalid_request
            | Refusal_body_not_received
            | Not_found
            | Input_capacity
            | Network_error
            | Timeout )
        ; _
        }
    , (Not_started | Before_dispatch | Dispatch_started | Terminal) )
  | Completion_failed _, (Not_started | Dispatch_started | Response_received | Terminal)
  | Response_body_deadline_exceeded,
      (Not_started | Before_dispatch | Dispatch_started | Terminal)
  | ( Provider_response_refused
        { refusal =
            ( Request_body_refused
            | Rate_limited
            | Overloaded
            | Server_error
            | Payment_required
            | Context_overflow )
        ; _
        }
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
    , _ )
  | ( Provider_response_refused _, _ ) -> false
;;

let candidate_rejection_may_advance (receipt : candidate_rejection_receipt) =
  receipt.measurement.dispatch = No_measurement_dispatch
;;

let flow_execution_terminal_kind = function
  | Flow_candidates_exhausted { rejection; _ }
    when candidate_rejection_may_advance rejection ->
    Advanceable_candidates_exhausted
  | Flow_exact_execution_failed { cause; _ }
    when execution_failure_may_advance cause ->
    Advanceable_candidates_exhausted
  | Flow_attempt_already_started _
  | Flow_attempt_start_failed _
  | Flow_measurement_start_failed _
  | Flow_before_measurement_dispatch_callback_failed _
  | Flow_measurement_terminal_callback_failed _
  | Flow_before_dispatch_callback_failed _
  | Flow_before_advance_callback_failed _
  | Flow_candidates_exhausted _
  | Flow_exact_execution_failed _ ->
    Non_advanceable_terminal
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
    when candidate_rejection_may_advance receipt ->
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

(* Text renderers for the exact-output error family (#27861). They exist so a
   consumer never reimplements this classification or drops a payload behind
   [_]: every match below is exhaustive with no catch-all, so a new
   constructor is a compile error here. Numeric fields are printed because
   they are what tells a local capacity refusal from a provider outage. The
   strings are for logs and operator lines only; nothing may branch on them.
   A transport error is rendered by its typed kind, never by its message,
   because a message can echo request material. A raw provider body is
   rendered by the caller's [raw_response_to_string]: AGENT_CORE offers only
   the sha256 ([raw_response_sha256_to_string]), and a consumer that owns a
   redactor may pass a redacted excerpt instead. *)

let optional_token_count_to_string = function
  | None -> "unknown"
  | Some tokens -> string_of_int tokens
;;

let token_capacity_rejection_to_string : token_capacity_rejection -> string = function
  | Capacity_evidence_not_yet_valid { now_unix_s; checked_at_unix_s } ->
    Printf.sprintf
      "capacity evidence not yet valid (now=%d checked_at=%d)"
      now_unix_s
      checked_at_unix_s
  | Capacity_evidence_expired { now_unix_s; expires_at_unix_s } ->
    Printf.sprintf
      "capacity evidence expired (now=%d expires_at=%d)"
      now_unix_s
      expires_at_unix_s
  | Capacity_boundary_unknown { input_tokens; accepted_through_tokens; rejected_from_tokens }
    ->
    Printf.sprintf
      "capacity boundary unknown (input=%d accepted_through=%d rejected_from=%s)"
      input_tokens
      accepted_through_tokens
      (optional_token_count_to_string rejected_from_tokens)
  | Capacity_input_rejected { input_tokens; accepted_through_tokens; rejected_from_tokens }
    ->
    Printf.sprintf
      "capacity input rejected (input=%d accepted_through=%d rejected_from=%d)"
      input_tokens
      accepted_through_tokens
      rejected_from_tokens
;;

let input_capacity_disposition_to_string : input_capacity_disposition -> string =
  function
  | Token_measurement_required { accepted_through_tokens; rejected_from_tokens } ->
    Printf.sprintf
      "token measurement required (accepted_through=%d rejected_from=%s)"
      accepted_through_tokens
      (optional_token_count_to_string rejected_from_tokens)
  | Context_window_exceeded { input_tokens; reserved_output_tokens; max_context_tokens } ->
    Printf.sprintf
      "context window exceeded (input=%d reserved_output=%d max_context=%d)"
      input_tokens
      reserved_output_tokens
      max_context_tokens
  | Token_capacity_rejected rejection -> token_capacity_rejection_to_string rejection
;;

let candidate_rejection_disposition_to_string
  : candidate_rejection_disposition -> string
  = function
  | Runtime_slot_unavailable -> "runtime slot unavailable"
  | Runtime_contract_rejected -> "runtime contract rejected"
  | Input_contract_rejected -> "input contract rejected"
  | Output_requirement_rejected -> "output requirement rejected"
  | Input_capacity disposition -> input_capacity_disposition_to_string disposition
  | Request_preparation_failed -> "request preparation failed"
;;

let http_error_kind_to_string : Http_client.http_error -> string = function
  | Http_client.HttpError { code; body = _; retry_after_header = _ } ->
    Printf.sprintf "http_status=%d" code
  | Http_client.NetworkError { kind; message = _ } ->
    "network_error:" ^ Http_client.network_error_kind_to_string kind
  | Http_client.TimeoutError { phase; message = _ } ->
    "timeout:" ^ Http_client.timeout_phase_to_label phase
  | Http_client.AcceptRejected { reason = _ } -> "accept_rejected"
  | Http_client.ProviderTerminal { kind = Http_client.Session_conflict; message = _ } ->
    "provider_terminal:session_conflict"
  | Http_client.ProviderTerminal { kind = Http_client.Other subtype; message = _ } ->
    "provider_terminal:" ^ subtype
  | Http_client.ProviderFailure { kind; message = _ } ->
    Http_client.provider_failure_kind_to_string kind
;;

let generation_dispatch_fact_to_string : generation_dispatch_fact -> string = function
  | No_generation_dispatch -> "not sent"
  | Generation_dispatch_started -> "sent"
;;

let execution_error_cause_to_string : execution_error_cause -> string = function
  | Attempt_already_started -> "attempt already started"
  | Clock_required_for_timeout -> "clock required for timeout"
  | Frozen_request_mismatch -> "frozen request mismatch"
  | Completion_failed { error; dispatch } ->
    Printf.sprintf
      "completion failed (%s, %s)"
      (http_error_kind_to_string error)
      (generation_dispatch_fact_to_string dispatch)
  | Response_body_deadline_exceeded ->
    "total request deadline exceeded while reading response body"
  | Provider_response_refused { http_status; refusal; _ } ->
    Printf.sprintf
      "provider refused (http_status=%d refusal=%s)"
      http_status
      (provider_refusal_to_string refusal)
  | Incomplete_output -> "incomplete output"
  | Missing_output -> "missing output"
  | Ambiguous_output count -> Printf.sprintf "ambiguous output (candidates=%d)" count
  | Unexpected_output_content -> "unexpected output content"
  | Invalid_json_output -> "invalid json output"
  | Internal_non_json_output -> "internal non-json output"
;;

let start_attempt_error_to_string : start_attempt_error -> string = function
  | Call_id_generation_failed detail ->
    Printf.sprintf "call_id_generation_failed detail=%S" detail
;;

let measurement_start_error_to_string : measurement_start_error -> string = function
  | Measurement_operation_id_generation_failed detail ->
    Printf.sprintf "operation_id_generation_failed detail=%S" detail
  | Measurement_clock_required_for_timeout -> "measurement_clock_required_for_timeout"
;;

let candidate_rejection_to_string (rejection : candidate_rejection_receipt) =
  Printf.sprintf
    "slot=%s %s cause=%s"
    rejection.visit.identity.candidate_id
    (candidate_rejection_disposition_to_string
       (candidate_rejection_disposition rejection))
    (candidate_rejection_reason rejection)
;;

let flow_advance_failure_to_string
  : flow_advance_failure_snapshot -> string * string
  = function
  | Flow_advance_candidate_rejected rejection ->
    ( rejection.visit.identity.candidate_id
    , "candidate_rejected cause=" ^ candidate_rejection_reason rejection )
  | Flow_advance_execution_failed { candidate; cause; raw_response_sha256 } ->
    let sha =
      match raw_response_sha256 with
      | None -> ""
      | Some sha -> Printf.sprintf " raw_response_sha256=%s" sha
    in
    ( candidate.visit.identity.candidate_id
    , Printf.sprintf
        "execution_failed cause=%s%s"
        (execution_error_cause_to_string cause)
        sha )
;;

let flow_evidence_to_string (evidence : flow_evidence) =
  let attempts =
    List.map
      (fun (attempt : flow_attempt_snapshot) ->
         Printf.sprintf
           "slot=%s call_id=%s"
           attempt.visit.identity.candidate_id
           (call_id_to_string (generation_receipt_snapshot_call_id attempt.receipt)))
      evidence.attempts
  in
  let advances =
    List.map
      (fun (advance : flow_advance_receipt) ->
         let failed_slot, failure_kind = flow_advance_failure_to_string advance.failed in
         Printf.sprintf
           "advance=%s->%s kind=%s"
           failed_slot
           advance.next.identity.candidate_id
           failure_kind)
      evidence.advances
  in
  match attempts @ advances with
  | [] -> "no candidate attempt or advance was recorded"
  | details -> String.concat "; " details
;;

let raw_response_sha256_to_string : raw_response option -> string = function
  | None -> "raw_response_sha256=none"
  | Some raw -> "raw_response_sha256=" ^ raw.body_sha256
;;

let execution_error_to_string
      ~(raw_response_to_string : raw_response option -> string)
      (error : execution_error)
  =
  Printf.sprintf
    "call_id=%s cause=%s %s"
    (call_id_to_string error.call_id)
    (execution_error_cause_to_string error.cause)
    (raw_response_to_string error.raw_response)
;;

let flow_candidate_failure_to_string ~raw_response_to_string
  : flow_candidate_failure -> string
  = function
  | Flow_candidate_rejected rejection ->
    "candidate_rejected " ^ candidate_rejection_to_string rejection
  | Flow_candidate_execution_failed { candidate; cause } ->
    Printf.sprintf
      "execution_failed slot=%s %s"
      candidate.visit.identity.candidate_id
      (execution_error_to_string ~raw_response_to_string cause)
;;

let flow_execution_error_to_string
      ~(callback_error_to_string : 'callback_error -> string)
      ~(raw_response_to_string : raw_response option -> string)
      (error : 'callback_error flow_execution_error)
  =
  let with_flow evidence detail =
    Printf.sprintf "%s; flow=[%s]" detail (flow_evidence_to_string evidence)
  in
  match error with
  | Flow_attempt_already_started evidence -> with_flow evidence "attempt_already_started"
  | Flow_attempt_start_failed { candidate; cause; evidence } ->
    with_flow
      evidence
      (Printf.sprintf
         "attempt_start_failed: slot=%s cause=%s"
         candidate.identity.candidate_id
         (start_attempt_error_to_string cause))
  | Flow_measurement_start_failed { candidate; cause; evidence } ->
    with_flow
      evidence
      (Printf.sprintf
         "measurement_start_failed: slot=%s cause=%s"
         candidate.identity.candidate_id
         (measurement_start_error_to_string cause))
  | Flow_before_measurement_dispatch_callback_failed { measurement; cause; evidence } ->
    with_flow
      evidence
      (Printf.sprintf
         "before_measurement_dispatch_callback_failed: slot=%s cause=%s"
         measurement.visit.identity.candidate_id
         (callback_error_to_string cause))
  | Flow_measurement_terminal_callback_failed { measurement; cause; evidence } ->
    with_flow
      evidence
      (Printf.sprintf
         "measurement_terminal_callback_failed: slot=%s cause=%s"
         measurement.visit.identity.candidate_id
         (callback_error_to_string cause))
  | Flow_before_dispatch_callback_failed { candidate; cause; evidence } ->
    with_flow
      evidence
      (Printf.sprintf
         "before_dispatch_callback_failed: slot=%s cause=%s"
         candidate.visit.identity.candidate_id
         (callback_error_to_string cause))
  | Flow_before_advance_callback_failed { failed; next; cause; evidence } ->
    with_flow
      evidence
      (Printf.sprintf
         "before_advance_callback_failed: failed=[%s] next=%s cause=%s"
         (flow_candidate_failure_to_string ~raw_response_to_string failed)
         next.identity.candidate_id
         (callback_error_to_string cause))
  | Flow_candidates_exhausted { rejection; evidence } ->
    with_flow evidence ("candidates_exhausted: " ^ candidate_rejection_to_string rejection)
  | Flow_exact_execution_failed { candidate; cause; evidence } ->
    with_flow
      evidence
      (Printf.sprintf
         "execution_failed: slot=%s %s"
         candidate.visit.identity.candidate_id
         (execution_error_to_string ~raw_response_to_string cause))
;;
