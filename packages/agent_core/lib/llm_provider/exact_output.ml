module Plan = Exact_output_plan
module Flow_admission = Exact_output_flow_admission
module Measurement_receipt = Exact_output_measurement_receipt
include Measurement_receipt
module Exec = Exact_output_execution
module Flow_state = Exact_output_flow
module Trace = Exact_output_provider_trace
module Generation_receipt = Exact_output_generation_receipt
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
  | Output_limit_reached
  | Incomplete_output
  | Missing_output
  | Ambiguous_output of int
  | Unexpected_output_content
  | Invalid_json_output

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
  ; admission_class : Admission_class.t
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

type measurement_start_error = Measurement_operation_id_generation_failed of string

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

let start_flow ~admission_class (ready : flow_snapshot) =
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
      ; admission_class
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
  | Missing_declared_target_credential _
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
  | Missing_declared_target_credential { target_ref; provider_id } ->
    Printf.sprintf
      "missing_declared_target_credential(target_ref=%s provider_id=%s)"
      (quoted_dynamic target_ref)
      (quoted_dynamic provider_id)
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
  | Retry.InvalidRequest
      { reason =
          ( Retry.Json_parse_error
          | Retry.Attempt_rejected
          | Retry.Unknown_invalid_request )
      ; _
      } -> Invalid_request
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

let execution_error_cause ~http_status ~dispatch = function
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
  (* Empty OpenAI/GLM content is rejected by the provider parser before JSON
     normalization. Its typed stop reason still proves an output limit. *)
  | Exec.Provider_error
      (Http_client.ProviderFailure
         { kind = Http_client.Empty_completion { stop_reason = Types.MaxTokens }; _ }) ->
    Output_limit_reached
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
       | Http_client.ProviderFailure
           { kind =
               ( Http_client.Capacity_exhausted _
               | Http_client.Hard_quota _
               | Http_client.Capability_mismatch _
               | Http_client.Cli_policy_invalid _
               | Http_client.Cli_startup_failed _
               | Http_client.Provider_parse_error _
               | Http_client.Provider_wire_error _
               | Http_client.Provider_reported_error _
               | Http_client.Provider_interrupted
               | Http_client.Response_body_too_large _
               | Http_client.Repeating_generation _
               | Http_client.Unknown_provider_failure _ )
           ; _
           } ) as error) -> Completion_failed { error; dispatch }
  | Exec.Output_normalization_failed (Exec.Incomplete_structured_response Types.MaxTokens) ->
    Output_limit_reached
  | Exec.Output_normalization_failed
      (Exec.Incomplete_structured_response
         ( Types.EndTurn
         | Types.StopToolUse
         | Types.StopSequence
         | Types.Refusal
         | Types.ContentFilter
         | Types.RepetitionTruncation
         | Types.PauseTurn
         | Types.Compaction
         | Types.ContextWindowExceeded
         | Types.UnmatchedToolCalls
         | Types.Unknown _ )) -> Incomplete_output
  | Exec.Output_normalization_failed Exec.Missing_structured_text -> Missing_output
  | Exec.Output_normalization_failed (Exec.Ambiguous_structured_text count) ->
    Ambiguous_output count
  | Exec.Output_normalization_failed Exec.Unexpected_structured_content ->
    Unexpected_output_content
  | Exec.Output_normalization_failed (Exec.Invalid_json _) -> Invalid_json_output
;;

let execute_once_with_publication ~publish ~net ~clock (attempt : attempt) =
  let ready = attempt.ready in
  let receipt = attempt.receipt in
  match
    Exec.execute_once_with_evidence
      ~net
      ~clock
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
    Ok
      { call_id = receipt_call_id receipt
      ; receipt
      ; output = outcome.output.value
      ; provenance = ready.provenance
      ; raw_response = raw_response evidence
      ; usage
      }
;;

(* An exact walk stops only where masc itself failed: its callbacks, a replay
   of the flow, an identity it could not allocate, and cancellation, which
   propagates as an exception (RFC-exact-lane-walks-one-slot-list.md §3.3,
   Q1). Every execution failure is the binding's or its answer's, so it hands
   the same input to the declared successor. Exact requests carry no tools, so
   a successor cannot double an effect. That holds when the result is unknown
   too -- the request went out and no answer came back, or the stream stopped
   part way: the provider may have billed that dispatch, and the receipt keeps
   it as a fact. A rejected candidate hands the input on whether or not its
   count-tokens measurement went out: measuring is not generating.

   masc's own wiring cannot fail an execution: the plan parses its URL and
   headers when it is frozen, a clock is always passed, an attempt is started
   once by the step that allocated it, and every normalized answer is JSON. *)
let flow_execution_terminal_kind = function
  | Flow_candidates_exhausted _ | Flow_exact_execution_failed _ ->
    Advanceable_candidates_exhausted
  | Flow_attempt_already_started _
  | Flow_attempt_start_failed _
  | Flow_measurement_start_failed _
  | Flow_before_measurement_dispatch_callback_failed _
  | Flow_measurement_terminal_callback_failed _
  | Flow_before_dispatch_callback_failed _
  | Flow_before_advance_callback_failed _ -> Non_advanceable_terminal
;;

type flow_binding_standing =
  | Every_binding_resting
  | Not_every_binding_resting

(* Only refusals that name the binding's own standing -- its quota or rate
   limit spent, its capacity full, its account unable to pay. Every other
   refusal can be about this input (a size, a request shape, a credential, a
   route), so it is not read as rest. *)
let provider_refusal_is_binding_rest = function
  | Rate_limited | Overloaded | Payment_required -> true
  | Request_body_refused
  | Refusal_body_not_received
  | Server_error
  | Auth_failed
  | Authorization_refused
  | Invalid_request
  | Not_found
  | Context_overflow
  | Input_capacity
  | Network_error
  | Timeout -> false
;;

let provider_failure_is_binding_rest : Http_client.provider_failure_kind -> bool =
  function
  | Http_client.Capacity_exhausted _ | Http_client.Hard_quota _ -> true
  | Http_client.Capability_mismatch _
  | Http_client.Cli_policy_invalid _
  | Http_client.Cli_startup_failed _
  | Http_client.Provider_parse_error _
  | Http_client.Provider_wire_error _
  | Http_client.Provider_reported_error _
  | Http_client.Provider_interrupted
  | Http_client.Response_body_too_large _
  | Http_client.Empty_completion _
  | Http_client.Context_overflow _
  | Http_client.Repeating_generation _
  | Http_client.Unknown_provider_failure _ -> false
;;

(* A transport failure before the generation request was dispatched (DNS,
   refused connection, connect timeout) reached no provider, so it says nothing
   about the input, and the binding serves nothing until the network is back.
   After a dispatch the provider may have acted on the request, so the same
   failure is not rest. *)
let execution_cause_is_binding_rest = function
  | Provider_response_refused { refusal; http_status = _ } ->
    provider_refusal_is_binding_rest refusal
  | Completion_failed { error = Http_client.ProviderFailure { kind; message = _ }; dispatch = _ }
    -> provider_failure_is_binding_rest kind
  | Completion_failed
      { error = Http_client.NetworkError _ | Http_client.TimeoutError _
      ; dispatch = No_generation_dispatch
      } -> true
  | Completion_failed
      { error = Http_client.NetworkError _ | Http_client.TimeoutError _
      ; dispatch = Generation_dispatch_started
      } -> false
  | Completion_failed
      { error =
          ( Http_client.HttpError _
          | Http_client.AcceptRejected _
          | Http_client.ProviderTerminal _ )
      ; dispatch = _
      } -> false
  | Response_body_deadline_exceeded
  | Output_limit_reached
  | Incomplete_output
  | Missing_output
  | Ambiguous_output _
  | Unexpected_output_content
  | Invalid_json_output -> false
;;

let flow_execution_binding_standing error =
  let advance_rests (advance : flow_advance_receipt) =
    match advance.failed with
    | Flow_advance_execution_failed { cause; candidate = _; raw_response_sha256 = _ } ->
      execution_cause_is_binding_rest cause
    | Flow_advance_candidate_rejected _ -> false
  in
  match error with
  | Flow_exact_execution_failed { cause; evidence; candidate = _ }
    when execution_cause_is_binding_rest cause.cause
         && List.for_all advance_rests evidence.advances -> Every_binding_resting
  | Flow_attempt_already_started _
  | Flow_attempt_start_failed _
  | Flow_measurement_start_failed _
  | Flow_before_measurement_dispatch_callback_failed _
  | Flow_measurement_terminal_callback_failed _
  | Flow_before_dispatch_callback_failed _
  | Flow_before_advance_callback_failed _
  | Flow_candidates_exhausted _
  | Flow_exact_execution_failed _ -> Not_every_binding_resting
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
      ~clock
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
    (* The flow's class orders both of its permit waits on the endpoint: the
       token-count measurement and the generation dispatch. *)
    let target = selected_target_with_admission_class target flow.admission_class in
    let flow_measurement receipt : flow_measurement_receipt =
      { visit = candidate.visit; receipt }
    in
    (match
       admit_candidate_request
         ~net
         ~clock
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
          let publish () = publish_attempt_snapshot flow candidate_receipt in
          let run () =
            match before_dispatch candidate_receipt with
            | Error cause ->
              Error
                (Flow_step_before_dispatch_callback_failed (candidate_receipt, cause))
            | Ok () ->
              Generation_receipt.start attempt.receipt;
              publish ();
              (match execute_once_with_publication ~publish ~net ~clock attempt with
               | Ok success -> Ok (candidate_receipt, success)
               | Error cause ->
                 Error
                   (Flow_step_execution_failed
                      { candidate = candidate_receipt; cause }))
          in
          let timeout_failure ~phase stage =
            (match Generation_receipt.phase attempt.receipt with
             | Generation_receipt.Not_started ->
               Generation_receipt.start attempt.receipt
             | Before_dispatch | Dispatch_started | Response_received | Terminal -> ());
            publish ();
            let cause =
              { call_id = receipt_call_id attempt.receipt
              ; receipt = attempt.receipt
              ; cause =
                  Completion_failed
                    { error =
                        Http_client.TimeoutError
                          { message =
                              Printf.sprintf
                                "exact body deadline exceeded %s"
                                stage
                          ; phase
                          }
                    ; dispatch =
                        generation_dispatch_fact_of_receipt attempt.receipt
                    }
              ; raw_response = None
              }
            in
            Error
              (Flow_step_execution_failed
                 { candidate = candidate_receipt; cause })
          in
          publish ();
          match target.config.max_concurrent_requests, target.body_timeout_s with
          | None, _ -> run ()
          | Some _, None -> Provider_admission.with_admission ~config:target.config run
          | Some _, Some timeout_s ->
            (match
               Provider_admission.with_admission_and_work_for
                 ~clock
                 ~timeout_s
                 ~config:target.config
                 run
             with
             | Ok result -> result
             | Error Provider_admission.Permit_wait_expired ->
               timeout_failure ~phase:Http_client.Queue
                 "before a provider admission permit was granted"
             | Error Provider_admission.Permit_granted_as_deadline_passed ->
               timeout_failure ~phase:Http_client.Queue
                 "as the provider admission permit was granted"
             | Error Provider_admission.Work_expired ->
               timeout_failure ~phase:Http_client.Wall_clock
                 "during the provider round trip")))
;;

let advanceable_flow_failure = function
  | Flow_step_candidate_rejected receipt -> Some (Flow_candidate_rejected receipt)
  | Flow_step_execution_failed { candidate; cause } ->
    Some (Flow_candidate_execution_failed { candidate; cause })
  | Flow_step_attempt_start_failed _
  | Flow_step_measurement_start_failed _
  | Flow_step_before_measurement_dispatch_callback_failed _
  | Flow_step_measurement_terminal_callback_failed _
  | Flow_step_before_dispatch_callback_failed _ -> None
;;

let execute_flow_once
      ~net
      ~clock
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
           ~clock
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
  | Output_limit_reached -> "output limit reached"
  | Incomplete_output -> "incomplete output"
  | Missing_output -> "missing output"
  | Ambiguous_output count -> Printf.sprintf "ambiguous output (candidates=%d)" count
  | Unexpected_output_content -> "unexpected output content"
  | Invalid_json_output -> "invalid json output"
;;

let start_attempt_error_to_string : start_attempt_error -> string = function
  | Call_id_generation_failed detail ->
    Printf.sprintf "call_id_generation_failed detail=%S" detail
;;

let measurement_start_error_to_string : measurement_start_error -> string = function
  | Measurement_operation_id_generation_failed detail ->
    Printf.sprintf "operation_id_generation_failed detail=%S" detail
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
